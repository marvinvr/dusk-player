import Foundation

/// Account-level library order and hidden libraries, routed to the account's
/// `AccountPreferencesProviding` (docs/jellyfin/04-architecture.md §17). For
/// Plex that is the plex.tv `experience` user setting (`PlexAccountPreferences`).
///
/// Read is best effort. A missing setting, a 404, or an unparseable blob all
/// mean "this account never customized its order" and fall back to
/// `/library/sections` order. Only a genuine transport or auth failure sets
/// `orderUnavailable`.
extension MediaService {
    /// The signed-in account's preferences facet. One account until J-13
    /// adds linked ones.
    var accountPreferences: any AccountPreferencesProviding {
        primaryAccount.preferences
    }

    /// Cache identity of the current session. The pinned list is per account
    /// token (Plex Home members each have their own) and the sections are the
    /// ones the currently connected servers answered with, so both go in.
    ///
    /// The servers go in **in priority order**, not sorted: the unpinned tail of
    /// the effective order follows server priority, so reordering Server
    /// Priority has to invalidate the cache even though the same servers are
    /// connected.
    var libraryOrderCacheIdentity: String {
        let serverIDs = mergeServerIDs.joined(separator: ",")
        return "\(serverIDs.nilIfEmpty ?? "-")|\(activeProfileID ?? "-")"
    }

    /// Loads `/library/sections` from every connected server and the account's
    /// library layout, all in parallel, once per `(serverIDs|profileID)`.
    /// Concurrent callers share the same in-flight request set.
    ///
    /// Each server's sections are committed the moment they arrive, so the
    /// library list paints from the first server instead of the slowest. Throws
    /// only when *every* server's `/library/sections` failed; one failing server
    /// must never blank the others' libraries. A layout failure is swallowed
    /// and simply leaves the libraries in plain server order.
    @discardableResult
    func ensureLibraryOrderLoaded(force: Bool = false) async throws -> [Library] {
        let identity = libraryOrderCacheIdentity

        if !force, libraryOrder.state == .loaded, libraryOrder.matchesCacheIdentity(identity) {
            return libraryOrder.orderedSections
        }

        if !force, let existing = libraryOrder.loadTask {
            return try await existing.value
        }

        let task = Task { @MainActor [weak self] () throws -> [Library] in
            guard let self else { return [] }
            return try await self.performLibraryOrderLoad(identity: identity)
        }
        libraryOrder.loadTask = task

        do {
            let result = try await task.value
            libraryOrder.clearLoadTask(task)
            return result
        } catch {
            libraryOrder.clearLoadTask(task)
            throw error
        }
    }

    /// Re-reads the account's layout only, leaving the cached sections alone.
    /// Used when the Library Order screen opens (every write re-reads too),
    /// because the account is last-writer-wins and another client may have
    /// reordered since. Throws on a read failure.
    func refreshLibraryOrder() async throws {
        let identity = libraryOrderCacheIdentity
        let layout = try await accountPreferences.libraryLayout()
        libraryOrder.apply(layout: layout, identity: identity)
    }

    /// Read-modify-write of the account's library layout.
    ///
    /// `ordered` must be EVERY section of every connected server in the new
    /// order, including sections Dusk cannot browse (music, photos) — anything
    /// left out would lose its pin. `hidden` (library ids) sets each section's
    /// `isHidden`; nil leaves the flags as the account has them. Writes are
    /// serialized; each one re-reads the layout first and never writes from cache.
    func reorderLibraries(_ ordered: [Library], hidden: Set<String>? = nil) async throws {
        let previous = libraryOrder.writeTask

        let task = Task { @MainActor [weak self] () throws -> Void in
            // Wait for the predecessor whatever its outcome: a failed write must
            // not skip the queue for the next one.
            _ = await previous?.result
            guard let self else { return }
            try await self.performLibraryReorder(ordered, hidden: hidden)
        }
        libraryOrder.writeTask = task

        do {
            try await task.value
            libraryOrder.clearWriteTask(task)
        } catch {
            libraryOrder.clearWriteTask(task)
            throw error
        }
    }

    /// The hidden-library filter, once the account's flags are known. Waits for
    /// the shared library order load (a no-op once it is cached); if that
    /// cannot be read, nothing is known to be hidden.
    func loadedHiddenLibraryFilter(for scope: HiddenLibraryFilter.Scope = .everywhere) async -> HiddenLibraryFilter {
        _ = try? await ensureLibraryOrderLoaded()
        return libraryOrder.hiddenLibraryFilter(for: scope)
    }

    /// Applies the cached order to an already-fetched list, without any
    /// networking. Returns the list unchanged when nothing is cached.
    func effectiveLibraryOrder(for libraries: [Library]) -> [Library] {
        LibraryOrderArrangement.effectiveOrder(
            libraries: libraries,
            layout: libraryOrder.layout,
            machineIdentifiers: libraryOrder.machineIdentifiers
        )
    }

    // MARK: - Load

    private func performLibraryOrderLoad(identity: String) async throws -> [Library] {
        let serverIDs = mergeServerIDs
        libraryOrder.beginLoading(serverOrder: serverIDs)

        guard !serverIDs.isEmpty else {
            libraryOrder.finishLoading(
                layout: await loadLibraryLayoutIgnoringFailure(),
                identity: identity
            )
            return []
        }

        // The account layout and every server's sections race each other; the
        // layout is optional, so it is never awaited before the first section
        // commit.
        async let layoutResult = loadLibraryLayoutIgnoringFailure()

        var failures: [String: any Error] = [:]
        // Result.capturing, not do/catch: this closure runs as a task group
        // child inside streamAcrossServers (see Result.capturing).
        for await result in streamAcrossServers({ service, serverID in
            await Result<[Library], any Error>.capturing {
                try await service.getLibraries(serverID: serverID)
            }
        }) {
            switch result.value {
            case let .success(sections):
                libraryOrder.applyServerSections(sections, serverID: result.serverID)
            case let .failure(error):
                failures[result.serverID] = error
                libraryOrder.applyServerSections(nil, serverID: result.serverID)
            }
        }

        let layout = await layoutResult

        // Only a total blackout is an error. One failing server leaves the
        // others' libraries on screen and is surfaced as a partial-outage note.
        if failures.count == serverIDs.count, let error = failures.values.first {
            libraryOrder.failLoading(error.localizedDescription)
            throw error
        }

        libraryOrder.finishLoading(layout: layout, identity: identity)
        return libraryOrder.orderedSections
    }

    /// nil = the layout could not be read at all (transport/auth). An empty
    /// but non-nil result means the account simply never customized its order.
    private func loadLibraryLayoutIgnoringFailure() async -> AccountLibraryLayout? {
        do {
            return try await accountPreferences.libraryLayout()
        } catch {
            LibraryOrderStore.logFailure("read", error: error)
            return nil
        }
    }

    // MARK: - Write

    private func performLibraryReorder(_ ordered: [Library], hidden: Set<String>?) async throws {
        // HARD INVARIANT: only servers that actually answered `/library/sections`
        // with sections this session may have their pins rewritten. A server
        // whose fetch failed looks identical to one with no libraries, and
        // writing that would unpin its libraries in every Plex client the
        // account uses. The same goes for a server that answered with nothing
        // (`LibraryOrderStore.machineIdentifiers` leaves it out); the provider
        // also drops one that is not connected at all.
        let serverIDs = libraryOrder.machineIdentifiers.subtracting(libraryOrder.failedServerIDs)
        let identity = libraryOrderCacheIdentity
        let written = try await accountPreferences.saveLibraryLayout(
            ordered,
            hidden: hidden,
            serverIDs: serverIDs,
            didRead: { [libraryOrder] layout in
                // The re-read before the write lands in the store whatever the
                // write's outcome, as a Library Order screen refresh would.
                libraryOrder.apply(layout: layout, identity: identity)
            }
        )
        libraryOrder.commitWrite(layout: written)
    }
}
