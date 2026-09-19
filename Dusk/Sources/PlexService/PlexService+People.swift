import Foundation

extension PlexService {
    /// - Parameter serverID: Person ids are per-server tag ids, exactly like
    ///   rating keys, so a person route has to carry the server it came from.
    func getPerson(personID: String, serverID: String? = nil) async throws -> PlexPerson {
        let people: [PlexPerson] = try await fetchDirectories(
            path: "/library/people/\(personID)",
            serverID: serverID
        )
        guard let person = people.first else {
            throw PlexServiceError.decodingError("No person found for id \(personID)")
        }
        return person
    }

    func getPersonMedia(personID: String, serverID: String? = nil) async throws -> [PlexItem] {
        let items: [PlexItem] = try await fetchMetadata(
            path: "/library/people/\(personID)/media",
            serverID: serverID
        )

        var seen = Set<PlexItemID>()
        return items
            .filter { $0.type == .movie || $0.type == .show }
            .filter { seen.insert($0.id).inserted }
    }
}
