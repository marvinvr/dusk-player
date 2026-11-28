import Foundation

/// The account's server order and per-server on/off switch.
///
/// Priority decides which server plays an item that exists on several of them,
/// and in which order the fallbacks are tried. A disabled server is ignored
/// entirely: not connected, not merged, not searched.
///
/// The list is additive on purpose. A server that is temporarily missing from
/// discovery (offline, sharing revoked for a day) keeps its slot and its
/// enabled flag, so nothing silently reshuffles behind the user's back;
/// entries are only dropped on sign-out via `prune(keeping:)`.
@MainActor
@Observable
final class ServerPriorityStore {
    struct Entry: Codable, Hashable, Sendable {
        let machineIdentifier: String
        var isEnabled: Bool
    }

    static let defaultsKey = "PlexServerPriority"
    /// Legacy single-server selection, used to seed the first ordering.
    static let legacyServerIDKey = "PlexServerID"

    private(set) var entries: [Entry] = []

    /// Bumped on every mutation. Screens observe it to know they have to reload
    /// merged content, without caring what exactly changed.
    private(set) var revision: Int = 0

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = Self.load(from: defaults)
    }

    // MARK: - Reading

    var enabledIdentifiers: [String] {
        entries.filter(\.isEnabled).map(\.machineIdentifier)
    }

    func isEnabled(_ machineIdentifier: String) -> Bool {
        // Unknown servers are enabled until the user says otherwise; a server
        // that has just appeared must not be invisible.
        entries.first { $0.machineIdentifier == machineIdentifier }?.isEnabled ?? true
    }

    /// Position in the priority list. Unknown servers sort last.
    func rank(of machineIdentifier: String) -> Int {
        entries.firstIndex { $0.machineIdentifier == machineIdentifier } ?? Int.max
    }

    /// The enabled subset of `servers`, in priority order. Servers missing from
    /// the stored order keep their discovery order at the end.
    func enabledServers(from servers: [PlexServer]) -> [PlexServer] {
        servers
            .filter { isEnabled($0.clientIdentifier) }
            .enumerated()
            .sorted { lhs, rhs in
                let leftRank = rank(of: lhs.element.clientIdentifier)
                let rightRank = rank(of: rhs.element.clientIdentifier)
                if leftRank != rightRank { return leftRank < rightRank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Every known server in priority order, enabled or not.
    func ordered(_ servers: [PlexServer]) -> [PlexServer] {
        servers
            .enumerated()
            .sorted { lhs, rhs in
                let leftRank = rank(of: lhs.element.clientIdentifier)
                let rightRank = rank(of: rhs.element.clientIdentifier)
                if leftRank != rightRank { return leftRank < rightRank }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: - Mutation

    /// Folds a fresh discovery result into the stored order: unknown servers are
    /// appended enabled, known ones keep their slot and flag, and nothing is
    /// removed just because it did not answer this time.
    func reconcile(discovered: [PlexServer]) {
        let known = Set(entries.map(\.machineIdentifier))
        let appended = discovered
            .map(\.clientIdentifier)
            .filter { !known.contains($0) && !$0.isEmpty }

        guard !appended.isEmpty else { return }

        var seen = known
        for identifier in appended where seen.insert(identifier).inserted {
            entries.append(Entry(machineIdentifier: identifier, isEnabled: true))
        }
        commit()
    }

    func setEnabled(_ isEnabled: Bool, for machineIdentifier: String) {
        if let index = entries.firstIndex(where: { $0.machineIdentifier == machineIdentifier }) {
            guard entries[index].isEnabled != isEnabled else { return }
            entries[index].isEnabled = isEnabled
        } else {
            entries.append(Entry(machineIdentifier: machineIdentifier, isEnabled: isEnabled))
        }
        commit()
    }

    /// iOS list reordering (`onMove`).
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
        commit()
    }

    /// tvOS reordering, which has no drag gesture and moves one row at a time.
    func move(_ machineIdentifier: String, to destination: Int) {
        guard let index = entries.firstIndex(where: { $0.machineIdentifier == machineIdentifier }) else {
            return
        }
        let clamped = max(0, min(destination, entries.count - 1))
        guard clamped != index else { return }
        let entry = entries.remove(at: index)
        entries.insert(entry, at: clamped)
        commit()
    }

    /// Applies an order decided over a subset of the list — the servers the UI
    /// can actually show. Entries the caller did not mention (a server missing
    /// from this discovery pass) keep their absolute slot, so reordering what
    /// is on screen never quietly demotes what is not.
    func reorder(visible identifiers: [String]) {
        let visible = Set(identifiers)
        var queue = identifiers
        var updated: [Entry] = []

        for entry in entries {
            guard visible.contains(entry.machineIdentifier) else {
                updated.append(entry)
                continue
            }
            guard !queue.isEmpty else { continue }
            let next = queue.removeFirst()
            updated.append(
                entries.first { $0.machineIdentifier == next }
                    ?? Entry(machineIdentifier: next, isEnabled: true)
            )
        }

        // Anything the store had never seen lands at the end, in the order it
        // was handed in.
        for identifier in queue {
            updated.append(Entry(machineIdentifier: identifier, isEnabled: isEnabled(identifier)))
        }

        guard updated != entries else { return }
        entries = updated
        commit()
    }

    /// Drops everything the account no longer has. Only sign-out should call
    /// this; a server missing from one discovery pass is not gone.
    func prune(keeping machineIdentifiers: Set<String>) {
        let filtered = entries.filter { machineIdentifiers.contains($0.machineIdentifier) }
        guard filtered.count != entries.count else { return }
        entries = filtered
        commit()
    }

    func reset() {
        guard !entries.isEmpty else { return }
        entries = []
        defaults.removeObject(forKey: Self.defaultsKey)
        revision &+= 1
    }

    // MARK: - Persistence

    private func commit() {
        revision &+= 1
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    private static func load(from defaults: UserDefaults) -> [Entry] {
        if let data = defaults.data(forKey: defaultsKey),
           let stored = try? JSONDecoder().decode([Entry].self, from: data) {
            return stored
        }

        // First launch after the multi-server change: the server the user was
        // already on becomes the top priority, so nothing appears to move.
        if let legacy = defaults.string(forKey: legacyServerIDKey)?.nilIfEmpty {
            return [Entry(machineIdentifier: legacy, isEnabled: true)]
        }

        return []
    }
}
