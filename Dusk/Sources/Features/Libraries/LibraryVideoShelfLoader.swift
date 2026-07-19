import Foundation

/// One 16:9 channel row on a video library's recommendations screen, backed
/// by a Plex collection (video libraries hold one collection per channel).
struct LibraryVideoChannelShelf: Identifiable, Sendable, Hashable {
    let collection: PlexLibraryCollection
    let items: [PlexItem]

    var id: String { collection.id }
}

struct LibraryVideoShelfResult: Sendable {
    let channelShelves: [LibraryVideoChannelShelf]
    let rediscoverItems: [PlexItem]
}

/// Loads the video-library-specific shelves (per-channel rows plus a seeded
/// "Rediscover" row of unwatched items) for `LibraryRecommendationsViewModel`.
/// Video sections skip the genre recommendation engine entirely; these rows
/// take its place.
@MainActor
struct LibraryVideoShelfLoader {
    let library: PlexLibrary
    let plexService: PlexService
    var calendar: Calendar = .autoupdatingCurrent
    var nowProvider: @Sendable () -> Date = Date.init

    // Static so they stay out of the memberwise initializer.
    private static let maxChannelShelves = 6
    private static let itemsPerChannelShelf = 12
    private static let rediscoverItemCount = 12
    private static let rediscoverCandidatePageSize = 60
    private static let minimumRediscoverItemCount = 4

    func load() async -> LibraryVideoShelfResult {
        async let channelShelvesTask = loadChannelShelves()
        async let rediscoverTask = loadRediscoverItems()

        return LibraryVideoShelfResult(
            channelShelves: await channelShelvesTask,
            rediscoverItems: await rediscoverTask
        )
    }

    /// One row per collection (channel), newest uploads first. Sections with
    /// at most one collection skip channel rows entirely because the section
    /// hubs already cover the same content.
    private func loadChannelShelves() async -> [LibraryVideoChannelShelf] {
        guard let collections = try? await plexService.getLibraryCollections(sectionId: library.key),
              collections.count > 1 else {
            return []
        }

        let selectedCollections = Array(collections.prefix(Self.maxChannelShelves))
        let sectionId = library.key
        let itemsPerShelf = Self.itemsPerChannelShelf
        let service = plexService

        let loadedShelves = await withTaskGroup(
            of: (Int, LibraryVideoChannelShelf?).self
        ) { group in
            for (index, collection) in selectedCollections.enumerated() {
                group.addTask {
                    let items = (try? await service.getLibraryItems(
                        sectionId: sectionId,
                        size: itemsPerShelf,
                        sort: "originallyAvailableAt:desc",
                        filters: ["collection": collection.key]
                    )) ?? []

                    guard !items.isEmpty else { return (index, nil) }
                    return (index, LibraryVideoChannelShelf(collection: collection, items: items))
                }
            }

            var results: [(Int, LibraryVideoChannelShelf?)] = []
            results.reserveCapacity(selectedCollections.count)

            for await result in group {
                results.append(result)
            }

            return results
        }

        return loadedShelves
            .sorted { $0.0 < $1.0 }
            .compactMap(\.1)
    }

    /// A deterministic daily sample of unwatched items. In-progress items are
    /// excluded so the row never duplicates Continue Watching. The candidate
    /// page is a seeded window over the whole title-sorted section — not the
    /// newest page — so older uploads resurface instead of mirroring the
    /// Recently Added hub.
    private func loadRediscoverItems() async -> [PlexItem] {
        let randomizer = RecommendationSeededRandomizer(
            calendar: calendar,
            nowProvider: nowProvider,
            seedScope: library.key
        )
        let seed = randomizer.dailySeed(for: "rediscover")

        let pageSize = Self.rediscoverCandidatePageSize
        let totalCount = (try? await plexService.getLibraryItemCount(sectionId: library.key)) ?? 0
        let maxOffset = max(0, totalCount - pageSize)
        let offset = maxOffset > 0 ? Int(seed % UInt64(maxOffset + 1)) : 0

        let candidates = (try? await plexService.getLibraryItems(
            sectionId: library.key,
            start: offset,
            size: pageSize,
            sort: "titleSort"
        )) ?? []

        let unwatched = candidates.filter { !$0.isWatched && !$0.isPartiallyWatched }

        guard unwatched.count >= Self.minimumRediscoverItemCount else { return [] }

        return Array(
            randomizer.seededShuffle(unwatched, seed: seed)
                .prefix(Self.rediscoverItemCount)
        )
    }
}
