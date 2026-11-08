import Foundation

/// The account's browsable libraries, across every connected server.
///
/// Libraries are deliberately **not** merged into virtual ones: two servers'
/// "Movies" sections stay two rows, because they hold different files, sort
/// differently and page independently. What is merged is the *order* — the
/// account's plex.tv sidebar order spans every server — and the type tabs,
/// which land on recommendations drawn from all libraries of that type.
/// One library's answer in the item-count task group; `hasItems` is nil when a
/// cancelled load said nothing. A named type built in one place on purpose: see
/// `Result.capturing`.
private struct LibraryItemCountCheck: Sendable {
    let libraryID: String
    let hasItems: Bool?
}

@MainActor
@Observable
final class LibrariesViewModel {
    private let plexService: PlexService

    /// Read-through of the shared library-order store so every browsable list
    /// follows the order stored on the Plex account. Music sections occupy
    /// slots in that order but are not browsable in Dusk, so they are filtered
    /// out here (and only here — the settings editor lists them), as are the
    /// libraries hidden in Library Order.
    /// So are "Other Videos" and photo sections until they are known to hold
    /// something: an empty one would otherwise put a tab in front of everyone.
    var libraries: [PlexLibrary] {
        plexService.libraryOrder.visibleSections.filter { library in
            guard let type = library.libraryType else { return false }
            return !Self.countedTypes.contains(type) || libraryHasItems[library.id] == true
        }
    }

    /// Types whose sections commonly exist empty (Plex creates them on a
    /// whim, people forget them), so they stay hidden until counted.
    private static let countedTypes: Set<PlexLibraryType> = [.video, .photo]

    /// Any browsable section, counted or not, so an uncounted video section
    /// does not read as "nothing loaded yet".
    private var hasBrowsableSections: Bool {
        plexService.libraryOrder.orderedSections.contains { $0.libraryType != nil }
    }

    /// Whether each counted section (`PlexLibrary.id`) holds any items.
    /// Missing means not counted yet, which keeps the section hidden; a failed
    /// count shows it rather than hiding a library that may well have content.
    private var libraryHasItems: [String: Bool] = [:]

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
        // Counting runs even when the sections are current: the shell's load
        // is often cancelled by the next server connecting, and an uncounted
        // section must not stay hidden for the rest of the session.
        guard force || !hasBrowsableSections || loadedRevision != serverContentRevision else {
            await countLibraryItems()
            return
        }

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

        await countLibraryItems()
    }

    /// Counts the video and photo sections not yet known to have items, so
    /// empty ones stay hidden and get another look on the next load.
    private func countLibraryItems() async {
        let uncounted = plexService.libraryOrder.orderedSections.filter {
            guard let type = $0.libraryType else { return false }
            return Self.countedTypes.contains(type) && libraryHasItems[$0.id] != true
        }
        guard !uncounted.isEmpty else { return }

        await withTaskGroup(of: LibraryItemCountCheck.self) { group in
            for library in uncounted {
                group.addTask { [plexService] in
                    let count = try? await plexService.getLibraryItemCount(
                        sectionId: library.key,
                        serverID: library.serverID
                    )
                    // A cancelled load (the shell's task restarts as servers
                    // connect) says nothing about the section: leave it
                    // uncounted for the next load.
                    let failureAnswer: Bool? = Task.isCancelled ? nil : true
                    return LibraryItemCountCheck(
                        libraryID: library.id,
                        hasItems: count.map { $0 > 0 } ?? failureAnswer
                    )
                }
            }
            for await result in group {
                guard let hasItems = result.hasItems else { continue }
                libraryHasItems[result.libraryID] = hasItems
            }
        }
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
