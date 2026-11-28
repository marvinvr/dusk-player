import Foundation

@MainActor
@Observable
final class ActorDetailViewModel {
    private let media: MediaService
    /// The server the credit was read from. Person ids are per-server tag ids,
    /// so the filmography has to be fetched from the same server; nil falls
    /// back to the primary one.
    let serverID: String?

    private(set) var person: PersonReference
    private(set) var filmography: [MediaItem] = []
    private(set) var isLoading = false
    private(set) var error: String?

    init(person: PersonReference, serverID: String? = nil, media: MediaService) {
        self.person = person
        self.serverID = serverID
        self.media = media
    }

    func load() async {
        guard filmography.isEmpty else { return }
        isLoading = true
        error = nil

        do {
            if let personID = person.personID {
                async let personRequest = media.getPerson(personID: personID, serverID: serverID)
                async let mediaRequest = media.getPersonMedia(personID: personID, serverID: serverID)
                let (loadedPerson, loadedMedia) = try await (personRequest, mediaRequest)
                mergePersonDetails(loadedPerson)
                filmography = sortFilmography(loadedMedia)
            } else {
                filmography = sortFilmography(try await fallbackFilmography())
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    var movies: [MediaItem] {
        filmography.filter { $0.type == .movie }
    }

    var shows: [MediaItem] {
        filmography.filter { $0.type == .show }
    }

    var creditSummary: String {
        let parts = [
            movies.isEmpty ? nil : "\(movies.count) Movie\(movies.count == 1 ? "" : "s")",
            shows.isEmpty ? nil : "\(shows.count) Show\(shows.count == 1 ? "" : "s")",
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }

        let summary = parts.joined(separator: " · ")
        return summary.isEmpty ? "No titles found in this library" : summary
    }

    func personImageURL(size: Int) -> URL? {
        media.imageURL(for: ArtworkRef(serverID: serverID, path: person.thumb), size: ImageSize(width: size, height: size))
    }

    func posterURL(for item: MediaItem, width: Int, height: Int) -> URL? {
        item.posterImageURL(media: media, width: width, height: height)
    }

    func subtitle(for item: MediaItem) -> String? {
        item.filmographyPosterSubtitle
    }

    private func mergePersonDetails(_ loadedPerson: PersonDetails) {
        person = PersonReference(
            personID: loadedPerson.personID ?? person.personID,
            name: loadedPerson.tag,
            thumb: loadedPerson.thumb ?? person.thumb,
            roleName: person.roleName
        )
    }

    private func fallbackFilmography() async throws -> [MediaItem] {
        let results = try await media.search(query: person.name, serverID: serverID)
        let supportedItems = results
            .flatMap(\.items)
            .filter { $0.type == .movie || $0.type == .show }

        let exactRoleMatches = supportedItems.filter { item in
            item.roles?.contains(where: { $0.tag.caseInsensitiveCompare(person.name) == .orderedSame }) == true
        }

        return exactRoleMatches.isEmpty ? supportedItems : exactRoleMatches
    }

    private func sortFilmography(_ items: [MediaItem]) -> [MediaItem] {
        var seen = Set<MediaItemID>()
        return items
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                let leftYear = lhs.year ?? Int.min
                let rightYear = rhs.year ?? Int.min
                if leftYear != rightYear {
                    return leftYear > rightYear
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }
}
