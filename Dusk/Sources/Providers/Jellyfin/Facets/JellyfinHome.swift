import Foundation

/// Jellyfin's Home rows. Placeholder until J-04: no rows.
@MainActor
struct JellyfinHome: HomeProviding {
    let server: JellyfinServerProvider

    nonisolated init(server: JellyfinServerProvider) {
        self.server = server
    }

    func homeRows() async throws -> [HomeRow] { [] }

    func continueWatching() async throws -> [MediaItem] { [] }

    func libraryRows(libraryID: String, count: Int) async throws -> [HomeRow] { [] }

    func promotedLibraryRows(libraryID: String, count: Int) async throws -> [HomeRow] { [] }

    func rowItems(rowKey: String, start: Int, size: Int?) async throws -> [MediaItem] { [] }

    func managedRows(libraryID: String) async throws -> [ManagedHub] { [] }

    func setManagedRow(_ row: ManagedHub, libraryID: String) async throws {
        throw MediaServiceError.notImplemented
    }

    func managedRow(for row: HomeRow, source: HomeRowSource, libraryIDs: [String]) async -> ManagedHomeRow? { nil }
}
