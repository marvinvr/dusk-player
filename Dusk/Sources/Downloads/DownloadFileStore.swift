import Foundation
import CryptoKit

struct DownloadFileStore: Sendable {
    let rootDirectory: URL

    init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        rootDirectory = applicationSupport
            .appendingPathComponent("Dusk", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    var stateFileURL: URL {
        rootDirectory.appendingPathComponent("downloads.json")
    }

    var playbackSyncStateFileURL: URL {
        rootDirectory.appendingPathComponent("playback-sync.json")
    }

    var metadataDirectory: URL {
        rootDirectory.appendingPathComponent("Metadata", isDirectory: true)
    }

    var artworkDirectory: URL {
        rootDirectory.appendingPathComponent("Artwork", isDirectory: true)
    }

    var resumeDataDirectory: URL {
        rootDirectory.appendingPathComponent("ResumeData", isDirectory: true)
    }

    func prepareRootDirectory() throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resumeDataDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = rootDirectory
        try? mutableRoot.setResourceValues(values)
    }

    func loadSnapshot() -> DownloadStoreSnapshot {
        guard let data = try? Data(contentsOf: stateFileURL) else {
            return DownloadStoreSnapshot()
        }
        return (try? JSONDecoder().decode(DownloadStoreSnapshot.self, from: data)) ?? DownloadStoreSnapshot()
    }

    func saveSnapshot(_ snapshot: DownloadStoreSnapshot) throws {
        try prepareRootDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: stateFileURL, options: [.atomic])
    }

    func metadataURL(accountProfileID: String?, serverID: String, endpoint: String) -> URL {
        let profileDirectory: URL
        if let accountProfileID = accountProfileID?.nilIfEmpty {
            profileDirectory = metadataDirectory
                .appendingPathComponent("Profiles", isDirectory: true)
                .appendingPathComponent(safeFileComponent(accountProfileID), isDirectory: true)
        } else {
            profileDirectory = metadataDirectory
        }

        return profileDirectory
            .appendingPathComponent(safeFileComponent(serverID), isDirectory: true)
            .appendingPathComponent("\(Self.hash(endpoint)).json")
    }

    func adoptLegacyMetadata(accountProfileID: String, serverIDs: Set<String>) {
        for serverID in serverIDs {
            let legacyDirectory = metadataDirectory
                .appendingPathComponent(safeFileComponent(serverID), isDirectory: true)
            let destinationDirectory = metadataDirectory
                .appendingPathComponent("Profiles", isDirectory: true)
                .appendingPathComponent(safeFileComponent(accountProfileID), isDirectory: true)
                .appendingPathComponent(safeFileComponent(serverID), isDirectory: true)

            guard FileManager.default.fileExists(atPath: legacyDirectory.path) else { continue }
            try? FileManager.default.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )

            let files = (try? FileManager.default.contentsOfDirectory(
                at: legacyDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
            for sourceURL in files {
                let destinationURL = destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent)
                guard !FileManager.default.fileExists(atPath: destinationURL.path) else { continue }
                try? FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }
        }
    }

    func artworkURL(for path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return artworkDirectory.appendingPathComponent("\(Self.hash(path)).jpg")
    }

    func targetVideoURL(
        accountProfileID: String,
        for details: PlexMediaDetails,
        part: PlexMediaPart
    ) throws -> URL {
        let relativePath = relativeVideoPath(
            accountProfileID: accountProfileID,
            for: details,
            part: part
        )
        let url = rootDirectory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    func relativePath(for absoluteURL: URL) -> String {
        let rootPath = rootDirectory.standardizedFileURL.path
        let filePath = absoluteURL.standardizedFileURL.path
        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else {
            return absoluteURL.lastPathComponent
        }
        var relative = String(filePath.dropFirst(rootPath.count))
        if relative.hasPrefix("/") {
            relative.removeFirst()
        }
        return relative
    }

    func absoluteURL(for relativePath: String?) -> URL? {
        guard let relativePath, !relativePath.isEmpty else { return nil }
        let rootURL = rootDirectory.standardizedFileURL
        let url = rootURL.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path == rootURL.path || url.path.hasPrefix(rootURL.path + "/") else {
            return nil
        }
        return url
    }

    func existingFileURL(for relativePath: String?) -> URL? {
        guard let url = absoluteURL(for: relativePath),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    func deleteVideo(relativePath: String?) {
        guard let url = absoluteURL(for: relativePath) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func storageUsageBytes() -> Int64 {
        directorySize(rootDirectory)
    }

    func availableStorageBytes() -> Int64? {
        #if os(tvOS)
        guard let values = try? rootDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey]) else {
            return nil
        }
        return values.volumeAvailableCapacity.map(Int64.init)
        #else
        guard let values = try? rootDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else {
            return nil
        }
        return values.volumeAvailableCapacityForImportantUsage
        #endif
    }

    func saveResumeData(_ data: Data, globalKey: String) throws -> String {
        try prepareRootDirectory()
        let url = resumeDataDirectory.appendingPathComponent("\(Self.hash(globalKey)).resume")
        try data.write(to: url, options: [.atomic])
        return relativePath(for: url)
    }

    func resumeData(relativePath: String?) -> Data? {
        guard let url = absoluteURL(for: relativePath) else { return nil }
        return try? Data(contentsOf: url)
    }

    func deleteResumeData(relativePath: String?) {
        guard let url = absoluteURL(for: relativePath) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func deleteAllStoredData() {
        try? FileManager.default.removeItem(at: rootDirectory)
        try? prepareRootDirectory()
    }

    private func relativeVideoPath(
        accountProfileID: String,
        for details: PlexMediaDetails,
        part: PlexMediaPart
    ) -> String {
        let ext = preferredExtension(for: details, part: part)
        let profileComponents = ["Profiles", sanitized(accountProfileID)]

        switch details.type {
        case .episode:
            let show = sanitized(details.grandparentTitle ?? "TV Show")
            let seasonNumber = details.parentIndex ?? 0
            let episodeNumber = details.index ?? 0
            let seasonFolder = "Season \(String(format: "%02d", seasonNumber))"
            let episodeTitle = sanitized(details.title)
            let filename = "S\(String(format: "%02d", seasonNumber))E\(String(format: "%02d", episodeNumber)) - \(episodeTitle).\(ext)"
            return (profileComponents + ["TV Shows", show, seasonFolder, filename]).joined(separator: "/")
        case .movie:
            let title = sanitized(details.year.map { "\(details.title) (\($0))" } ?? details.title)
            return (profileComponents + ["Movies", title, "\(title).\(ext)"]).joined(separator: "/")
        default:
            let title = sanitized(details.title)
            return (profileComponents + ["Other", title, "\(title).\(ext)"]).joined(separator: "/")
        }
    }

    private func preferredExtension(for details: PlexMediaDetails, part: PlexMediaPart) -> String {
        let candidates = [
            part.file.flatMap { URL(fileURLWithPath: $0).pathExtension.nilIfEmpty },
            URL(string: part.key)?.pathExtension.nilIfEmpty,
            part.container,
            details.media.first(where: { $0.parts.contains(where: { $0.id == part.id }) })?.container,
        ]

        return candidates.compactMap { $0?.lowercased() }.first ?? "mp4"
    }

    private func sanitized(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let components = value.components(separatedBy: invalid)
        let sanitized = components.joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return sanitized.isEmpty ? "Untitled" : sanitized
    }

    private func safeFileComponent(_ value: String) -> String {
        sanitized(value).replacingOccurrences(of: " ", with: "_")
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    static func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
