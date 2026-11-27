import Foundation

// Server identity, envelopes, sign-in and users.
// docs/jellyfin/02-jellyfin-api-mapping.md §0, §1; 03-prior-art.md §7.

/// `{Items, TotalRecordCount, StartIndex}`. `Items` is required: a body
/// without it is not the list that was asked for.
struct JellyfinQueryResult<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]
    let totalRecordCount: Int?
    let startIndex: Int?

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
        case startIndex = "StartIndex"
    }
}

/// `GET /System/Info/Public` (no auth). `id` is the server identity used by
/// the probe's identity gate.
struct JellyfinPublicSystemInfoDTO: Codable, Hashable, Sendable {
    let id: String
    let serverName: String?
    let version: String?
    let productName: String?
    let localAddress: String?
    let operatingSystem: String?
    let startupWizardCompleted: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case serverName = "ServerName"
        case version = "Version"
        case productName = "ProductName"
        case localAddress = "LocalAddress"
        case operatingSystem = "OperatingSystem"
        case startupWizardCompleted = "StartupWizardCompleted"
    }
}

/// `GET /System/Endpoint`: whether this connection is local.
struct JellyfinEndpointInfoDTO: Codable, Hashable, Sendable {
    let isLocal: Bool?
    let isInNetwork: Bool?

    enum CodingKeys: String, CodingKey {
        case isLocal = "IsLocal"
        case isInNetwork = "IsInNetwork"
    }
}

// MARK: - Sign-in

/// `POST /Users/AuthenticateByName` body.
struct JellyfinAuthenticateByNameDTO: Encodable, Sendable {
    let username: String
    let password: String

    enum CodingKeys: String, CodingKey {
        case username = "Username"
        case password = "Pw"
    }
}

/// `POST /Users/AuthenticateWithQuickConnect` body.
struct JellyfinQuickConnectAuthenticateDTO: Encodable, Sendable {
    let secret: String

    enum CodingKeys: String, CodingKey {
        case secret = "Secret"
    }
}

/// Answer of both sign-in calls.
struct JellyfinAuthenticationResultDTO: Decodable, Sendable {
    let accessToken: String
    let serverID: String?
    let user: JellyfinUserDTO
    let sessionInfo: JellyfinSessionInfoDTO?

    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case serverID = "ServerId"
        case user = "User"
        case sessionInfo = "SessionInfo"
    }
}

/// `POST /QuickConnect/Initiate` and `GET /QuickConnect/Connect?secret=`.
/// `code` is the six digits the user types on the approving device.
struct JellyfinQuickConnectResultDTO: Decodable, Hashable, Sendable {
    let authenticated: Bool
    let secret: String
    let code: String?
    let deviceID: String?
    let deviceName: String?
    let appName: String?
    let appVersion: String?
    let dateAdded: JellyfinDate?

    enum CodingKeys: String, CodingKey {
        case authenticated = "Authenticated"
        case secret = "Secret"
        case code = "Code"
        case deviceID = "DeviceId"
        case deviceName = "DeviceName"
        case appName = "AppName"
        case appVersion = "AppVersion"
        case dateAdded = "DateAdded"
    }
}

// MARK: - Users

/// `GET /Users/Me`, `GET /Users/Public` entries, `AuthenticationResult.User`.
struct JellyfinUserDTO: Decodable, Hashable, Sendable {
    let id: String
    let name: String?
    let serverID: String?
    let primaryImageTag: String?
    let hasPassword: Bool?
    let hasConfiguredPassword: Bool?
    let enableAutoLogin: Bool?
    let lastLoginDate: JellyfinDate?
    let lastActivityDate: JellyfinDate?
    let configuration: JellyfinUserConfigurationDTO?
    let policy: JellyfinUserPolicyDTO?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case serverID = "ServerId"
        case primaryImageTag = "PrimaryImageTag"
        case hasPassword = "HasPassword"
        case hasConfiguredPassword = "HasConfiguredPassword"
        case enableAutoLogin = "EnableAutoLogin"
        case lastLoginDate = "LastLoginDate"
        case lastActivityDate = "LastActivityDate"
        case configuration = "Configuration"
        case policy = "Policy"
    }
}

/// `User.Configuration`: language defaults, library order and exclusions.
/// Also the body of `POST /Users/Configuration`, so it round-trips.
struct JellyfinUserConfigurationDTO: Codable, Hashable, Sendable {
    var audioLanguagePreference: String?
    var subtitleLanguagePreference: String?
    var subtitleMode: JellyfinSubtitleMode?
    var playDefaultAudioTrack: Bool?
    var rememberAudioSelections: Bool?
    var rememberSubtitleSelections: Bool?
    var enableNextEpisodeAutoPlay: Bool?
    var displayMissingEpisodes: Bool?
    var hidePlayedInLatest: Bool?
    var orderedViews: [String]?
    var myMediaExcludes: [String]?
    var latestItemsExcludes: [String]?
    var groupedFolders: [String]?

    enum CodingKeys: String, CodingKey {
        case audioLanguagePreference = "AudioLanguagePreference"
        case subtitleLanguagePreference = "SubtitleLanguagePreference"
        case subtitleMode = "SubtitleMode"
        case playDefaultAudioTrack = "PlayDefaultAudioTrack"
        case rememberAudioSelections = "RememberAudioSelections"
        case rememberSubtitleSelections = "RememberSubtitleSelections"
        case enableNextEpisodeAutoPlay = "EnableNextEpisodeAutoPlay"
        case displayMissingEpisodes = "DisplayMissingEpisodes"
        case hidePlayedInLatest = "HidePlayedInLatest"
        case orderedViews = "OrderedViews"
        case myMediaExcludes = "MyMediaExcludes"
        case latestItemsExcludes = "LatestItemsExcludes"
        case groupedFolders = "GroupedFolders"
    }
}

/// `User.Policy`: the source of `ServerPermissions`.
struct JellyfinUserPolicyDTO: Decodable, Hashable, Sendable {
    let isAdministrator: Bool?
    let isDisabled: Bool?
    let isHidden: Bool?
    let enableCollectionManagement: Bool?
    let enableSubtitleManagement: Bool?
    let enableContentDownloading: Bool?
    let enableLiveTvAccess: Bool?
    let enableLiveTvManagement: Bool?
    let enableMediaPlayback: Bool?
    let enablePlaybackRemuxing: Bool?
    let enableVideoPlaybackTranscoding: Bool?
    let enableAudioPlaybackTranscoding: Bool?
    let enableRemoteAccess: Bool?
    let enableUserPreferenceAccess: Bool?
    let enableContentDeletion: Bool?
    let enableAllFolders: Bool?
    let enabledFolders: [String]?
    let blockedMediaFolders: [String]?
    let remoteClientBitrateLimit: Int?
    let maxActiveSessions: Int?

    enum CodingKeys: String, CodingKey {
        case isAdministrator = "IsAdministrator"
        case isDisabled = "IsDisabled"
        case isHidden = "IsHidden"
        case enableCollectionManagement = "EnableCollectionManagement"
        case enableSubtitleManagement = "EnableSubtitleManagement"
        case enableContentDownloading = "EnableContentDownloading"
        case enableLiveTvAccess = "EnableLiveTvAccess"
        case enableLiveTvManagement = "EnableLiveTvManagement"
        case enableMediaPlayback = "EnableMediaPlayback"
        case enablePlaybackRemuxing = "EnablePlaybackRemuxing"
        case enableVideoPlaybackTranscoding = "EnableVideoPlaybackTranscoding"
        case enableAudioPlaybackTranscoding = "EnableAudioPlaybackTranscoding"
        case enableRemoteAccess = "EnableRemoteAccess"
        case enableUserPreferenceAccess = "EnableUserPreferenceAccess"
        case enableContentDeletion = "EnableContentDeletion"
        case enableAllFolders = "EnableAllFolders"
        case enabledFolders = "EnabledFolders"
        case blockedMediaFolders = "BlockedMediaFolders"
        case remoteClientBitrateLimit = "RemoteClientBitrateLimit"
        case maxActiveSessions = "MaxActiveSessions"
    }
}

// MARK: - Sessions

/// `GET /Sessions?deviceId=` entries and `AuthenticationResult.SessionInfo`.
/// `transcodingInfo` is the authoritative "was it really a copy" answer
/// (03 §5.1 item 8).
struct JellyfinSessionInfoDTO: Decodable, Sendable {
    let id: String?
    let userID: String?
    let userName: String?
    let client: String?
    let deviceID: String?
    let deviceName: String?
    let applicationVersion: String?
    let isActive: Bool?
    let supportsMediaControl: Bool?
    let playableMediaTypes: [JellyfinMediaType]?
    let lastActivityDate: JellyfinDate?
    let playState: JellyfinPlayStateDTO?
    let nowPlayingItem: JellyfinItemDTO?
    let transcodingInfo: JellyfinTranscodingInfoDTO?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case userID = "UserId"
        case userName = "UserName"
        case client = "Client"
        case deviceID = "DeviceId"
        case deviceName = "DeviceName"
        case applicationVersion = "ApplicationVersion"
        case isActive = "IsActive"
        case supportsMediaControl = "SupportsMediaControl"
        case playableMediaTypes = "PlayableMediaTypes"
        case lastActivityDate = "LastActivityDate"
        case playState = "PlayState"
        case nowPlayingItem = "NowPlayingItem"
        case transcodingInfo = "TranscodingInfo"
    }
}

struct JellyfinPlayStateDTO: Decodable, Hashable, Sendable {
    let positionTicks: JellyfinTicks?
    let canSeek: Bool?
    let isPaused: Bool?
    let isMuted: Bool?
    let mediaSourceID: String?
    let audioStreamIndex: Int?
    let subtitleStreamIndex: Int?
    let playMethod: JellyfinPlayMethod?
    let playSessionID: String?

    enum CodingKeys: String, CodingKey {
        case positionTicks = "PositionTicks"
        case canSeek = "CanSeek"
        case isPaused = "IsPaused"
        case isMuted = "IsMuted"
        case mediaSourceID = "MediaSourceId"
        case audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex"
        case playMethod = "PlayMethod"
        case playSessionID = "PlaySessionId"
    }
}

/// `SessionInfo.TranscodingInfo`. `transcodeReasons` arrives as an array of
/// names on current servers and as one comma-separated string on older ones;
/// both decode.
struct JellyfinTranscodingInfoDTO: Decodable, Hashable, Sendable {
    let isVideoDirect: Bool?
    let isAudioDirect: Bool?
    let videoCodec: String?
    let audioCodec: String?
    let container: String?
    let bitrate: Int?
    let width: Int?
    let height: Int?
    let audioChannels: Int?
    let hardwareAccelerationType: String?
    let transcodeReasons: [JellyfinTranscodeReason]

    enum CodingKeys: String, CodingKey {
        case isVideoDirect = "IsVideoDirect"
        case isAudioDirect = "IsAudioDirect"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
        case container = "Container"
        case bitrate = "Bitrate"
        case width = "Width"
        case height = "Height"
        case audioChannels = "AudioChannels"
        case hardwareAccelerationType = "HardwareAccelerationType"
        case transcodeReasons = "TranscodeReasons"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isVideoDirect = try container.decodeIfPresent(Bool.self, forKey: .isVideoDirect)
        isAudioDirect = try container.decodeIfPresent(Bool.self, forKey: .isAudioDirect)
        videoCodec = try container.decodeIfPresent(String.self, forKey: .videoCodec)
        audioCodec = try container.decodeIfPresent(String.self, forKey: .audioCodec)
        self.container = try container.decodeIfPresent(String.self, forKey: .container)
        bitrate = try container.decodeIfPresent(Int.self, forKey: .bitrate)
        width = try container.decodeIfPresent(Int.self, forKey: .width)
        height = try container.decodeIfPresent(Int.self, forKey: .height)
        audioChannels = try container.decodeIfPresent(Int.self, forKey: .audioChannels)
        hardwareAccelerationType = try container.decodeIfPresent(String.self, forKey: .hardwareAccelerationType)
        if let list = try? container.decodeIfPresent([JellyfinTranscodeReason].self, forKey: .transcodeReasons) {
            transcodeReasons = list
        } else {
            transcodeReasons = JellyfinTranscodeReason.list(
                try? container.decodeIfPresent(String.self, forKey: .transcodeReasons))
        }
    }
}

/// `POST /Sessions/Capabilities/Full` body, sent once after sign-in.
struct JellyfinClientCapabilitiesDTO: Encodable, Sendable {
    var playableMediaTypes: [JellyfinMediaType] = [.video]
    var supportedCommands: [String] = []
    var supportsMediaControl = false
    var supportsPersistentIdentifier = true

    enum CodingKeys: String, CodingKey {
        case playableMediaTypes = "PlayableMediaTypes"
        case supportedCommands = "SupportedCommands"
        case supportsMediaControl = "SupportsMediaControl"
        case supportsPersistentIdentifier = "SupportsPersistentIdentifier"
    }
}
