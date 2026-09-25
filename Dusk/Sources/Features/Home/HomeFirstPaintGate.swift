import Foundation

/// Decides when Home's first merge is complete enough to put on screen.
///
/// Painting the first server's answer immediately is fast but unstable: if that
/// server has nothing in progress and the next one does, the cinematic hero
/// appears a moment later and pushes the whole screen down. Waiting for every
/// server is stable but lets one slow or unreachable share hold Home hostage.
///
/// The gate sits between the two. Once there is something to show it waits a
/// short grace for the rest of the servers (and the account's library order) to
/// catch up, which absorbs the usual LAN-versus-LAN spread. Only when the servers
/// that had Continue Watching last time are still missing — and nothing that has
/// answered has any — does it wait longer, because that is the one late arrival
/// that changes the shape of the screen rather than just adding a row. Either
/// way the first paint never comes later than `patience` after Home started
/// waiting; whatever arrives after that folds in as it lands.
struct HomeFirstPaintGate {
    /// How long the first content waits for the rest of the servers.
    static let settleGrace: Duration = .milliseconds(500)
    /// The hard cap on holding a paintable screen back, measured from when Home
    /// started waiting.
    static let patience: Duration = .seconds(3)

    enum Decision: Equatable {
        case paint
        /// `nil` when there is nothing to paint yet, so no deadline applies.
        case wait(until: ContinuousClock.Instant?)
    }

    let startedAt: ContinuousClock.Instant

    /// - Parameters:
    ///   - hasContent: the merge in hand has something Home would render.
    ///   - hasHero: the merge in hand has an item the cinematic hero would show.
    ///   - firstContentAt: when the merge first had content.
    ///   - isSettled: nothing else is still expected — every server has answered,
    ///     the library order is known, and no server is still connecting.
    ///   - isAwaitingRememberedHero: a server that had Continue Watching the last
    ///     time Home settled has not answered yet and may still.
    func decide(
        now: ContinuousClock.Instant,
        hasContent: Bool,
        hasHero: Bool,
        firstContentAt: ContinuousClock.Instant?,
        isSettled: Bool,
        isAwaitingRememberedHero: Bool
    ) -> Decision {
        guard hasContent, let firstContentAt else { return .wait(until: nil) }
        guard !isSettled else { return .paint }

        let cap = startedAt + Self.patience
        let deadline = isAwaitingRememberedHero && !hasHero
            ? cap
            : min(firstContentAt + Self.settleGrace, cap)

        return now >= deadline ? .paint : .wait(until: deadline)
    }
}

/// Which servers had Continue Watching the last time Home settled, per Plex Home
/// profile, so the next launch knows whose answer is worth waiting for.
///
/// A hint, not a record: a server that drops out simply stops being waited for
/// after the next settled load, and a stale entry costs at most one
/// `HomeFirstPaintGate.patience`.
enum HomeContinueWatchingMemory {
    private static let defaultsKey = "HomeContinueWatchingServerIDs"

    static func serverIDs(profileID: String?) -> Set<String> {
        let stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String]]
        return Set(stored?[profileKey(profileID)] ?? [])
    }

    static func remember(_ serverIDs: Set<String>, profileID: String?) {
        var stored = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
        let key = profileKey(profileID)
        let sorted = serverIDs.sorted()
        guard (stored[key] ?? []) != sorted else { return }
        stored[key] = sorted.isEmpty ? nil : sorted
        UserDefaults.standard.set(stored, forKey: defaultsKey)
    }

    private static func profileKey(_ profileID: String?) -> String {
        profileID?.nilIfEmpty ?? "-"
    }
}
