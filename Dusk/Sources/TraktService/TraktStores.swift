import Foundation

/// Trakt tokens per Plex profile, in the Keychain. Each Plex Home user links
/// their own Trakt account, so a kid's profile never scrobbles to a parent's.
enum TraktCredentialStore {
    private static let keychainKey = "TraktAccounts"

    static func load() -> [String: TraktTokens] {
        guard let data = KeychainHelper.load(key: keychainKey),
              let accounts = try? JSONDecoder().decode([String: TraktTokens].self, from: data) else {
            return [:]
        }
        return accounts
    }

    static func save(_ accounts: [String: TraktTokens]) {
        guard !accounts.isEmpty else {
            KeychainHelper.delete(key: keychainKey)
            return
        }
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        KeychainHelper.save(key: keychainKey, data: data)
    }
}

/// Finished plays not yet accepted by Trakt. Small and bounded on purpose:
/// this is a retry buffer, not a sync engine.
struct TraktHistoryQueue {
    static let maximumEntries = 200
    static let maximumAttempts = 8

    private static let defaultsKey = "TraktPendingHistory"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [TraktHistoryEntry] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let entries = try? JSONDecoder().decode([TraktHistoryEntry].self, from: data) else {
            return []
        }
        return entries
    }

    func save(_ entries: [TraktHistoryEntry]) {
        let kept = Array(entries.suffix(Self.maximumEntries))
        guard !kept.isEmpty, let data = try? JSONEncoder().encode(kept) else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
