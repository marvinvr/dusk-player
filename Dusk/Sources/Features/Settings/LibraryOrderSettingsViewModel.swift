import Foundation
// `move(fromOffsets:toOffset:)` on RangeReplaceableCollection ships in SwiftUI,
// not Foundation.
import SwiftUI

/// Editing state for the library order screen.
///
/// The list is the user's working copy: every move mutates it immediately so the
/// UI stays responsive, and the write to Plex is debounced so walking a library
/// through six slots is one account write, not six. The order lives on the Plex
/// account (`PlexService.reorderLibraries`), so it is shared with every other
/// Plex client signed in as the same user.
@MainActor
@Observable
final class LibraryOrderSettingsViewModel {
    /// Shown when the sections or the account order could not be read at all.
    static let loadErrorMessage = "Couldn't load your library order from Plex."
    /// Shown when a debounced write failed; the list reverts to the stored order.
    static let saveErrorMessage = "Couldn't save the library order to your Plex account. Your libraries keep their current order."

    /// How long an edit sits before it is pushed to the Plex account.
    private static let writeDebounce: Duration = .seconds(1)

    private let plexService: PlexService

    /// Working order. Every section of the connected server, unfiltered: music
    /// and photo libraries are not browsable in Dusk but they occupy a slot in
    /// the account's sidebar order, so hiding them here would silently move them.
    private(set) var libraries: [PlexLibrary] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var error: String?
    private(set) var saveError: String?

    /// Server names, keyed by library id, for the libraries whose title and
    /// type are not unique. The server name is a disambiguator, never
    /// decoration: a single-server account never sees one.
    private(set) var serverLabels: [String: String] = [:]

    /// The order waiting for the debounce to elapse, if any.
    @ObservationIgnored private var pendingOrder: [PlexLibrary]?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    /// Chained so two flushes cannot overlap on the wire.
    @ObservationIgnored private var writeTask: Task<Void, Never>?

    init(plexService: PlexService) {
        self.plexService = plexService
    }

    func load() async {
        guard !isLoading else { return }

        isLoading = true
        error = nil
        do {
            // `force` because the settings screen is the one place that must show
            // the account's current order rather than whatever was cached at launch.
            _ = try await plexService.ensureLibraryOrderLoaded(force: true)
            libraries = plexService.libraryOrder.orderedSections
            serverLabels = makeServerLabels(for: libraries)
        } catch {
            self.error = Self.loadErrorMessage
        }
        isLoading = false
    }

    /// The row title: the library name, plus its server only when another
    /// library of the same type carries the same name. Shared with the
    /// Libraries tab through `ServerLabeling` so both say the same thing.
    func displayTitle(for library: PlexLibrary) -> String {
        ServerLabeling.displayTitle(for: library, labels: serverLabels)
    }

    private func makeServerLabels(for libraries: [PlexLibrary]) -> [String: String] {
        ServerLabeling.serverLabels(for: libraries, pool: plexService.pool)
    }

    // MARK: - Editing

    /// iOS/iPadOS list editing.
    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var updated = libraries
        updated.move(fromOffsets: offsets, toOffset: destination)
        apply(updated)
    }

    /// tvOS position menus: move one library to an absolute slot.
    func move(_ library: PlexLibrary, to index: Int) {
        guard let current = libraries.firstIndex(of: library) else { return }

        let target = min(max(index, 0), libraries.count - 1)
        guard current != target else { return }

        var updated = libraries
        let moved = updated.remove(at: current)
        updated.insert(moved, at: target)
        apply(updated)
    }

    func position(of library: PlexLibrary) -> Int {
        libraries.firstIndex(of: library) ?? 0
    }

    private func apply(_ updated: [PlexLibrary]) {
        libraries = updated
        saveError = nil
        pendingOrder = updated

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
        guard let order = pendingOrder else { return }
        pendingOrder = nil

        let previous = writeTask
        writeTask = Task { [weak self] in
            await previous?.value
            await self?.write(order)
        }
    }

    private func write(_ order: [PlexLibrary]) async {
        isSaving = true
        do {
            try await plexService.reorderLibraries(order)
            saveError = nil
        } catch {
            saveError = Self.saveErrorMessage
            // The account still holds the last order Plex accepted; showing the
            // failed order would lie about what other Plex apps will do.
            libraries = plexService.libraryOrder.orderedSections
        }
        isSaving = false
    }
}
