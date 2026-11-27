import Foundation

// Wire-level value types shared by every Jellyfin DTO: ticks, dates, ids and
// the open string enums the server uses. All of them decode tolerantly, so
// one odd value never fails a whole response (docs/jellyfin/03-prior-art.md
// §10.3).

// MARK: - Ticks

/// A Jellyfin duration or position: 100 ns ticks on the wire, `Int64` because a
/// 3 h film is 108 000 000 000 ticks.
///
/// Decodes from an integer, a floating-point number or a numeric string and
/// becomes `0` for anything else, so a malformed value never fails the
/// document. Note that not every Jellyfin time is ticks: trickplay `Interval`
/// is milliseconds and bitrates are bits per second.
struct JellyfinTicks: Codable, Hashable, Comparable, Sendable {
    static let perMillisecond: Int64 = 10_000
    static let perSecond: Int64 = 10_000_000

    let rawValue: Int64

    init(_ rawValue: Int64) {
        self.rawValue = rawValue
    }

    init(milliseconds: Int) {
        rawValue = Int64(milliseconds) * Self.perMillisecond
    }

    init(seconds: TimeInterval) {
        rawValue = seconds.isFinite ? Int64((seconds * Double(Self.perSecond)).rounded()) : 0
    }

    /// Rounded to the nearest millisecond, the unit Dusk's domain uses.
    var milliseconds: Int {
        Int((Double(rawValue) / Double(Self.perMillisecond)).rounded())
    }

    var seconds: TimeInterval {
        Double(rawValue) / Double(Self.perSecond)
    }

    static func < (lhs: JellyfinTicks, rhs: JellyfinTicks) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            rawValue = value
        } else if let value = try? container.decode(Double.self), value.isFinite,
                  abs(value) < 9.2e18 {
            rawValue = Int64(value.rounded())
        } else if let text = try? container.decode(String.self),
                  let value = Int64(text.trimmingCharacters(in: .whitespaces)) {
            rawValue = value
        } else {
            rawValue = 0
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Dates

/// A Jellyfin timestamp. The server writes ISO 8601 with up to seven fraction
/// digits (`2026-06-18T11:06:59.8066228Z`), sometimes six or none, and some
/// endpoints a bare date. Foundation's ISO parsers disagree about those forms
/// across OS versions, so this parses by hand.
///
/// Decoding never throws: an unparseable string keeps `raw` and has a nil
/// `date`, a non-string value becomes an empty `raw`.
struct JellyfinDate: Codable, Hashable, Sendable {
    let raw: String
    let date: Date?

    init(raw: String) {
        self.raw = raw
        date = Self.parse(raw)
    }

    init(_ date: Date) {
        self.date = date
        raw = Self.format(date)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(raw: (try? container.decode(String.self)) ?? "")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    /// `YYYY-MM-DD`, optionally followed by `THH:MM[:SS[.fraction]]` and a
    /// zone (`Z`, `±HH:MM`, `±HHMM`, `±HH`). No zone means UTC, which is how
    /// the server writes every date it stores.
    static func parse(_ text: String) -> Date? {
        let bytes = Array(text.trimmingCharacters(in: .whitespaces).utf8)
        var index = 0

        func digits(_ count: Int) -> Int? {
            guard index + count <= bytes.count else { return nil }
            var value = 0
            for offset in 0..<count {
                let byte = bytes[index + offset]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            index += count
            return value
        }
        func consume(_ character: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == character else { return false }
            index += 1
            return true
        }

        guard let year = digits(4), consume(45), let month = digits(2), consume(45),
              let day = digits(2), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var hour = 0, minute = 0, second = 0
        var fraction = 0.0
        var offsetSeconds = 0

        if index < bytes.count, bytes[index] == 84 || bytes[index] == 116 || bytes[index] == 32 { // T, t, space
            index += 1
            guard let parsedHour = digits(2), consume(58), let parsedMinute = digits(2),
                  parsedHour <= 24, parsedMinute <= 59 else { return nil }
            hour = parsedHour
            minute = parsedMinute
            if consume(58) {
                guard let parsedSecond = digits(2), parsedSecond <= 60 else { return nil }
                second = parsedSecond
                if index < bytes.count, bytes[index] == 46 || bytes[index] == 44 { // . or ,
                    index += 1
                    var scale = 0.1
                    var sawDigit = false
                    while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                        fraction += Double(bytes[index] - 48) * scale
                        scale /= 10
                        sawDigit = true
                        index += 1
                    }
                    guard sawDigit else { return nil }
                }
            }
            if index < bytes.count {
                let sign = bytes[index]
                if sign == 90 || sign == 122 { // Z, z
                    index += 1
                } else if sign == 43 || sign == 45 { // + -
                    index += 1
                    guard let offsetHours = digits(2), offsetHours <= 23 else { return nil }
                    var offsetMinutes = 0
                    if index < bytes.count {
                        _ = consume(58)
                        guard let parsed = digits(2), parsed <= 59 else { return nil }
                        offsetMinutes = parsed
                    }
                    offsetSeconds = (offsetHours * 3600 + offsetMinutes * 60) * (sign == 45 ? -1 : 1)
                } else {
                    return nil
                }
            }
        }
        guard index == bytes.count else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        let seconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds) + fraction
        return Date(timeIntervalSince1970: seconds)
    }

    /// Seven fraction digits in UTC, the form the server writes.
    static func format(_ date: Date) -> String {
        let interval = date.timeIntervalSince1970
        var wholeSeconds = Int(interval.rounded(.down))
        var ticks = Int(((interval - Double(wholeSeconds)) * 10_000_000).rounded())
        if ticks >= 10_000_000 {
            wholeSeconds += 1
            ticks -= 10_000_000
        }
        let days = Int((Double(wholeSeconds) / 86_400).rounded(.down))
        let secondOfDay = wholeSeconds - days * 86_400
        let (year, month, day) = civilFromDays(days)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%07dZ",
                      year, month, day, secondOfDay / 3600, secondOfDay % 3600 / 60, secondOfDay % 60, ticks)
    }

    // Howard Hinnant's days-from-civil algorithm, proleptic Gregorian, UTC.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civilFromDays(_ days: Int) -> (Int, Int, Int) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}

// MARK: - Ids

enum JellyfinID {
    /// Item, user and server ids are GUIDs. JSON carries them as 32 lower-case
    /// hex characters, but `TranscodingUrl` / `DeliveryUrl` paths use the dashed
    /// form. Both are accepted in requests; normalise before using an id as a
    /// key or comparing two.
    static func normalized(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func same(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }
}

// MARK: - Open string enums

/// A server enum decoded as an open set of strings. Jellyfin adds enum cases
/// between releases (item kinds, video range types, segment types), and a
/// closed Swift enum would turn each new case into a decoding failure for the
/// whole response. Known values are static constants on each type.
protocol JellyfinOpenEnum: RawRepresentable, Codable, Hashable, Sendable,
    ExpressibleByStringLiteral, CustomStringConvertible where RawValue == String {
    init(rawValue: String)
}

extension JellyfinOpenEnum {
    init(stringLiteral value: String) {
        self.init(rawValue: value)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: (try? container.decode(String.self)) ?? "")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue }

    /// Jellyfin compares enum names case-insensitively on input; so does this.
    func matches(_ other: Self) -> Bool {
        rawValue.caseInsensitiveCompare(other.rawValue) == .orderedSame
    }
}

/// `BaseItemKind`.
struct JellyfinItemKind: JellyfinOpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let movie: Self = "Movie"
    static let series: Self = "Series"
    static let season: Self = "Season"
    static let episode: Self = "Episode"
    static let video: Self = "Video"
    static let boxSet: Self = "BoxSet"
    static let playlist: Self = "Playlist"
    static let photo: Self = "Photo"
    static let photoAlbum: Self = "PhotoAlbum"
    static let folder: Self = "Folder"
    static let collectionFolder: Self = "CollectionFolder"
    static let userView: Self = "UserView"
    static let userRootFolder: Self = "UserRootFolder"
    static let person: Self = "Person"
    static let genre: Self = "Genre"
    static let studio: Self = "Studio"
    static let trailer: Self = "Trailer"
    static let tvChannel: Self = "TvChannel"
    static let tvProgram: Self = "TvProgram"
    static let liveTvProgram: Self = "LiveTvProgram"
    static let recording: Self = "Recording"
}

/// `CollectionType` of a library view. Absent = mixed content.
struct JellyfinCollectionType: JellyfinOpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let movies: Self = "movies"
    static let tvShows: Self = "tvshows"
    static let homeVideos: Self = "homevideos"
    static let boxSets: Self = "boxsets"
    static let playlists: Self = "playlists"
    static let liveTV: Self = "livetv"
    static let music: Self = "music"
    static let books: Self = "books"
    static let photos: Self = "photos"
    static let musicVideos: Self = "musicvideos"
}

struct JellyfinMediaType: JellyfinOpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let video: Self = "Video"
    static let audio: Self = "Audio"
    static let photo: Self = "Photo"
    static let book: Self = "Book"
    static let unknown: Self = "Unknown"
}

struct JellyfinImageType: JellyfinOpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let primary: Self = "Primary"
    static let backdrop: Self = "Backdrop"
    static let logo: Self = "Logo"
    static let thumb: Self = "Thumb"
    static let banner: Self = "Banner"
    static let art: Self = "Art"
    static let disc: Self = "Disc"
    static let chapter: Self = "Chapter"
    static let screenshot: Self = "Screenshot"
}

/// `PersonKind` on `BaseItemPerson.Type`.
struct JellyfinPersonKind: JellyfinOpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let actor: Self = "Actor"
    static let director: Self = "Director"
    static let writer: Self = "Writer"
    static let producer: Self = "Producer"
    static let guestStar: Self = "GuestStar"
    static let composer: Self = "Composer"
}

/// `ExtraType` of a special feature.
struct JellyfinExtraType: JellyfinOpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let trailer: Self = "Trailer"
    static let behindTheScenes: Self = "BehindTheScenes"
    static let deletedScene: Self = "DeletedScene"
    static let interview: Self = "Interview"
    static let featurette: Self = "Featurette"
    static let clip: Self = "Clip"
    static let scene: Self = "Scene"
    static let sample: Self = "Sample"
    static let short: Self = "Short"
    static let themeVideo: Self = "ThemeVideo"
}

struct JellyfinLocationType: JellyfinOpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let fileSystem: Self = "FileSystem"
    static let remote: Self = "Remote"
    static let virtual: Self = "Virtual"
    static let offline: Self = "Offline"
}

/// `MediaStreamType`.
struct JellyfinStreamType: JellyfinOpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let video: Self = "Video"
    static let audio: Self = "Audio"
    static let subtitle: Self = "Subtitle"
    static let embeddedImage: Self = "EmbeddedImage"
    static let data: Self = "Data"
    static let lyric: Self = "Lyric"
}

/// `VideoRangeType`, the explicit HDR / Dolby Vision classification.
struct JellyfinVideoRangeType: JellyfinOpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let unknown: Self = "Unknown"
    static let sdr: Self = "SDR"
    static let hdr10: Self = "HDR10"
    static let hdr10Plus: Self = "HDR10Plus"
    static let hlg: Self = "HLG"
    static let dovi: Self = "DOVI"
    static let doviWithHDR10: Self = "DOVIWithHDR10"
    static let doviWithHLG: Self = "DOVIWithHLG"
    static let doviWithSDR: Self = "DOVIWithSDR"
    static let doviWithEL: Self = "DOVIWithEL"
    static let doviWithHDR10Plus: Self = "DOVIWithHDR10Plus"
    static let doviWithELHDR10Plus: Self = "DOVIWithELHDR10Plus"
    static let doviInvalid: Self = "DOVIInvalid"
}

/// `VideoRange` (coarse: SDR / HDR).
struct JellyfinVideoRange: JellyfinOpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let unknown: Self = "Unknown"
    static let sdr: Self = "SDR"
    static let hdr: Self = "HDR"
}

struct JellyfinAudioSpatialFormat: JellyfinOpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let none: Self = "None"
    static let dolbyAtmos: Self = "DolbyAtmos"
    static let dtsX: Self = "DTSX"
}

/// `SubtitleDeliveryMethod`.
struct JellyfinSubtitleDeliveryMethod: JellyfinOpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let encode: Self = "Encode"
    static let embed: Self = "Embed"
    static let external: Self = "External"
    static let hls: Self = "Hls"
    static let videoSideData: Self = "VideoSideData"
    static let drop: Self = "Drop"
}

/// `MediaProtocol` of a media source.
struct JellyfinMediaProtocol: JellyfinOpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let file: Self = "File"
    static let http: Self = "Http"
    static let rtmp: Self = "Rtmp"
    static let rtsp: Self = "Rtsp"
    static let udp: Self = "Udp"
    static let rtp: Self = "Rtp"
    static let ftp: Self = "Ftp"
}

/// `MediaSegmentType`.
struct JellyfinMediaSegmentType: JellyfinOpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let unknown: Self = "Unknown"
    static let commercial: Self = "Commercial"
    static let preview: Self = "Preview"
    static let recap: Self = "Recap"
    static let outro: Self = "Outro"
    static let intro: Self = "Intro"
}

/// `PlayMethod` reported in playback sessions.
struct JellyfinPlayMethod: JellyfinOpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let transcode: Self = "Transcode"
    static let directStream: Self = "DirectStream"
    static let directPlay: Self = "DirectPlay"
}

/// `SubtitlePlaybackMode` in the user configuration.
struct JellyfinSubtitleMode: JellyfinOpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let `default`: Self = "Default"
    static let always: Self = "Always"
    static let onlyForced: Self = "OnlyForced"
    static let none: Self = "None"
    static let smart: Self = "Smart"
}

/// `TranscodeReason` values, found comma-separated in `TranscodeReasons`.
struct JellyfinTranscodeReason: JellyfinOpenEnum {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let containerNotSupported: Self = "ContainerNotSupported"
    static let videoCodecNotSupported: Self = "VideoCodecNotSupported"
    static let audioCodecNotSupported: Self = "AudioCodecNotSupported"
    static let subtitleCodecNotSupported: Self = "SubtitleCodecNotSupported"
    static let videoRangeTypeNotSupported: Self = "VideoRangeTypeNotSupported"
    static let containerBitrateExceedsLimit: Self = "ContainerBitrateExceedsLimit"
    static let directPlayError: Self = "DirectPlayError"

    /// Splits the comma-separated form the server uses in URLs and sessions.
    static func list(_ text: String?) -> [Self] {
        (text ?? "").split(separator: ",")
            .map { Self(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.rawValue.isEmpty }
    }
}
