import Foundation

@MainActor
@Observable
final class SearchViewModel {
    private let plexService: PlexService
    private let seerrService: SeerrService

    var query = ""
    private(set) var results: [SearchMediaResultGroup] = []
    private(set) var isSearching = false
    private(set) var error: String?
    private(set) var hasSearched = false

    private var searchTask: Task<Void, Never>?

    init(plexService: PlexService, seerrService: SeerrService) {
        self.plexService = plexService
        self.seerrService = seerrService
    }

    func searchDebounced() {
        searchTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func imageURL(for item: SearchMediaResult, width: Int, height: Int) -> URL? {
        item.imageURL(
            plexService: plexService,
            seerrService: seerrService,
            width: width,
            height: height
        )
    }

    func availabilityBadge(for item: SearchMediaResult) -> String? {
        item.availabilityBadge(using: seerrService)
    }

    private func performSearch(_ query: String) async {
        isSearching = true
        error = nil

        let seerrTask: Task<[SeerrSearchMedia], Never> = Task { [seerrService] in
            guard seerrService.isAvailableForCurrentContext else {
                return [SeerrSearchMedia]()
            }
            return (try? await seerrService.search(query: query)) ?? []
        }
        defer { seerrTask.cancel() }

        var plexGroups: [PlexSearchResult] = []
        var plexError: Error?
        do {
            plexGroups = try await plexService.search(query: query)
            guard !Task.isCancelled else { return }
            results = Self.makeGroups(plexGroups: plexGroups, seerrItems: [])
            hasSearched = true
        } catch {
            plexError = error
        }

        let seerrItems = await seerrTask.value
        guard !Task.isCancelled else { return }
        results = Self.makeGroups(plexGroups: plexGroups, seerrItems: seerrItems)
        hasSearched = true
        if results.isEmpty, let plexError {
            self.error = plexError.localizedDescription
        }
        isSearching = false
    }

    private static func makeGroups(
        plexGroups: [PlexSearchResult],
        seerrItems: [SeerrSearchMedia]
    ) -> [SearchMediaResultGroup] {
        var groups = plexGroups.map {
            SearchMediaResultGroup(
                id: $0.type ?? $0.title,
                title: $0.title,
                type: $0.type,
                items: $0.items.map(SearchMediaResult.plex)
            )
        }

        let plexItems = plexGroups.flatMap(\.items)
        let plexTMDBIDs = Set(
            plexItems.flatMap(\.guids).compactMap { $0.value(for: "tmdb") }.compactMap(Int.init)
        )
        let plexFallbackKeys = Set(plexItems.map(fallbackKey))

        for item in seerrItems {
            guard let type = item.supportedMediaType,
                  item.mediaInfo?.status != .available,
                  item.mediaInfo?.status != .blocklisted,
                  !plexTMDBIDs.contains(item.id),
                  !plexFallbackKeys.contains(fallbackKey(item)) else {
                continue
            }

            let targetType = type == .tv ? "show" : "movie"
            if let index = groups.firstIndex(where: { $0.type == targetType }) {
                groups[index].items.append(.seerr(item))
            } else {
                groups.append(
                    SearchMediaResultGroup(
                        id: targetType,
                        title: type == .tv ? "Shows" : "Movies",
                        type: targetType,
                        items: [.seerr(item)]
                    )
                )
            }
        }

        return groups.filter { !$0.items.isEmpty }
    }

    private static func fallbackKey(_ item: PlexItem) -> String {
        "\(item.type.rawValue):\(normalized(item.title)):\(item.year.map(String.init) ?? "")"
    }

    private static func fallbackKey(_ item: SeerrSearchMedia) -> String {
        let type = item.supportedMediaType == .tv ? "show" : "movie"
        return "\(type):\(normalized(item.displayTitle)):\(item.year.map(String.init) ?? "")"
    }

    private static func normalized(_ value: String) -> String {
        String(
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .filter { $0.isLetter || $0.isNumber }
        )
    }
}
