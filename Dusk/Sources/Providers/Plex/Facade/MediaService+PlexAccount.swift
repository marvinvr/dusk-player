import Foundation

/// The Plex account glue on the facade: the account's state forwarders, its
/// persisted names and request constants. The state lives on the account's
/// provider (`plexAccount.state`); these forward to it so every caller reads
/// and writes exactly what it did when they were stored on the service.
/// Orchestration (sign-in, Plex Home switches, the connect pass) is in
/// `MediaService+Auth`, `+Home` and `+Servers`.
extension MediaService {
    /// The Plex account. One per install until J-13 links others.
    var plexAccount: PlexAccountProvider {
        accountProvider as! PlexAccountProvider
    }

    var client: PlexClient { plexAccount.client }

    /// `currentUser` for the account row.
    var signedInUser: AccountUser? {
        currentUser.map {
            AccountUser(username: $0.username, title: $0.title, friendlyName: $0.friendlyName, thumb: $0.thumb, email: $0.email)
        }
    }

    /// Durable credential created by the normal Plex sign-in flow. This token
    /// belongs to the linked full account and is the only credential allowed to
    /// enumerate or switch Plex Home members.
    var primaryAccountToken: String? {
        get { plexAccount.state.primaryAccountToken }
        set { plexAccount.state.primaryAccountToken = newValue }
    }
    /// Credential used for account-scoped API calls in the current session.
    /// It equals `primaryAccountToken` outside Plex Home and becomes the token
    /// returned by the Home switch endpoint for another member.
    var activeAccountToken: String? {
        get { plexAccount.state.activeAccountToken }
        set { plexAccount.state.activeAccountToken = newValue }
    }
    var authTokenUpdatedAt: Date? {
        get { plexAccount.state.authTokenUpdatedAt }
        set { plexAccount.state.authTokenUpdatedAt = newValue }
    }
    var currentUser: PlexUser? {
        get { plexAccount.state.currentUser }
        set { plexAccount.state.currentUser = newValue }
    }
    var homeUsers: [PlexHomeUser] {
        get { plexAccount.state.homeUsers }
        set { plexAccount.state.homeUsers = newValue }
    }
    var activeHomeUser: PlexHomeUser? {
        get { plexAccount.state.activeHomeUser }
        set { plexAccount.state.activeHomeUser = newValue }
    }
    var homeBootstrapCompleted: Bool {
        get { plexAccount.state.homeBootstrapCompleted }
        set { plexAccount.state.homeBootstrapCompleted = newValue }
    }
    /// Cached identity is usable offline; Plex Home still needs online validation.
    var isUsingOfflineHomeSession: Bool {
        get { plexAccount.state.isUsingOfflineHomeSession }
        set { plexAccount.state.isUsingOfflineHomeSession = newValue }
    }
    var homeSelectionRequested: Bool {
        get { plexAccount.state.homeSelectionRequested }
        set { plexAccount.state.homeSelectionRequested = newValue }
    }
    var primaryProfileID: String? {
        get { plexAccount.state.primaryProfileID }
        set { plexAccount.state.primaryProfileID = newValue }
    }
    var hasRememberedHomeUserToken: Bool {
        get { plexAccount.state.hasRememberedHomeUserToken }
        set { plexAccount.state.hasRememberedHomeUserToken = newValue }
    }

    var hasPlexHome: Bool { plexAccount.state.hasPlexHome }
    var needsHomeUserSelection: Bool { plexAccount.state.needsHomeUserSelection }
    /// Every set persists the choice (and the remembered member token), as the
    /// stored property's `didSet` did; `PlexAccountProvider.restoreCredentials`
    /// runs the same step for the launch-time assignment.
    var automaticHomeSignIn: Bool {
        get { plexAccount.state.automaticHomeSignIn }
        set {
            plexAccount.state.automaticHomeSignIn = newValue
            automaticHomeSignInDidChange()
        }
    }
    var bootstrapNetworkAvailable: Bool {
        get { plexAccount.state.bootstrapNetworkAvailable }
        set { plexAccount.state.bootstrapNetworkAvailable = newValue }
    }

    // MARK: - Persisted names and constants

    static var plexTVBase: String { PlexAccountProvider.plexTVBase }
    /// Kept at the legacy name so existing users' linked-account credential
    /// migrates without requiring another sign-in.
    static let keychainTokenKey = PlexAccountProvider.keychainTokenKey
    static let keychainActiveHomeTokenKey = PlexAccountProvider.keychainActiveHomeTokenKey
    static let defaultsClientIDKey = "PlexClientIdentifier"
    // The four keys below are the single-server layout. Nothing writes them any
    // more: they are read once by `migrateLegacySingleServerState()` and then
    // deleted, and `ServerPool` reuses their names as the prefix of its
    // per-server keys ("PlexServerURL.<id>", …) so an install keeps one
    // recognisable namespace.
    static let keychainServerTokenKey = "PlexServerAuthToken"
    static let defaultsServerURLKey = "PlexServerURL"
    static let defaultsServerDataKey = "PlexServerData"
    static let defaultsLastGoodConnectionURIKey = "PlexLastGoodConnectionURI"
    /// Legacy selection, still read by `ServerPriorityStore` to seed the first
    /// priority order. Only sign-out removes it.
    static let defaultsServerIDKey = "PlexServerID"
    static let defaultsActiveHomeUserDataKey = PlexAccountProvider.defaultsActiveHomeUserDataKey
    static let defaultsAutomaticHomeSignInKey = PlexAccountProvider.defaultsAutomaticHomeSignInKey
    static let defaultsHomeMigrationCompletedKey = PlexAccountProvider.defaultsHomeMigrationCompletedKey
    static let defaultsPrimaryProfileIDKey = PlexAccountProvider.defaultsPrimaryProfileIDKey
    static let authenticationPropagationRetryWindow = PlexAccountProvider.authenticationPropagationRetryWindow
    static let authenticationPropagationRetryAttempts = PlexAccountProvider.authenticationPropagationRetryAttempts
    /// The shared session's whole-request budget (`PlexClient.session`).
    static let requestResourceTimeout: TimeInterval = PlexClient.requestResourceTimeout
}
