import Foundation

/// IPTV sources per Plex profile. The source list (names and URLs) is a plain
/// preference in UserDefaults, keyed by profile like other per-user settings;
/// header values are secrets and live in the Keychain, keyed by source id.
struct IPTVSourceStore {
    private static let defaultsKeyPrefix = "IPTVSources."
    private static let keychainKey = "IPTVSourceHeaderValues"

    private let defaults: UserDefaults
    /// Seam for tests: the Keychain is unavailable to a hostless test bundle.
    private let secrets: SecretStorage

    struct SecretStorage: Sendable {
        var load: @Sendable () -> Data?
        var save: @Sendable (Data) -> Void
        var delete: @Sendable () -> Void

        static let keychain = SecretStorage(
            load: { KeychainHelper.load(key: IPTVSourceStore.keychainKey) },
            save: { KeychainHelper.save(key: IPTVSourceStore.keychainKey, data: $0) },
            delete: { KeychainHelper.delete(key: IPTVSourceStore.keychainKey) }
        )
    }

    init(defaults: UserDefaults = .standard, secrets: SecretStorage = .keychain) {
        self.defaults = defaults
        self.secrets = secrets
    }

    func sources(profileID: String) -> [IPTVSource] {
        guard let data = defaults.data(forKey: Self.defaultsKeyPrefix + profileID),
              let sources = try? JSONDecoder().decode([IPTVSource].self, from: data) else {
            return []
        }
        return sources
    }

    func save(_ sources: [IPTVSource], profileID: String) {
        let key = Self.defaultsKeyPrefix + profileID
        guard !sources.isEmpty, let data = try? JSONEncoder().encode(sources) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    func headerValue(for sourceID: UUID) -> String? {
        loadSecrets()[sourceID.uuidString]
    }

    func setHeaderValue(_ value: String?, for sourceID: UUID) {
        var all = loadSecrets()
        all[sourceID.uuidString] = value?.nilIfEmpty
        guard !all.isEmpty, let data = try? JSONEncoder().encode(all) else {
            secrets.delete()
            return
        }
        secrets.save(data)
    }

    private func loadSecrets() -> [String: String] {
        guard let data = secrets.load(),
              let values = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return values
    }
}
