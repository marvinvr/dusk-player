import Foundation
import Security
import Testing
@testable import Dusk

/// Shared plumbing for the G4 legacy-container tests (`LegacyContainerTests`,
/// `RealLegacyContainerTests`) and their recorder (`LegacyContainerRecorder`).
///
/// Fixtures are read and written through `#filePath`, not the test bundle:
/// simulator processes can reach the host file system, so no `project.yml`
/// change is needed and the recorder can write straight into the repository.
/// See `DuskTests/Fixtures/LegacyContainer/LegacyContainer-README.md`.
enum LegacyFixture {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/LegacyContainer", isDirectory: true)

    /// `TEST_RUNNER_DUSK_RECORD_LEGACY_CONTAINER=1 xcodebuild …` reaches the
    /// test process as `DUSK_RECORD_LEGACY_CONTAINER=1`.
    static let isRecording = ProcessInfo.processInfo.environment["DUSK_RECORD_LEGACY_CONTAINER"] == "1"

    static func url(_ name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: false)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static func record(_ data: Data, as name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(name), options: .atomic)
    }

    /// Parsed JSON, so key order and whitespace do not matter but a renamed,
    /// dropped or added key does.
    static func jsonObject(_ data: Data) throws -> NSObject {
        let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return try #require(object as? NSObject)
    }

    static func expectSameJSON(
        _ actual: Data?,
        _ expected: Data,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let actual = try #require(actual, sourceLocation: sourceLocation)
        let lhs = try jsonObject(actual)
        let rhs = try jsonObject(expected)
        #expect(
            lhs.isEqual(rhs),
            "Re-encoded bytes differ from the fixture:\n\(String(decoding: actual, as: UTF8.self))",
            sourceLocation: sourceLocation
        )
    }

    /// A throwaway `UserDefaults` suite, removed after `body`.
    static func withScratchDefaults<T>(_ body: (UserDefaults) throws -> T) throws -> T {
        let suite = "LegacyContainer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        return try body(defaults)
    }

    /// A throwaway downloads root, removed after `body`.
    static func withTemporaryRoot<T>(_ body: (URL) throws -> T) throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LegacyContainer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try body(root)
    }

    /// Writes `data` at `relativePath` under `root`, creating directories.
    static func place(_ data: Data, at relativePath: String, under root: URL) throws {
        let url = root.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    /// Runs `body` with `UserDefaults.standard[key]` temporarily replaced, then
    /// puts the original value (or its absence) back.
    static func withStandardDefault<T>(
        _ key: String,
        set value: Any?,
        _ body: () throws -> T
    ) rethrows -> T {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        defer {
            if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        return try body()
    }

    /// Async twin of `withStandardDefault` for several keys at once.
    @MainActor
    static func preservingStandardDefaults<T>(
        _ keys: [String],
        _ body: () async throws -> T
    ) async rethrows -> T {
        let defaults = UserDefaults.standard
        let originals = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, original) in zip(keys, originals) {
                if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        return try await body()
    }

    // MARK: - Keychain

    /// The Keychain service every Dusk item uses on iOS and tvOS (frozen).
    static let keychainService = "com.dusk-player.app"

    /// Reads a generic-password item by the literal service and account,
    /// bypassing `KeychainHelper`, so a changed service or account name fails.
    static func keychainData(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Runs `body` and afterwards restores the Keychain item `account` to what
    /// it was before (or deletes it).
    static func preservingKeychainItem<T>(_ account: String, _ body: () throws -> T) rethrows -> T {
        let original = KeychainHelper.load(key: account)
        defer {
            if let original { KeychainHelper.save(key: account, data: original) } else { KeychainHelper.delete(key: account) }
        }
        return try body()
    }

    /// Whether this process can use the Keychain at all (a simulator test host
    /// normally can; -34018 means it cannot).
    static var keychainIsAvailable: Bool {
        let account = "DuskLegacyContainerProbe.\(UUID().uuidString)"
        defer { KeychainHelper.delete(key: account) }
        return KeychainHelper.save(key: account, data: Data("probe".utf8))
    }
}

/// Fixed values shared by the recorder and the decode tests. They are inputs,
/// not expectations: the tests assert against their own literals.
enum LegacyValues {
    static let ownerProfile = "4f2a9c1d7e3b5a60"
    static let kidProfile = "plex-home-24601"
    static let serverA = "a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9"
    static let serverB = "b7c9e1f3a5d7b9c1e3f5a7c9e1b3d5f7a9c1e3f5"
    /// Records written before servers were keyed by machine identifier.
    static let legacyBaseURLServer = "http://192.168.1.10:32400"

    /// 2026-05-09T13:46:40Z, exactly representable as a Double.
    static let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let t1 = Date(timeIntervalSinceReferenceDate: 800_003_600)
    static let t2 = Date(timeIntervalSinceReferenceDate: 800_086_400)

    static let iptvSourceID = UUID(uuidString: "6B1E6C0A-3F2D-4C8B-9E7A-1D2C3B4A5F60")!
    static let iptvXtreamSourceID = UUID(uuidString: "0F9E8D7C-6B5A-4938-A7B6-C5D4E3F2A1B0")!
    static let traktHistoryID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    static let iptvProgrammeStart = Date(timeIntervalSince1970: 1_767_225_600)
    static let iptvProgrammeEnd = Date(timeIntervalSince1970: 1_767_229_200)
    static let iptvNextProgrammeEnd = Date(timeIntervalSince1970: 1_767_232_800)

    /// A PMS `/library/metadata/{rk}` part as Plex sends it, for the converted
    /// download's `PlexMedia` blob.
    static let convertedMediaJSON = #"""
        {"id":91,"container":"mkv","videoCodec":"h264","audioCodec":"aac","videoResolution":"720",
         "audioChannels":2,"width":1280,"height":720,"bitrate":4000,"duration":2520000,
         "Part":[{"id":92,"key":"/library/parts/92/1700000000/file.mkv","file":"/transcode/92.mkv",
                  "size":1260000000,"container":"mkv","duration":2520000,
                  "Stream":[{"id":93,"streamType":2,"codec":"aac","channels":2,"languageCode":"eng",
                             "displayTitle":"English (AAC Stereo)"}]}]}
        """#

    /// plex.tv `/api/v2/resources` entries, one still carrying a token the way
    /// pre-Keychain builds stored it.
    static let serverResourcesJSON = #"""
        [{"name":"Living Room","clientIdentifier":"a3d5f7e9b1c2d4e6f8a0b2c4d6e8f0a1b3c5d7e9",
          "product":"Plex Media Server","productVersion":"1.41.3.9314","platform":"Linux",
          "platformVersion":"6.1","provides":"server","owned":true,"presence":true,
          "accessToken":"server-token-must-not-persist","sourceTitle":null,
          "connections":[
            {"protocol":"https","address":"192.168.1.10","port":32400,
             "uri":"https://192-168-1-10.0123456789abcdef.plex.direct:32400","local":true,"relay":false,"IPv6":false},
            {"protocol":"https","address":"203.0.113.7","port":32400,
             "uri":"https://203-0-113-7.0123456789abcdef.plex.direct:32400","local":false,"relay":false,"IPv6":false}]},
         {"name":"Friend's Server","clientIdentifier":"b7c9e1f3a5d7b9c1e3f5a7c9e1b3d5f7a9c1e3f5",
          "provides":"server","owned":false,"presence":false,"sourceTitle":"friend",
          "connections":[
            {"protocol":"https","address":"198.51.100.4","port":443,
             "uri":"https://relay.plex.direct:443","local":false,"relay":true}]}]
        """#

    /// plex.tv `/api/v2/home/users` member, stored as `PlexActiveHomeUserData`.
    static let homeUserJSON = #"""
        {"id":24601,"uuid":"c1d2e3f4a5b60789","username":"kid","title":"Kid","friendlyName":"Kiddo",
         "thumb":"https://plex.tv/users/c1d2e3f4a5b60789/avatar","protected":"1","restricted":1,
         "admin":false,"guest":false}
        """#

    /// An episode as PMS sends it, for the ShowTrackPreferences scope and
    /// descriptors.
    static let trackEpisodeJSON = #"""
        {"ratingKey":"2011","key":"/library/metadata/2011","type":"episode","title":"Pilot",
         "parentIndex":1,"index":1,"parentRatingKey":"2010","grandparentRatingKey":"2000",
         "Media":[{"id":1,"container":"mkv","Part":[{"id":2,"key":"/library/parts/2/file.mkv","Stream":[
            {"id":11,"streamType":2,"languageCode":"jpn","codec":"truehd","channels":8,
             "displayTitle":"Japanese (TrueHD 7.1)"},
            {"id":12,"streamType":3,"languageCode":"eng","codec":"srt","forced":true,
             "displayTitle":"English Forced (SRT)"},
            {"id":13,"streamType":3,"languageCode":"eng","codec":"srt","key":"/library/streams/13",
             "displayTitle":"English (SRT External)","hearingImpaired":true}]}]}]}
        """#
}
