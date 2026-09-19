import Foundation

/// The account's browsable libraries, across every connected server.
///
/// Libraries are deliberately **not** merged into virtual ones: two servers'
/// "Movies" sections stay two rows, because they hold different files, sort
/// differently and page independently. What is merged is the *order* — the
/// account's plex.tv sidebar order spans every server — and the type tabs,
/// which land on recommendations drawn from all libraries of that type.
@MainActor
@Observable
final class LibrariesViewModel {
    private let plexService: PlexService

    /// Read-through of the shared library-order store so every browsable list
    /// follows the order stored on the Plex account. Music and photo sections
    /// occupy slots in that order but are not browsable in Dusk, so they are
    /// filtered out here (and only here — the settings editor lists them).
    var libraries: [PlexLibrary] {
        plexService.libraryOrder.orderedSections.filter { $0.libraryType != nil }
    }

    private(set) var isLoading = false
    private(set) var error: String?

    /// The server/profile combination `libraries` was loaded for. Several
    /// screens ask for the libraries at once (the tab shell, each type tab), so
    /// this is what keeps one connect pass from triggering three loads.
    @ObservationIgnored private var loadedRevision: ServerContentRevision?

    /// Set when a load was asked for while another was already running. That
    /// load fetched the servers it knew about at the time, so the request is
    /// queued behind it instead of dropped — otherwise the libraries of a server
    /// that connected a moment later would never appear.
    @ObservationIgnored private var needsReload = false

    init(plexService: PlexService) {
        self.plexService = plexService
    }

    var availableLibraryTypes: [PlexLibraryType] {
        PlexLibraryType.allCases.filter { hasLibraries(for: $0) }
    }

    func libraries(for type: PlexLibraryType) -> [PlexLibrary] {
        libraries.filter { $0.libraryType == type }
    }

    func hasLibraries(for type: PlexLibraryType) -> Bool {
        libraries.contains { $0.libraryType == type }
    }

    /// The load is cross-server and per-server results are committed as they
    /// land, so `libraries` fills in from the first server that answers. It
    /// throws only when every server failed — one failing server must never
    /// blank the others' libraries.
    func loadLibraries(force: Bool = false) async {
        guard !isLoading else {
            needsReload = true
            return
        }
        guard force || libraries.isEmpty || loadedRevision != serverContentRevision else { return }

        var shouldForce = force
        repeat {
            // The revision is read *before* the fetch and recorded as what was
            // loaded: a server that connects while the sections are in flight
            // did not contribute to this result, so the loop has to run again.
            let revision = serverContentRevision
            needsReload = false
            isLoading = true
            error = nil

            do {
                _ = try await plexService.ensureLibraryOrderLoaded(force: shouldForce)
                loadedRevision = revision
                error = nil
            } catch {
                self.error = error.localizedDescription
                isLoading = false
                return
            }

            isLoading = false
            shouldForce = false
        } while needsReload || loadedRevision != serverContentRevision
    }

    func iconName(for library: PlexLibrary) -> String {
        library.libraryType?.systemImage ?? "folder"
    }

    /// Composite artwork lives on the library's own server.
    func artURL(for library: PlexLibrary, width: Int, height: Int) -> URL? {
        plexService.imageURL(
            for: library.composite ?? library.art ?? library.thumb,
            serverID: library.serverID,
            width: width,
            height: height
        )
    }

    /// The row title, with the server appended only when another library of the
    /// same type has the same name. See `ServerLabeling`.
    func displayTitle(for library: PlexLibrary) -> String {
        ServerLabeling.displayTitle(for: library, labels: serverLabels)
    }

    /// Computed from the whole browsable list, not per type tab: a "Movies"
    /// library and a "Movies" video library are told apart by their type, and
    /// the same label has to appear wherever the library is listed.
    var serverLabels: [String: String] {
        ServerLabeling.serverLabels(for: libraries, pool: plexService.pool)
    }

    var availability: ServerAvailability {
        plexService.pool.availability
    }

    var serverContentRevision: ServerContentRevision {
        plexService.serverContentRevision
    }
}
