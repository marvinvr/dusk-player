import Foundation

enum SeerrMediaType: String, Codable, Sendable, Hashable {
    case movie
    case tv
}

enum SeerrMediaStatus: Int, Codable, Sendable, Hashable {
    case unknown = 1
    case pending
    case processing
    case partiallyAvailable
    case available
    case blocklisted
    case deleted
}

enum SeerrMediaRequestStatus: Int, Codable, Sendable, Hashable {
    case pending = 1
    case approved
    case declined
    case failed
    case completed
}

struct SeerrPublicSettings: Decodable, Sendable {
    let initialized: Bool
    let applicationTitle: String?
    let mediaServerLogin: Bool
    let mediaServerType: Int
    let partialRequestsEnabled: Bool
    let enableSpecialEpisodes: Bool

    var isPlexServer: Bool {
        mediaServerType == 1
    }
}

struct SeerrUser: Codable, Sendable, Hashable, Identifiable {
    let id: Int
    let email: String?
    let username: String?
    let plexUsername: String?
    let permissions: Int64

    var displayName: String {
        plexUsername?.nilIfEmpty
            ?? username?.nilIfEmpty
            ?? email?.nilIfEmpty
            ?? "Plex User"
    }

    func hasAnyPermission(_ permissionsToCheck: [SeerrPermission]) -> Bool {
        let value = SeerrPermission(rawValue: permissions)
        return value.contains(.admin) || permissionsToCheck.contains(where: value.contains)
    }

    func canRequest(_ mediaType: SeerrMediaType) -> Bool {
        switch mediaType {
        case .movie:
            return hasAnyPermission([.request, .requestMovie])
        case .tv:
            return hasAnyPermission([.request, .requestTV])
        }
    }
}

struct SeerrPermission: OptionSet, Sendable {
    let rawValue: Int64

    static let admin = SeerrPermission(rawValue: 2)
    static let request = SeerrPermission(rawValue: 32)
    static let requestMovie = SeerrPermission(rawValue: 262_144)
    static let requestTV = SeerrPermission(rawValue: 524_288)
}

struct SeerrSearchResponse: Decodable, Sendable {
    let page: Int?
    let totalPages: Int?
    let totalResults: Int?
    let results: [SeerrSearchMedia]
}

struct SeerrSearchMedia: Decodable, Sendable, Hashable, Identifiable {
    let id: Int
    let mediaType: String
    let title: String?
    let name: String?
    let posterPath: String?
    let backdropPath: String?
    let overview: String?
    let releaseDate: String?
    let firstAirDate: String?
    let mediaInfo: SeerrMediaInfo?

    var supportedMediaType: SeerrMediaType? {
        SeerrMediaType(rawValue: mediaType)
    }

    var displayTitle: String {
        title?.nilIfEmpty ?? name?.nilIfEmpty ?? "Untitled"
    }

    var year: Int? {
        let date = releaseDate?.nilIfEmpty ?? firstAirDate?.nilIfEmpty
        guard let yearText = date?.prefix(4) else { return nil }
        return Int(yearText)
    }
}

struct SeerrMediaInfo: Decodable, Sendable, Hashable {
    let id: Int?
    let tmdbId: Int?
    let tvdbId: Int?
    let status: SeerrMediaStatus?
    let status4k: SeerrMediaStatus?
    let requests: [SeerrMediaRequest]?
    let seasons: [SeerrMediaSeason]?
    let ratingKey: String?
}

struct SeerrMediaRequest: Decodable, Sendable, Hashable, Identifiable {
    let id: Int
    let status: SeerrMediaRequestStatus
    let requestedBy: SeerrUser?
    let seasons: [SeerrSeasonRequest]?
    let is4k: Bool?
}

struct SeerrSeasonRequest: Decodable, Sendable, Hashable {
    let id: Int?
    let seasonNumber: Int
    let status: SeerrMediaRequestStatus
}

struct SeerrMediaSeason: Decodable, Sendable, Hashable {
    let id: Int?
    let seasonNumber: Int
    let status: SeerrMediaStatus?
    let status4k: SeerrMediaStatus?
}

struct SeerrGenre: Decodable, Sendable, Hashable, Identifiable {
    let id: Int
    let name: String
}

struct SeerrMovieDetails: Decodable, Sendable, Hashable, Identifiable {
    let id: Int
    let title: String
    let overview: String?
    let releaseDate: String?
    let runtime: Int?
    let posterPath: String?
    let backdropPath: String?
    let voteAverage: Double?
    let genres: [SeerrGenre]?
    let mediaInfo: SeerrMediaInfo?

    var year: Int? {
        guard let value = releaseDate?.prefix(4) else { return nil }
        return Int(value)
    }
}

struct SeerrTVDetails: Decodable, Sendable, Hashable, Identifiable {
    let id: Int
    let name: String
    let overview: String?
    let firstAirDate: String?
    let posterPath: String?
    let backdropPath: String?
    let voteAverage: Double?
    let genres: [SeerrGenre]?
    let seasons: [SeerrSeasonSummary]
    let mediaInfo: SeerrMediaInfo?

    var year: Int? {
        guard let value = firstAirDate?.prefix(4) else { return nil }
        return Int(value)
    }
}

struct SeerrSeasonSummary: Decodable, Sendable, Hashable, Identifiable {
    let id: Int
    let airDate: String?
    let episodeCount: Int?
    let name: String
    let overview: String?
    let posterPath: String?
    let seasonNumber: Int
}

struct SeerrSeasonDetails: Decodable, Sendable, Hashable, Identifiable {
    let id: Int
    let airDate: String?
    let episodes: [SeerrEpisode]?
    let name: String
    let overview: String?
    let posterPath: String?
    let seasonNumber: Int
}

struct SeerrEpisode: Decodable, Sendable, Hashable, Identifiable {
    let id: Int
    let airDate: String?
    let episodeNumber: Int?
    let name: String?
    let overview: String?
    let runtime: Int?
    let stillPath: String?
}

struct SeerrQuotaResponse: Decodable, Sendable {
    let movie: SeerrQuota
    let tv: SeerrQuota
}

struct SeerrQuota: Decodable, Sendable {
    let days: Int?
    let limit: Int?
    let used: Int?
    let remaining: Int?
    let restricted: Bool
}

struct SeerrCreateRequestBody: Encodable, Sendable {
    let mediaType: SeerrMediaType
    let mediaId: Int
    let seasons: SeerrRequestedSeasons?
    let is4k: Bool
}

enum SeerrRequestedSeasons: Encodable, Sendable {
    case all
    case numbers([Int])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .all:
            try container.encode("all")
        case .numbers(let values):
            try container.encode(values)
        }
    }
}

enum SeerrRequestState: Sendable, Hashable {
    case requestable
    case pending
    case approved
    case processing
    case partiallyAvailable
    case available
    case blocklisted
    case declined
    case failed
    case completed

    var badgeTitle: String {
        switch self {
        case .requestable: "Request"
        case .pending: "Pending"
        case .approved: "Approved"
        case .processing: "Processing"
        case .partiallyAvailable: "Partial"
        case .available: "Available"
        case .blocklisted: "Unavailable"
        case .declined: "Declined"
        case .failed: "Failed"
        case .completed: "Available"
        }
    }

    var detailTitle: String {
        switch self {
        case .requestable: "Available to request"
        case .pending: "Pending approval"
        case .approved: "Approved"
        case .processing: "Being processed"
        case .partiallyAvailable: "Partially available"
        case .available, .completed: "Available in Plex"
        case .blocklisted: "Not available to request"
        case .declined: "Request declined"
        case .failed: "Request failed"
        }
    }

    var canRequest: Bool {
        self == .requestable || self == .declined
    }

    var systemImage: String {
        switch self {
        case .requestable: "paperplane.fill"
        case .pending: "clock"
        case .approved: "checkmark.circle"
        case .processing: "arrow.triangle.2.circlepath"
        case .partiallyAvailable: "circle.lefthalf.filled"
        case .available, .completed: "checkmark.circle.fill"
        case .blocklisted: "nosign"
        case .declined: "xmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    static func resolve(
        mediaInfo: SeerrMediaInfo?,
        currentUserID: Int?,
        seasonNumber: Int? = nil
    ) -> SeerrRequestState {
        if seasonNumber == nil {
            switch mediaInfo?.status {
            case .available: return .available
            case .partiallyAvailable: return .partiallyAvailable
            case .processing: return .processing
            case .blocklisted: return .blocklisted
            default: break
            }
        } else if let seasonNumber {
            let mediaSeason = mediaInfo?.seasons?.first { $0.seasonNumber == seasonNumber }
            switch mediaSeason?.status {
            case .available: return .available
            case .partiallyAvailable: return .partiallyAvailable
            case .processing: return .processing
            case .blocklisted: return .blocklisted
            default: break
            }
        }

        let standardRequests = mediaInfo?.requests?.filter { $0.is4k != true } ?? []
        let prioritizedRequests = standardRequests.sorted {
            ($0.requestedBy?.id == currentUserID ? 0 : 1) <
                ($1.requestedBy?.id == currentUserID ? 0 : 1)
        }

        let requestStatus: SeerrMediaRequestStatus? = {
            if let seasonNumber {
                return prioritizedRequests
                    .flatMap { $0.seasons ?? [] }
                    .first { $0.seasonNumber == seasonNumber }?
                    .status
            }
            return prioritizedRequests.first?.status
        }()

        switch requestStatus {
        case .pending: return .pending
        case .approved: return .approved
        case .declined: return .declined
        case .failed: return .failed
        case .completed: return .completed
        case nil:
            switch mediaInfo?.status {
            case .pending: return .pending
            case .deleted, .unknown, nil: return .requestable
            case .processing: return .processing
            case .partiallyAvailable: return .partiallyAvailable
            case .available: return .available
            case .blocklisted: return .blocklisted
            }
        }
    }
}
