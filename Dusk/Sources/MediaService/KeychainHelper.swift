import Foundation
import Security

/// Minimal Keychain wrapper using the Security framework directly.
enum KeychainHelper {
    #if os(macOS)
    /// The Mac uses the shared login keychain, where every build would see one
    /// item named after the App Store bundle ID: a local beta (other bundle ID)
    /// or QA build would pick up, and overwrite, another build's sign-in. The
    /// bundle ID keeps them apart; the App Store build still uses
    /// "com.dusk-player.app".
    private static let service = Bundle.main.bundleIdentifier ?? "com.dusk-player.app"
    #else
    private static let service = "com.dusk-player.app"
    #endif

    #if DEBUG && os(macOS)
    /// Mac screenshot mode and `-DuskScreenshotSignedOut` captures never touch the
    /// real Keychain: its items are real sign-ins, and a rebuilt ad-hoc signed
    /// build blocks on a Keychain access prompt reading them. They get an
    /// in-memory store for the life of the process instead.
    private static var usesMemoryStore: Bool {
        ScreenshotMode.isActive || ScreenshotMode.startsSignedOut
    }
    nonisolated(unsafe) private static var memoryStore: [String: Data] = [:]
    private static let memoryStoreLock = NSLock()
    #endif

    @discardableResult
    static func save(key: String, data: Data) -> Bool {
        #if DEBUG && os(macOS)
        if usesMemoryStore {
            memoryStoreLock.withLock { memoryStore[key] = data }
            return true
        }
        #endif
        delete(key: key)

        #if os(macOS)
        // The Mac app keeps the default file-based login keychain (it works for
        // an ad-hoc signed sandboxed build); accessibility classes only apply to
        // the data-protection keychain, so none is set.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        #else
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        #endif

        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load(key: String) -> Data? {
        #if DEBUG && os(macOS)
        if usesMemoryStore {
            return memoryStoreLock.withLock { memoryStore[key] }
        }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        #if DEBUG && os(macOS)
        if usesMemoryStore {
            memoryStoreLock.withLock { memoryStore[key] = nil }
            return true
        }
        #endif
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
