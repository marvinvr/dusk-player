import Foundation

/// Account-level settings the server side keeps for the signed-in profile:
/// library order, hidden libraries and language defaults
/// (docs/jellyfin/04-architecture.md §13, §17).
///
/// One value per account. Caching, coalescing and the write queue are the
/// facade's (`MediaService+LibraryOrder`, `LibraryOrderStore`); a facet call
/// is one read or one write. The methods run on the main actor, where the
/// facade and its request routing live.
protocol AccountPreferencesProviding: Sendable {
    /// The account's library layout. An account that never customized it is
    /// `.neverCustomized`, not an error; only a transport or auth failure
    /// throws.
    @MainActor func libraryLayout() async throws -> AccountLibraryLayout

    /// Writes `order` (every library of every server in `serverIDs`, hidden
    /// ones included) as the account's layout. `hidden` (`Library.id`s) sets
    /// each written library's hidden flag; nil keeps the flags the account
    /// has.
    ///
    /// Only libraries of `serverIDs` may be rewritten: the facade passes the
    /// servers that answered with libraries this session, and the provider
    /// may narrow the set but never widen it. The layout is re-read first
    /// (never written from cache) and that read is handed to `didRead` before
    /// the write goes out, so a failed write still leaves the fresh read in
    /// the store. Returns the layout as written.
    @MainActor func saveLibraryLayout(
        _ order: [Library],
        hidden: Set<String>?,
        serverIDs: Set<String>,
        didRead: (AccountLibraryLayout) -> Void
    ) async throws -> AccountLibraryLayout

    /// The account's language defaults, nil when it has none to offer.
    @MainActor func languageDefaults() async throws -> AccountLanguageDefaults?
}

/// Where the account puts its libraries: its own order, and which ones it
/// hides. Entries are in the account's order and may repeat a library (the
/// first one decides) or name libraries of servers that are not connected;
/// `LibraryOrderArrangement` applies them to the connected servers' sections.
struct AccountLibraryLayout: Sendable, Equatable {
    struct Entry: Sendable, Hashable {
        let serverID: String
        /// The library's key on its server (`Library.key`).
        let libraryID: String
        let isHidden: Bool

        /// The `Library.id` this entry points at.
        var id: String { "\(serverID)|\(libraryID)" }
    }

    var entries: [Entry]

    static let neverCustomized = AccountLibraryLayout(entries: [])
}

/// The account's language settings in Dusk's terms. Dusk uses them as
/// defaults for Settings › Audio & Subtitles until the viewer picks something
/// in Dusk.
struct AccountLanguageDefaults: Equatable, Sendable {
    /// "" when the account turns automatic audio selection off (keep the
    /// title's original audio), nil when the account says nothing.
    var audioLanguage: String?
    var subtitleLanguage: String?
    var subtitleMode: SubtitleMode?

    init(audioLanguage: String?, subtitleLanguage: String?, subtitleMode: SubtitleMode?) {
        self.audioLanguage = audioLanguage
        self.subtitleLanguage = subtitleLanguage
        self.subtitleMode = subtitleMode
    }
}
