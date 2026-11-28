import Foundation
// `move(fromOffsets:toOffset:)` on RangeReplaceableCollection ships in SwiftUI,
// not Foundation.
import SwiftUI

/// Editing state for the account's libraries: their order (Library Order) and
/// which ones are hidden (Settings › Libraries › Hidden Libraries). Both screens
/// use it because both are written in one go to the same plex.tv setting.
///
/// The list is the user's working copy: every move mutates it immediately so the
/// UI stays responsive, and the write to Plex is debounced so walking a library
/// through six slots is one account write, not six. The order lives on the Plex
/// account (`MediaService.reorderLibraries`), so it is shared with every other
/// Plex client signed in as the same user.
@MainActor
@Observable
final class LibraryOrderSettingsViewModel {
    /// Shown when the sections or the account order could not be read at all.
    static let loadErrorMessage = "Couldn't load your library order from Plex."
    /// Shown when a debounced write failed; the list reverts to the stored order.
    static let saveErrorMessage = "Couldn't save your libraries to your Plex account. They keep their current order and visibility."

    /// How long an edit sits before it is pushed to the Plex account.
    private static let writeDebounce: Duration = .seconds(1)

    private let media: MediaService

    /// Working order. Every section of the connected server, unfiltered: music
    /// and photo libraries are not browsable in Dusk but they occupy a slot in
    /// the account's sidebar order, so leaving them out would silently move them.
    /// Hidden libraries stay in this list; a move puts them after the visible
    /// ones, which is where the account stores them anyway.
    private(set) var libraries: [Library] = []
    /// `Library.id`s the user has hidden.
    private(set) var hiddenIDs: Set<String> = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var error: String?
    private(set) var saveError: String?

    /// Server names, keyed by library id, for the libraries whose title and
    /// type are not unique. The server name is a disambiguator, never
    /// decoration: a single-server account never sees one.
    private(set) var serverLabels: [String: String] = [:]

    /// The order and hidden set waiting for the debounce to elapse, if any.
    @ObservationIgnored private var pendingWrite: (order: [Library], hidden: Set<String>)?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    /// Chained so two flushes cannot overlap on the wire.
    @ObservationIgnored private var writeTask: Task<Void, Never>?

    init(media: MediaService) {
        self.media = media
    }

    func load() async {
        guard !isLoading else { return }

        isLoading = true
        error = nil
        do {
            // `force` because the settings screen is the one place that must show
            // the account's current order rather than whatever was cached at launch.
            _ = try await media.ensureLibraryOrderLoaded(force: true)
            resetToStoredState()
            serverLabels = makeServerLabels(for: libraries)
        } catch {
            self.error = Self.loadErrorMessage
        }
        isLoading = false
    }

    /// The row title: the library name, plus its server only when another
    /// library of the same type carries the same name. Shared with the
    /// Libraries tab through `ServerLabeling` so both say the same thing.
    func displayTitle(for library: Library) -> String {
        ServerLabeling.displayTitle(for: library, labels: serverLabels)
    }

    private func makeServerLabels(for libraries: [Library]) -> [String: String] {
        ServerLabeling.serverLabels(for: libraries, pool: media.pool)
    }

    /// The libraries Dusk shows, in order. Moves and positions refer to this
    /// list.
    var visibleLibraries: [Library] {
        libraries.filter { !hiddenIDs.contains($0.id) }
    }

    var hiddenLibraries: [Library] {
        libraries.filter { hiddenIDs.contains($0.id) }
    }

    /// The libraries Dusk can show, per server, for the Hidden Libraries
    /// switches: servers in priority order, each server's libraries in its own
    /// order. Deliberately not the account order, so a switch never moves.
    var hideableLibrariesByServer: [LibraryServerGroup] {
        var groups: [LibraryServerGroup] = []
        for library in media.libraryOrder.sections where library.libraryType != nil {
            let serverID = library.serverID ?? ""
            if groups.last?.serverID == serverID {
                groups[groups.count - 1].libraries.append(library)
            } else {
                groups.append(LibraryServerGroup(
                    serverID: serverID,
                    serverName: media.pool.displayName(for: serverID),
                    libraries: [library]
                ))
            }
        }
        return groups
    }

    func isHidden(_ library: Library) -> Bool {
        hiddenIDs.contains(library.id)
    }

    /// Hidden libraries listed after the visible ones, mirroring how the
    /// account stores them.
    private func resetToStoredState() {
        let hidden = media.libraryOrder.hiddenSectionIdentities
        let ordered = media.libraryOrder.orderedSections
        libraries = ordered.filter { !hidden.contains($0.id) } + ordered.filter { hidden.contains($0.id) }
        hiddenIDs = hidden
    }

    // MARK: - Editing

    /// iOS/iPadOS list editing, over `visibleLibraries`.
    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var visible = visibleLibraries
        visible.move(fromOffsets: offsets, toOffset: destination)
        apply(visible + hiddenLibraries, hidden: hiddenIDs)
    }

    /// tvOS position menus: move one visible library to an absolute slot.
    func move(_ library: Library, to index: Int) {
        var visible = visibleLibraries
        guard let current = visible.firstIndex(of: library) else { return }

        let target = min(max(index, 0), visible.count - 1)
        guard current != target else { return }

        let moved = visible.remove(at: current)
        visible.insert(moved, at: target)
        apply(visible + hiddenLibraries, hidden: hiddenIDs)
    }

    func position(of library: Library) -> Int {
        visibleLibraries.firstIndex(of: library) ?? 0
    }

    /// Hides or shows a library everywhere in Dusk (see `HiddenLibraryFilter`).
    /// The flag lives on the Plex account next to the order, so other Plex apps
    /// follow it too.
    func setHidden(_ isHidden: Bool, for library: Library) {
        var hidden = hiddenIDs
        if isHidden {
            guard hidden.insert(library.id).inserted else { return }
        } else {
            guard hidden.remove(library.id) != nil else { return }
        }
        apply(libraries, hidden: hidden)
    }

    private func apply(_ updated: [Library], hidden: Set<String>) {
        libraries = updated
        hiddenIDs = hidden
        saveError = nil
        pendingWrite = (updated, hidden)

        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.writeDebounce)
            guard !Task.isCancelled else { return }
            self?.startWrite()
        }
    }

    // MARK: - Writing

    /// Called when the screen goes away so a half-elapsed debounce is not lost.
    func flushPendingWrite() async {
        debounceTask?.cancel()
        debounceTask = nil
        startWrite()
        await writeTask?.value
    }

    private func startWrite() {
        debounceTask = nil
        guard let pending = pendingWrite else { return }
        pendingWrite = nil

        let previous = writeTask
        writeTask = Task { [weak self] in
            await previous?.value
            await self?.write(pending.order, hidden: pending.hidden)
        }
    }

    private func write(_ order: [Library], hidden: Set<String>) async {
        isSaving = true
        do {
            try await media.reorderLibraries(order, hidden: hidden)
            saveError = nil
        } catch {
            saveError = Self.saveErrorMessage
            // The account still holds the last state Plex accepted; showing the
            // failed one would lie about what other Plex apps will do.
            resetToStoredState()
        }
        isSaving = false
    }
}

/// One server's libraries on the Hidden Libraries screen.
struct LibraryServerGroup: Identifiable {
    let serverID: String
    let serverName: String
    var libraries: [Library]

    var id: String { serverID }
}
