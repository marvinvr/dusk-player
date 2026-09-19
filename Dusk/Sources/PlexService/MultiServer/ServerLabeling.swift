import Foundation

/// Decides when a library has to say which server it is on.
///
/// The server name is a *disambiguator*, never decoration: it appears only when
/// another library of the same type carries the same title, so a single-server
/// account — and a multi-server account with distinctly named libraries — looks
/// exactly as it did before Dusk connected to everything at once.
@MainActor
enum ServerLabeling {
    /// Server names keyed by `PlexLibrary.id`, for the colliding libraries only.
    static func serverLabels(for libraries: [PlexLibrary], pool: ServerPool) -> [String: String] {
        var counts: [String: Int] = [:]
        for library in libraries {
            counts[collisionKey(for: library), default: 0] += 1
        }

        var labels: [String: String] = [:]
        for library in libraries {
            guard counts[collisionKey(for: library), default: 0] > 1,
                  let serverID = library.serverID else { continue }
            labels[library.id] = pool.displayName(for: serverID)
        }
        return labels
    }

    /// `"<title> · <server>"` when the library needs disambiguating, otherwise
    /// just the title.
    static func displayTitle(for library: PlexLibrary, labels: [String: String]) -> String {
        guard let serverName = labels[library.id] else { return library.title }
        return "\(library.title) · \(serverName)"
    }

    /// Two libraries collide when a user could not tell them apart: same kind of
    /// content, same name. `PlexLibrary.type` is used rather than `libraryType`
    /// so music and photo sections (which Dusk never resolves) still compare.
    private static func collisionKey(for library: PlexLibrary) -> String {
        "\(library.type)|\(library.title.lowercased())"
    }
}
