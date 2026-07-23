import Foundation

struct SeerrStoredSession: Codable, Sendable, Hashable {
    let baseURL: String
    let profileID: String
    let serverID: String
    var cookies: [String: String]
}

enum SeerrCredentialStore {
    private static let keychainKey = "SeerrSessions"

    static func load() -> [SeerrStoredSession] {
        guard let data = KeychainHelper.load(key: keychainKey),
              let sessions = try? JSONDecoder().decode([SeerrStoredSession].self, from: data) else {
            return []
        }
        return sessions
    }

    static func save(_ sessions: [SeerrStoredSession]) {
        guard !sessions.isEmpty else {
            KeychainHelper.delete(key: keychainKey)
            return
        }

        guard let data = try? JSONEncoder().encode(sessions) else { return }
        KeychainHelper.save(key: keychainKey, data: data)
    }

    static func removeAll() {
        KeychainHelper.delete(key: keychainKey)
    }
}

