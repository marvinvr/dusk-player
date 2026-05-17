import Foundation

@MainActor
@Observable
final class ActorDetailViewModel {
    private let plexService: PlexService

    private(set) var person: PlexPersonReference
    private(set) var filmography: [PlexItem] = []
    private(set) var isLoading = false
    private(set) var error: String?

    init(person: PlexPersonReference, plexService: PlexService) {
        self.person = person
        self.plexService = plexService
    }

    func load() async {
        guard filmography.isEmpty else { return }
        isLoading = true
        error = nil

        do {
            if let personID = person.personID {
                async let personRequest = plexService.getPerson(personID: personID)
                async let mediaRequest = plexService.getPersonMedia(personID: personID)
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

    var movies: [PlexItem] {
        filmography.filter { $0.type == .movie }
    }

    var shows: [PlexItem] {
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
        plexService.imageURL(for: person.thumb, width: size, height: size)
    }

    func posterURL(for item: PlexItem, width: Int, height: Int) -> URL? {
        item.posterImageURL(plexService: plexService, width: width, height: height)
    }

    func subtitle(for item: PlexItem) -> String? {
        item.filmographyPosterSubtitle
    }

    private func mergePersonDetails(_ loadedPerson: PlexPerson) {
        person = PlexPersonReference(
            personID: loadedPerson.personID ?? person.personID,
            name: loadedPerson.tag,
            thumb: loadedPerson.thumb ?? person.thumb,
            roleName: person.roleName
        )
    }

    private func fallbackFilmography() async throws -> [PlexItem] {
        let results = try await plexService.search(query: person.name)
        let supportedItems = results
            .flatMap(\.items)
            .filter { $0.type == .movie || $0.type == .show }

        let exactRoleMatches = supportedItems.filter { item in
            item.roles?.contains(where: { $0.tag.caseInsensitiveCompare(person.name) == .orderedSame }) == true
        }

        return exactRoleMatches.isEmpty ? supportedItems : exactRoleMatches
    }

    private func sortFilmography(_ items: [PlexItem]) -> [PlexItem] {
        var seen = Set<String>()
        return items
            .filter { seen.insert($0.ratingKey).inserted }
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
