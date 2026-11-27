import Foundation
@testable import Dusk

/// Loads the recorded Jellyfin responses in `DuskTests/Fixtures/Jellyfin`
/// (recorded by `scripts/jellyfin/record_fixtures.sh`). The files are copied
/// flat into the test bundle; the source tree is the fallback, which the
/// simulator can read.
enum JellyfinFixtures {
    private final class BundleToken {}

    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Jellyfin", isDirectory: true)

    static func url(_ name: String) -> URL {
        let file = "jellyfin-\(name)"
        if let url = Bundle(for: BundleToken.self).url(forResource: file, withExtension: "json") {
            return url
        }
        return directory.appendingPathComponent("\(file).json")
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JellyfinJSON.decode(type, from: data(name))
    }

    /// Every fixture name (without `jellyfin-` and `.json`).
    static func allNames() throws -> [String] {
        let bundled = Bundle(for: BundleToken.self).urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        let urls = bundled.contains { $0.lastPathComponent.hasPrefix("jellyfin-") }
            ? bundled
            : try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return urls.map(\.lastPathComponent)
            .filter { $0.hasPrefix("jellyfin-") && $0.hasSuffix(".json") }
            .map { String($0.dropFirst("jellyfin-".count).dropLast(".json".count)) }
            .sorted()
    }
}
