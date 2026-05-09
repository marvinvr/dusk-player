import Foundation

struct OfflinePlaybackSyncStore: Sendable {
    private let fileStore: DownloadFileStore

    init(fileStore: DownloadFileStore = DownloadFileStore()) {
        self.fileStore = fileStore
    }

    func loadSnapshot() -> OfflinePlaybackSyncSnapshot {
        guard let data = try? Data(contentsOf: fileStore.playbackSyncStateFileURL) else {
            return OfflinePlaybackSyncSnapshot()
        }
        return (try? JSONDecoder().decode(OfflinePlaybackSyncSnapshot.self, from: data))
            ?? OfflinePlaybackSyncSnapshot()
    }

    func saveSnapshot(_ snapshot: OfflinePlaybackSyncSnapshot) throws {
        try fileStore.prepareRootDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileStore.playbackSyncStateFileURL, options: [.atomic])
    }
}
