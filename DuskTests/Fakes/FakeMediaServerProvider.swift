import Foundation
@testable import Dusk

/// An in-memory server for view-model tests (docs/jellyfin/04-architecture.md
/// §5.5, 05-plan.md P0-19). A test fills the arrays and dictionaries below,
/// registers the server id with this provider's kind and hands
/// `FakeProviderFactory` to `MediaService`; every facade call for that id then
/// lands here instead of on a network.
///
/// Neutral domain types only. A member no test needs yet throws
/// `FakeProviderError.unsupported` (or returns nil/empty where the protocol
/// cannot throw); give it a backing store when a test needs it.
@MainActor
final class FakeMediaServerProvider: MediaServerProvider {
    nonisolated let descriptor: ServerDescriptor

    // MARK: Data the facets serve

    var permissions = ServerPermissions(
        canManageHomeRows: false,
        canInstallSubtitles: false,
        canDownload: false,
        canPlay: true,
        canEditPlaylists: true,
        ownerLabel: nil
    )
    var libraries: [Library] = []
    /// Library listings, by library id.
    var libraryItems: [String: [MediaItem]] = [:]
    /// By item id.
    var details: [String: MediaDetails] = [:]
    /// By show id.
    var seasons: [String: [Season]] = [:]
    /// By season id.
    var episodes: [String: [Episode]] = [:]
    var homeRows: [HomeRow] = []
    var continueWatching: [MediaItem] = []
    /// By library id.
    var libraryRows: [String: [HomeRow]] = [:]
    /// By row key.
    var rowItems: [String: [MediaItem]] = [:]
    /// Named apart from the `playlists` facet.
    var allPlaylists: [Playlist] = []
    /// By playlist id.
    var playlistEntries: [String: [PlaylistEntry]] = [:]

    // MARK: What the facets were asked

    struct WatchedWrite: Equatable {
        let item: MediaItemID
        let watched: Bool
    }

    /// Every facet call, as `#function`, in call order.
    private(set) var calls: [String] = []
    private(set) var watchedWrites: [WatchedWrite] = []
    private(set) var reports: [PlaybackReport] = []

    init(serverID: String, name: String = "Fake", kind: ProviderKind = .jellyfin) {
        descriptor = ServerDescriptor(id: serverID, name: name, kind: kind, version: nil, ownerLabel: nil)
    }

    func record(_ call: String) {
        calls.append(call)
    }

    func recordWatched(_ watched: Bool, item: MediaItemID) {
        watchedWrites.append(WatchedWrite(item: item, watched: watched))
    }

    func recordReport(_ report: PlaybackReport) {
        reports.append(report)
    }

    // MARK: Facets

    nonisolated var catalog: any CatalogProviding { FakeCatalog(server: self) }
    nonisolated var home: any HomeProviding { FakeHome(server: self) }
    nonisolated var playback: any PlaybackProviding { FakePlayback(server: self) }
    nonisolated var userData: any UserDataProviding { FakeUserData(server: self) }
    nonisolated var markers: any MarkerProviding { FakeMarkers(server: self) }
    nonisolated var images: any ImageProviding { FakeImages(server: self) }
    nonisolated var playlists: any PlaylistProviding { FakePlaylists(server: self) }
    nonisolated var downloads: any DownloadProviding { FakeDownloads(server: self) }
    nonisolated var liveTV: (any LiveTVProviding)? { nil }
    nonisolated var subtitleSearch: (any SubtitleSearchProviding)? { nil }
    nonisolated var rating: (any UserRatingProviding)? { nil }
}

enum FakeProviderError: Error, Equatable {
    /// The fake has no backing store for this member yet.
    case unsupported(String)
    /// The test did not seed this id.
    case notFound(String)
}

// MARK: - Factory

/// Serves one `FakeMediaServerProvider` for every seed of its kind: the facade
/// builds a provider per call for a server the pool does not know, and the
/// test's data and call records must survive that.
struct FakeProviderFactory: ProviderFactory {
    let provider: FakeMediaServerProvider

    var kind: ProviderKind { provider.descriptor.kind }

    func makeSignInFlow() -> any SignInFlow { FakeSignInFlow(kind: kind) }

    /// None: `AccountStore` reads every factory's accounts at launch.
    @MainActor func storedAccounts() -> [StoredAccount] { [] }

    func restoreAccount(from record: StoredAccount) -> any MediaAccountProvider {
        FakeAccountProvider(record: record)
    }

    func makeServerProvider(_ seed: ServerSessionSeed) -> any MediaServerProvider { provider }
}

struct FakeSignInFlow: SignInFlow {
    let kind: ProviderKind
    var productName: String { "Fake" }
}

/// An account with no servers, no profiles and no preferences.
final class FakeAccountProvider: MediaAccountProvider {
    let account: AccountDescriptor

    init(record: StoredAccount) {
        account = AccountDescriptor(id: record.id, kind: record.kind, displayName: record.displayName)
    }

    func servers() async throws -> [ServerCandidateSet] { [] }
    func probe(_ candidate: ConnectionCandidate, in set: ServerCandidateSet) async -> ProbeResult {
        .failed("FakeAccountProvider does not probe")
    }
    func signOut() async {}
    @MainActor func restoreCredentials(readsStoredSignIn: Bool) {}
    @MainActor func attach(recovering: any SessionRecovering) {}

    var profiles: any ProfileProviding { FakeProfiles() }
    var preferences: any AccountPreferencesProviding { FakeAccountPreferences() }
    var watchlist: (any WatchlistProviding)? { nil }
    @MainActor var seerrAuth: any SeerrAuthProviding { FakeSeerrAuth() }
}

struct FakeProfiles: ProfileProviding {
    @MainActor var canSwitch: Bool { false }
    @MainActor var all: [Profile] { [] }
    @MainActor var current: Profile? { nil }
}

struct FakeAccountPreferences: AccountPreferencesProviding {
    @MainActor func libraryLayout() async throws -> AccountLibraryLayout {
        throw FakeProviderError.unsupported(#function)
    }

    @MainActor func saveLibraryLayout(
        _ order: [Library],
        hidden: Set<String>?,
        serverIDs: Set<String>,
        didRead: (AccountLibraryLayout) -> Void
    ) async throws -> AccountLibraryLayout {
        throw FakeProviderError.unsupported(#function)
    }

    @MainActor func languageDefaults() async throws -> AccountLanguageDefaults? { nil }
}

struct FakeSeerrAuth: SeerrAuthProviding {
    func accepts(_ settings: SeerrPublicSettings) -> Bool { false }
    func login() -> SeerrLogin? { nil }
}

// MARK: - Catalog

@MainActor
struct FakeCatalog: CatalogProviding {
    let server: FakeMediaServerProvider

    nonisolated init(server: FakeMediaServerProvider) {
        self.server = server
    }

    func libraries() async throws -> [Library] {
        server.record(#function)
        return server.libraries
    }

    func items(
        libraryID: String,
        kind: LibraryKind?,
        start: Int,
        size: Int,
        sort: LibrarySortOption?,
        filter: LibraryFilter
    ) async throws -> [MediaItem] {
        server.record(#function)
        let all = server.libraryItems[libraryID] ?? []
        guard start < all.count else { return [] }
        return Array(all[start..<min(all.count, start + size)])
    }

    func itemCount(libraryID: String, kind: LibraryKind?, filter: LibraryFilter) async throws -> Int {
        server.record(#function)
        return server.libraryItems[libraryID]?.count ?? 0
    }

    func letterCounts(libraryID: String, kind: LibraryKind?, filter: LibraryFilter) async throws -> [LibraryLetterCount] {
        throw FakeProviderError.unsupported(#function)
    }

    func sortFields(for kind: LibraryKind?) -> [LibrarySortField] {
        LibrarySortField.fields(for: kind)
    }

    func filterFields(libraryID: String, includesCollection: Bool) async throws -> [LibraryFilterField] {
        throw FakeProviderError.unsupported(#function)
    }

    func filterChoices(for field: LibraryFilterField) async throws -> [LibraryFilterChoice] {
        throw FakeProviderError.unsupported(#function)
    }

    func genreChoices(libraryID: String) async throws -> [LibraryFilterChoice] {
        throw FakeProviderError.unsupported(#function)
    }

    func channelCollections(libraryID: String) async throws -> [MediaCollection] {
        throw FakeProviderError.unsupported(#function)
    }

    func collections(libraryID: String, start: Int, size: Int) async throws -> MediaItemPage {
        throw FakeProviderError.unsupported(#function)
    }

    func collectionItems(collectionID: String, start: Int, size: Int, sort: LibrarySortOption?) async throws -> MediaItemPage {
        throw FakeProviderError.unsupported(#function)
    }

    func collection(itemID: String) async throws -> MediaItem? {
        throw FakeProviderError.unsupported(#function)
    }

    func collectionMode(libraryID: String) async -> LibraryCollectionMode { .showItems }

    func details(itemID: String, checkFiles: Bool) async throws -> MediaDetails {
        server.record(#function)
        guard let details = server.details[itemID] else { throw FakeProviderError.notFound(itemID) }
        return details
    }

    func seasons(showID: String) async throws -> [Season] {
        server.record(#function)
        guard let seasons = server.seasons[showID] else { throw FakeProviderError.notFound(showID) }
        return seasons
    }

    func episodes(seasonID: String) async throws -> [Episode] {
        server.record(#function)
        guard let episodes = server.episodes[seasonID] else { throw FakeProviderError.notFound(seasonID) }
        return episodes
    }

    func allEpisodes(showID: String) async throws -> [Episode] {
        server.record(#function)
        guard let seasons = server.seasons[showID] else { throw FakeProviderError.notFound(showID) }
        return seasons.flatMap { server.episodes[$0.itemID] ?? [] }
    }

    func person(id: String) async throws -> PersonDetails {
        throw FakeProviderError.unsupported(#function)
    }

    func personMedia(id: String) async throws -> [MediaItem] {
        throw FakeProviderError.unsupported(#function)
    }

    func extras(itemID: String) async throws -> [Extra] {
        throw FakeProviderError.unsupported(#function)
    }

    func searchGroups(query: String) async throws -> [HomeRow] {
        throw FakeProviderError.unsupported(#function)
    }

    func items(matching ids: ExternalIDs, kind: MediaKind?, title: String?, year: Int?) async throws -> [MediaItem] {
        throw FakeProviderError.unsupported(#function)
    }

    func playbackHistory(
        libraryID: String,
        since: Date,
        limit: Int,
        pageSize: Int,
        accountID: Int?
    ) async throws -> [PlaybackHistoryEntry] {
        throw FakeProviderError.unsupported(#function)
    }

    func photoPage(libraryID: String, query: PhotoQuery, start: Int, size: Int) async throws -> PhotoPage {
        throw FakeProviderError.unsupported(#function)
    }
}

// MARK: - Home

@MainActor
struct FakeHome: HomeProviding {
    let server: FakeMediaServerProvider

    nonisolated init(server: FakeMediaServerProvider) {
        self.server = server
    }

    func homeRows() async throws -> [HomeRow] {
        server.record(#function)
        return server.homeRows
    }

    func continueWatching() async throws -> [MediaItem] {
        server.record(#function)
        return server.continueWatching
    }

    func libraryRows(libraryID: String, count: Int) async throws -> [HomeRow] {
        server.record(#function)
        return server.libraryRows[libraryID] ?? []
    }

    func promotedLibraryRows(libraryID: String, count: Int) async throws -> [HomeRow] {
        server.record(#function)
        return server.libraryRows[libraryID] ?? []
    }

    func rowItems(rowKey: String, start: Int, size: Int?) async throws -> [MediaItem] {
        server.record(#function)
        let all = server.rowItems[rowKey] ?? []
        guard start < all.count else { return [] }
        return Array(all[start..<min(all.count, start + (size ?? all.count))])
    }

    func managedRows(libraryID: String) async throws -> [ManagedHub] {
        throw FakeProviderError.unsupported(#function)
    }

    func setManagedRow(_ row: ManagedHub, libraryID: String) async throws {
        throw FakeProviderError.unsupported(#function)
    }

    func managedRow(for row: HomeRow, source: HomeRowSource, libraryIDs: [String]) async -> ManagedHomeRow? {
        nil
    }
}

// MARK: - Playback

@MainActor
struct FakePlayback: PlaybackProviding {
    let server: FakeMediaServerProvider

    nonisolated init(server: FakeMediaServerProvider) {
        self.server = server
    }

    nonisolated var traits: PlaybackTraits {
        PlaybackTraits(
            remuxNeedsAtmosSignalingPatch: false,
            remuxNeedsDolbyVisionBoxes: false,
            remuxNeedsVariantFilter: false,
            serverAppliesWatchedThreshold: false,
            persistsTrackChoiceFromReports: false
        )
    }

    nonisolated var credentialPolicy: any CredentialTransportPolicy { FakeCredentialPolicy() }

    func directPlayURL(for part: MediaPart) -> URL? { nil }

    func checkAccess(to url: URL) async -> PlaybackAccess { .allowed }

    func openServerStream(_ request: ServerStreamRequest) async throws -> ServerStream {
        throw FakeProviderError.unsupported(#function)
    }

    func confirm(_ stream: ServerStream) async -> StreamDecisions? { nil }

    func keepAlive(streamSessionID: String) async {
        server.record(#function)
    }

    func close(streamSessionID: String) async {
        server.record(#function)
    }

    func prepareTrackSelection(_ selection: TrackSelection, partID: String) async throws {
        throw FakeProviderError.unsupported(#function)
    }

    func sidecarSubtitleURL(for stream: MediaStream) -> URL? { nil }

    func prerolls(before itemID: String) async throws -> [MediaDetails] {
        throw FakeProviderError.unsupported(#function)
    }
}

/// Never carries a credential; its session only reaches `FakeNetworkRecorder`.
struct FakeCredentialPolicy: CredentialTransportPolicy {
    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeNetworkRecorder.self]
        return URLSession(configuration: configuration)
    }()

    func allowsCredential(in url: URL) -> Bool { false }
    func carriesCredential(_ request: URLRequest) -> Bool { false }
    func validate(_ request: URLRequest) throws {}
    func allowsRedirect(_ request: URLRequest, original: URLRequest?) -> Bool { false }
    var session: URLSession { Self.sharedSession }
}

// MARK: - User data, markers, images

@MainActor
struct FakeUserData: UserDataProviding {
    let server: FakeMediaServerProvider

    nonisolated init(server: FakeMediaServerProvider) {
        self.server = server
    }

    func report(_ event: PlaybackReport) async throws {
        server.record(#function)
        server.recordReport(event)
    }

    func setWatched(_ watched: Bool, item: MediaItemID, at date: Date?) async throws {
        server.record(#function)
        server.recordWatched(watched, item: item)
    }
}

@MainActor
struct FakeMarkers: MarkerProviding {
    let server: FakeMediaServerProvider

    nonisolated init(server: FakeMediaServerProvider) {
        self.server = server
    }

    func markers(for details: MediaDetails) -> [Marker] { details.markers }

    func scrubPreview(forPartID partID: String) async -> (any ScrubPreviewSource)? { nil }
}

@MainActor
struct FakeImages: ImageProviding {
    let server: FakeMediaServerProvider

    nonisolated init(server: FakeMediaServerProvider) {
        self.server = server
    }

    func url(for ref: ArtworkRef, size: ImageSize, session: ServerSession?) -> URL? { nil }

    func authenticatedRequest(for url: URL, session: ServerSession) -> URLRequest { URLRequest(url: url) }
}

// MARK: - Playlists

@MainActor
struct FakePlaylists: PlaylistProviding {
    let server: FakeMediaServerProvider

    nonisolated init(server: FakeMediaServerProvider) {
        self.server = server
    }

    func playlists() async throws -> [Playlist] {
        server.record(#function)
        return server.allPlaylists
    }

    func playlist(id: String) async throws -> Playlist? {
        server.record(#function)
        return server.allPlaylists.first { $0.itemID == id }
    }

    func entries(playlistID: String) async throws -> [PlaylistEntry] {
        server.record(#function)
        guard let entries = server.playlistEntries[playlistID] else { throw FakeProviderError.notFound(playlistID) }
        return entries
    }

    func createPlaylist(title: String, itemIDs: [String]) async throws -> Playlist {
        throw FakeProviderError.unsupported(#function)
    }

    func add(itemIDs: [String], to playlistID: String) async throws -> PlaylistAddResult {
        throw FakeProviderError.unsupported(#function)
    }

    func removeEntry(_ entryID: Int, from playlistID: String) async throws {
        throw FakeProviderError.unsupported(#function)
    }

    func moveEntry(_ entryID: Int, after afterEntryID: Int?, in playlistID: String) async throws {
        throw FakeProviderError.unsupported(#function)
    }

    func rename(playlistID: String, to title: String) async throws {
        throw FakeProviderError.unsupported(#function)
    }

    func delete(playlistID: String) async throws {
        throw FakeProviderError.unsupported(#function)
    }
}

// MARK: - Downloads

@MainActor
struct FakeDownloads: DownloadProviding {
    let server: FakeMediaServerProvider

    nonisolated init(server: FakeMediaServerProvider) {
        self.server = server
    }

    nonisolated func qualities(for item: MediaItemID) -> [DownloadQuality] { [] }

    func originalFileRequest(for part: MediaPart, directPlayURL: URL, credential: String) -> URLRequest? {
        URLRequest(url: directPlayURL)
    }

    func fetchSidecar(_ request: URLRequest) async throws -> (Data, URLResponse) {
        throw FakeProviderError.unsupported(#function)
    }

    func metadataSnapshot(_ key: MetadataSnapshotKey) async throws -> Data {
        throw FakeProviderError.unsupported(#function)
    }

    func conversionHeaders(clientIdentifier: String, credential: String) -> [String: String] { [:] }

    func createConversionQueue(via transport: any DownloadConversionTransport) async throws -> String {
        throw FakeProviderError.unsupported(#function)
    }

    func addConversionJob(
        queueID: String,
        itemID: String,
        mediaIndex: Int,
        quality: DownloadQuality,
        via transport: any DownloadConversionTransport
    ) async throws -> String {
        throw FakeProviderError.unsupported(#function)
    }

    func conversionJobs(queueID: String, via transport: any DownloadConversionTransport) async throws -> [ConversionJob] {
        throw FakeProviderError.unsupported(#function)
    }

    func conversionJob(
        queueID: String,
        jobID: String,
        via transport: any DownloadConversionTransport
    ) async throws -> ConversionJob {
        throw FakeProviderError.unsupported(#function)
    }

    func preparedConversion(
        queueID: String,
        jobID: String,
        sourceMedia: MediaVersion,
        via transport: any DownloadConversionTransport
    ) async throws -> ConvertedDownload {
        throw FakeProviderError.unsupported(#function)
    }

    func removeConversionJob(
        queueID: String,
        jobID: String,
        via transport: any DownloadConversionTransport
    ) async throws {
        throw FakeProviderError.unsupported(#function)
    }
}

// MARK: - Network guard

/// Fails every request and remembers its URL. Give it to
/// `MediaService(urlProtocolClasses:)` so a test can prove the facade reached
/// the fake and never a real server.
final class FakeNetworkRecorder: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [URL] = []

    static var requests: [URL] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            Self.lock.withLock { Self.seen.append(url) }
        }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

// MARK: - Domain builders

/// The neutral domain values with every optional field defaulted.
enum FakeMedia {
    static func item(
        serverID: String,
        itemID: String,
        type: MediaKind,
        title: String,
        index: Int? = nil,
        parentIndex: Int? = nil,
        parentID: String? = nil,
        grandparentID: String? = nil,
        grandparentTitle: String? = nil,
        duration: Int? = nil,
        playCount: Int? = nil,
        resumeOffsetMs: Int? = nil
    ) -> MediaItem {
        MediaItem(
            serverID: serverID, itemID: itemID, key: "/items/\(itemID)", type: type, subtype: nil,
            libraryID: nil, title: title, editionTitle: nil, summary: nil, studio: nil,
            contentRating: nil, year: nil, originallyAvailableAt: nil,
            thumb: nil, art: nil, banner: nil, clearLogo: nil, rating: nil, audienceRating: nil,
            duration: duration, playCount: playCount, resumeOffsetMs: resumeOffsetMs, lastPlayedAt: nil,
            addedAt: nil, updatedAt: nil, index: index, parentIndex: parentIndex, parentID: parentID,
            parentTitle: nil, parentThumb: nil, grandparentID: grandparentID,
            grandparentTitle: grandparentTitle, grandparentThumb: nil, grandparentArt: nil,
            episodeCount: nil, watchedEpisodeCount: nil, childCount: nil, smart: nil,
            genres: nil, directors: nil, writers: nil, roles: nil, guid: nil, guids: []
        )
    }

    static func details(
        serverID: String,
        itemID: String,
        type: MediaKind,
        title: String,
        index: Int? = nil,
        parentIndex: Int? = nil,
        parentID: String? = nil,
        grandparentID: String? = nil,
        grandparentTitle: String? = nil,
        duration: Int? = nil,
        playCount: Int? = nil,
        resumeOffsetMs: Int? = nil,
        childCount: Int? = nil,
        episodeCount: Int? = nil,
        watchedEpisodeCount: Int? = nil
    ) -> MediaDetails {
        MediaDetails(
            serverID: serverID, itemID: itemID, key: "/items/\(itemID)", type: type, subtype: nil,
            libraryID: nil, librarySectionTitle: nil, title: title, editionTitle: nil, summary: nil,
            year: nil, duration: duration, resumeOffsetMs: resumeOffsetMs, playCount: playCount,
            thumb: nil, art: nil, clearLogo: nil, contentRating: nil, primaryExtraKey: nil,
            rating: nil, audienceRating: nil, ratingImage: nil, audienceRatingImage: nil,
            userRating: nil, ratings: [], studio: nil, originallyAvailableAt: nil,
            childCount: childCount, episodeCount: episodeCount, watchedEpisodeCount: watchedEpisodeCount,
            index: index, parentIndex: parentIndex, parentID: parentID, parentThumb: nil,
            grandparentID: grandparentID, grandparentTitle: grandparentTitle, grandparentThumb: nil,
            genres: nil, directors: nil, writers: nil, roles: nil, collections: nil,
            guid: nil, guids: [], markers: [], media: []
        )
    }

    static func episode(
        serverID: String,
        itemID: String,
        title: String,
        index: Int,
        seasonIndex: Int = 1,
        seasonID: String? = nil,
        showID: String? = nil,
        showTitle: String? = nil,
        duration: Int? = 1_800_000,
        playCount: Int? = nil,
        resumeOffsetMs: Int? = nil
    ) -> Episode {
        Episode(
            serverID: serverID, itemID: itemID, key: "/items/\(itemID)", title: title,
            index: index, parentIndex: seasonIndex, parentID: seasonID, parentTitle: nil,
            grandparentID: showID, grandparentTitle: showTitle, grandparentThumb: nil,
            summary: nil, contentRating: nil, originallyAvailableAt: nil, year: nil,
            thumb: nil, art: nil, duration: duration, playCount: playCount,
            resumeOffsetMs: resumeOffsetMs, lastPlayedAt: nil, addedAt: nil, updatedAt: nil
        )
    }
}
