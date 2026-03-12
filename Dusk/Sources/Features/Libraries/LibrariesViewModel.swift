import Foundation

@MainActor
@Observable
final class LibrariesViewModel {
    private let plexService: PlexService

    private(set) var libraries: [PlexLibrary] = []
    private(set) var isLoading = false
    private(set) var error: String?

    init(plexService: PlexService) {
        self.plexService = plexService
    }

    func loadLibraries() async {
        guard libraries.isEmpty else { return }
        isLoading = true
        error = nil
        do {
            libraries = try await plexService.getLibraries().filter { isVisibleLibraryType($0.type) }
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func iconName(for library: PlexLibrary) -> String {
        switch library.type {
        case "movie": return "film"
        case "show": return "tv"
        case "artist": return "music.note"
        case "photo": return "photo"
        default: return "folder"
        }
    }

    func artURL(for library: PlexLibrary, width: Int, height: Int) -> URL? {
        plexService.imageURL(
            for: library.composite ?? library.art ?? library.thumb,
            width: width,
            height: height
        )
    }

    private func isVisibleLibraryType(_ type: String) -> Bool {
        switch type {
        case "movie", "show":
            return true
        default:
            return false
        }
    }
}
