import Foundation
import OSLog

private let homeLayoutLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "HomeLayout"
)

/// Backs the Home layout editor.
///
/// Plex owns as much of the layout as its API allows: rows that exist as
/// Managed Recommendations are reordered and shown/hidden inside their library
/// on the server. `UserPreferences` keeps the complete arrangement and syncs it
/// through iCloud so Dusk-only rows and cross-library placement also follow the
/// user to their other Dusk devices.
@MainActor @Observable
final class HomeLayoutSettingsViewModel {
    /// The Plex-side hub a row maps onto. `promotedToRecommended` and
    /// `promotedToSharedHome` are carried so a home-visibility write can send
    /// them back unchanged.
    struct ManagedReference: Hashable, Sendable {
        let sectionID: String
        let identifier: String
        let libraryTitle: String
        let promotedToRecommended: Bool
        let promotedToSharedHome: Bool
    }

    struct Row: Identifiable, Sendable {
        let id: String
        let title: String
        let subtitle: String?
        var isVisible: Bool
        let managed: ManagedReference?
    }

    private(set) var rows: [Row] = []
    private(set) var isFeaturedVisible = true
    private(set) var isLoading = false
    private(set) var error: String?
    /// Set when a Plex write failed but the change remained in Dusk's synced layout.
    private(set) var syncWarning: String?
    private(set) var isSyncing = false
    /// True when this account can write the layout back to Plex at all.
    private(set) var syncsToPlex = false

    var hasSavedLayout: Bool {
        preferences.hasCustomHomeLayout(context: context)
    }

    private let plexService: PlexService
    private let preferences: UserPreferences
    private let context: String

    /// Server-side order of the hubs currently promoted to home, per section.
    /// Used to skip pushes that would not change anything.
    private var promotedOrderBySection: [String: [String]] = [:]
    private var syncTask: Task<Void, Never>?

    init(plexService: PlexService, preferences: UserPreferences, context: String) {
        self.plexService = plexService
        self.preferences = preferences
        self.context = context
    }

    // MARK: - Loading

    func load() async {
        if rows.isEmpty {
            isLoading = true
        }
        defer { isLoading = false }

        do {
            async let fetchedHubs = plexService.getHubs()
            async let fetchedLibraries = plexService.getLibraries()
            async let liveTVAvailable = hasLiveTV()

            let hubs = try await fetchedHubs.filter { hub in
                !HomeHubFilter.shouldHide(hub: hub)
                    && hub.items.contains { !HomeHubFilter.shouldHide(item: $0) }
            }
            let libraries = try await fetchedLibraries.filter { $0.libraryType != nil }
            let managedHubs = await loadManagedHubs(libraries: libraries)

            rows = buildRows(
                hubs: hubs,
                managedHubs: managedHubs,
                includesLiveTV: await liveTVAvailable
            )
            isFeaturedVisible = !preferences.isHomeRowHidden(
                HomeLayoutRowID.featured,
                context: context
            )
            syncsToPlex = !managedHubs.isEmpty
            error = nil
        } catch {
            if rows.isEmpty {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: - Editing

    func setFeaturedVisible(_ isVisible: Bool) {
        isFeaturedVisible = isVisible
        preferences.setHomeRowHidden(
            !isVisible,
            rowID: HomeLayoutRowID.featured,
            context: context
        )
    }

    func setVisible(_ isVisible: Bool, rowID: String) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }

        rows[index].isVisible = isVisible

        guard let managed = rows[index].managed, plexService.canManageHubs else {
            preferences.setHomeRowHidden(!isVisible, rowID: rowID, context: context)
            return
        }

        // Plex owns this row's visibility, so no local override is kept. A
        // stale one from an earlier failure is cleared here.
        preferences.setHomeRowHidden(false, rowID: rowID, context: context)

        enqueueSync { [weak self] in
            guard let self else { return }

            do {
                try await plexService.setManagedHubVisibility(
                    sectionID: managed.sectionID,
                    identifier: managed.identifier,
                    promotedToOwnHome: isVisible,
                    promotedToRecommended: managed.promotedToRecommended,
                    promotedToSharedHome: managed.promotedToSharedHome
                )
                // Promoting a hub lands it wherever Plex chooses, so the
                // section's order is reasserted rather than compared.
                promotedOrderBySection.removeValue(forKey: managed.sectionID)
                try await pushOrder(sections: [managed.sectionID])
                syncWarning = nil
            } catch {
                fallBackToDeviceLayout(
                    hidden: !isVisible,
                    rowID: rowID,
                    error: error
                )
            }
        }
    }

    func move(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        rows.move(fromOffsets: offsets, toOffset: destination)
        preferences.setHomeRowOrder(rows.map(\.id), context: context)
        pushOrderToPlex()
    }

    /// Moves one row to an absolute position and saves the Dusk layout, without
    /// touching Plex.
    ///
    /// tvOS walks a row through the list one position at a time, so the Plex write
    /// waits for `pushOrderToPlex()` when the row is dropped; pushing per step
    /// would send a request for every remote swipe. Returns whether the row
    /// actually moved, so a step past either end of the list is a no-op.
    @discardableResult
    func moveRow(id rowID: String, toIndex destination: Int) -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == rowID }),
              rows.indices.contains(destination),
              index != destination else {
            return false
        }

        let row = rows.remove(at: index)
        rows.insert(row, at: destination)
        preferences.setHomeRowOrder(rows.map(\.id), context: context)
        return true
    }

    /// Replays the current order onto Plex. Does nothing when the account cannot
    /// manage hubs or the server-side order already matches.
    func pushOrderToPlex() {
        guard plexService.canManageHubs else { return }

        let sections = Set(rows.compactMap { $0.managed?.sectionID })

        enqueueSync { [weak self] in
            guard let self else { return }

            do {
                try await pushOrder(sections: sections)
                syncWarning = nil
            } catch {
                syncWarning = Self.syncWarningMessage(for: error)
                homeLayoutLogger.notice(
                    "Could not push Home row order to Plex: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Drops the Dusk layout on this device and its iCloud peers. Rows Plex
    /// stores stay as they are on the server.
    func resetLayout() async {
        preferences.resetHomeLayout(context: context)
        syncWarning = nil
        await load()
    }

    // MARK: - Plex writes

    /// Replays the user's order onto Plex, one section at a time. Only the hubs
    /// that are actually on home are moved, so hiding a row never reshuffles a
    /// library's Recommended page behind the user's back.
    private func pushOrder(sections: Set<String>) async throws {
        var desiredBySection: [String: [String]] = [:]
        for row in rows where row.isVisible {
            guard let managed = row.managed, sections.contains(managed.sectionID) else { continue }
            desiredBySection[managed.sectionID, default: []].append(managed.identifier)
        }

        let changedSections = desiredBySection.filter { promotedOrderBySection[$0.key] != $0.value }
        guard !changedSections.isEmpty else { return }

        isSyncing = true
        defer { isSyncing = false }

        for (sectionID, identifiers) in changedSections {
            var previousIdentifier: String?
            for identifier in identifiers {
                try await plexService.moveManagedHub(
                    sectionID: sectionID,
                    identifier: identifier,
                    after: previousIdentifier
                )
                previousIdentifier = identifier
            }
            promotedOrderBySection[sectionID] = identifiers
        }
    }

    private func fallBackToDeviceLayout(hidden: Bool, rowID: String, error: Error) {
        preferences.setHomeRowHidden(hidden, rowID: rowID, context: context)
        syncWarning = Self.syncWarningMessage(for: error)
        homeLayoutLogger.notice(
            "Could not update Plex hub visibility: \(error.localizedDescription, privacy: .public)"
        )
    }

    /// Serializes writes so a burst of drags and toggles reaches Plex in the
    /// order the user made them.
    private func enqueueSync(_ work: @escaping () async -> Void) {
        let previousTask = syncTask
        syncTask = Task { @MainActor in
            await previousTask?.value
            await work()
        }
    }

    private static func syncWarningMessage(for error: Error) -> String {
        if let plexError = error as? PlexServiceError,
           plexError == .httpError(statusCode: 403) || plexError == .unauthorized {
            return "Your Plex account can't change this server's layout. The change is still saved for your Dusk devices through iCloud."
        }
        return "Couldn't save the managed row to Plex. The change is still saved for your Dusk devices through iCloud."
    }

    // MARK: - Row construction

    private func buildRows(
        hubs: [PlexHub],
        managedHubs: [ManagedHubEntry],
        includesLiveTV: Bool
    ) -> [Row] {
        // `GET /hubs` reports a section hub as `movie.topunwatched.1` while the
        // manage endpoint calls it `movie.topunwatched`. Custom collections
        // already carry their section id. Both spellings are registered so
        // either payload matches.
        var referencesByRowID: [String: ManagedReference] = [:]
        var ambiguousRowIDs: Set<String> = []

        for entry in managedHubs {
            let reference = entry.reference
            referencesByRowID[
                HomeLayoutRowID.hub("\(reference.identifier).\(reference.sectionID)")
            ] = reference

            // Two libraries of the same type share hub identifiers, so the
            // section-less spelling only identifies a hub when it is unique.
            // Guessing a section here would write the layout to the wrong one.
            let bareRowID = HomeLayoutRowID.hub(reference.identifier)
            if referencesByRowID[bareRowID] != nil {
                ambiguousRowIDs.insert(bareRowID)
            } else {
                referencesByRowID[bareRowID] = reference
            }
        }

        for rowID in ambiguousRowIDs {
            referencesByRowID.removeValue(forKey: rowID)
        }

        var rows: [Row] = []
        var matchedIdentifiers: Set<String> = []

        if includesLiveTV {
            rows.append(
                Row(
                    id: HomeLayoutRowID.liveTV,
                    title: "On Now",
                    subtitle: "Live TV",
                    isVisible: true,
                    managed: nil
                )
            )
        }

        for hub in hubs {
            let rowID = HomeLayoutRowID.hub(hub)
            let reference = referencesByRowID[rowID]

            if let reference {
                matchedIdentifiers.insert(referenceKey(reference))
            }

            rows.append(
                Row(
                    id: rowID,
                    title: hub.title,
                    subtitle: reference?.libraryTitle,
                    isVisible: true,
                    managed: reference
                )
            )
        }

        // Hubs Plex is currently hiding from home never appear in `GET /hubs`.
        // Listing them is what makes the editor able to bring a row back.
        for entry in managedHubs where !entry.hub.promotedToOwnHome {
            let reference = entry.reference
            guard !matchedIdentifiers.contains(referenceKey(reference)) else { continue }

            rows.append(
                Row(
                    id: HomeLayoutRowID.hub("\(reference.identifier).\(reference.sectionID)"),
                    title: entry.hub.title,
                    subtitle: reference.libraryTitle,
                    isVisible: false,
                    managed: reference
                )
            )
        }

        rows.append(
            Row(
                id: HomeLayoutRowID.suggestions,
                title: "Suggestions",
                subtitle: "Picked for you by Dusk",
                isVisible: true,
                managed: nil
            )
        )

        let hiddenRows = preferences.hiddenHomeRows(context: context)
        let arrangedRows = HomeLayoutArrangement.arrange(
            rows,
            id: \.id,
            preferredOrder: preferences.homeRowOrder(context: context)
        )

        return arrangedRows.map { row in
            var row = row
            if hiddenRows.contains(row.id) {
                row.isVisible = false
            }
            return row
        }
    }

    private func referenceKey(_ reference: ManagedReference) -> String {
        "\(reference.sectionID)|\(reference.identifier)"
    }

    // MARK: - Plex reads

    private struct ManagedHubEntry: Sendable {
        let hub: PlexManagedHub
        let reference: ManagedReference
    }

    private func loadManagedHubs(libraries: [PlexLibrary]) async -> [ManagedHubEntry] {
        guard plexService.canManageHubs else { return [] }

        var entries: [ManagedHubEntry] = []
        var promotedOrder: [String: [String]] = [:]

        // A section that refuses the managed endpoint simply stays local-only;
        // one failure must not cost the whole editor.
        for library in libraries {
            guard let hubs = try? await plexService.getManagedHubs(sectionID: library.key) else {
                continue
            }

            promotedOrder[library.key] = hubs
                .filter(\.promotedToOwnHome)
                .map(\.identifier)

            entries.append(
                contentsOf: hubs.map { hub in
                    ManagedHubEntry(
                        hub: hub,
                        reference: ManagedReference(
                            sectionID: library.key,
                            identifier: hub.identifier,
                            libraryTitle: library.title,
                            promotedToRecommended: hub.promotedToRecommended,
                            promotedToSharedHome: hub.promotedToSharedHome
                        )
                    )
                }
            )
        }

        promotedOrderBySection = promotedOrder
        return entries
    }

    /// `try?` flattens the optional provider, so a `nil` here covers both "no
    /// Live TV on this server" and "discovery failed".
    private func hasLiveTV() async -> Bool {
        (try? await plexService.getLiveTVProvider()) != nil
    }
}
