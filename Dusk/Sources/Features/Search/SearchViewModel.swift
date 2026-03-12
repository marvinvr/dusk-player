import Foundation

@MainActor
@Observable
final class SearchViewModel {
    private let plexService: PlexService

    var query = ""
    private(set) var results: [PlexSearchResult] = []
    private(set) var isSearching = false
    private(set) var error: String?
    private(set) var hasSearched = false

    private var searchTask: Task<Void, Never>?

    init(plexService: PlexService) {
        self.plexService = plexService
    }

    func searchDebounced() {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            error = nil
            hasSearched = false
            isSearching = false
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await performSearch(trimmed)
        }
    }

    func imageURL(for path: String?, width: Int, height: Int) -> URL? {
        plexService.imageURL(for: path, width: width, height: height)
    }

    private func performSearch(_ query: String) async {
        isSearching = true
        error = nil

        do {
            let searchResults = try await plexService.search(query: query)
            guard !Task.isCancelled else { return }
            results = searchResults
            hasSearched = true
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
        isSearching = false
    }
}
