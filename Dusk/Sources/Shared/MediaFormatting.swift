import Foundation

enum MediaTextFormatter {
    static func seasonEpisodeLabel(
        season: Int?,
        episode: Int?,
        separator: String = " · "
    ) -> String? {
        switch (season, episode) {
        case let (season?, episode?):
            return "Season \(season)\(separator)Episode \(episode)"
        case let (season?, nil):
            return "Season \(season)"
        case let (nil, episode?):
            return "Episode \(episode)"
        default:
            return nil
        }
    }

    static func seasonCount(_ count: Int?) -> String? {
        pluralizedCount(count, singular: "Season", plural: "Seasons")
    }

    static func episodeCount(_ count: Int?) -> String? {
        pluralizedCount(count, singular: "Episode", plural: "Episodes")
    }

    static func watchedCount(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return "\(count) watched"
    }

    static func shortDuration(milliseconds: Int?) -> String? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        let totalMinutes = milliseconds / 60_000
        return "\(totalMinutes) min"
    }

    static func playbackDuration(milliseconds: Int?) -> String? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        let totalMinutes = milliseconds / 60_000
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }

        return "\(minutes)m"
    }

    static func localizedAirDate(_ value: String?) -> String? {
        guard let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmedValue.isEmpty else {
            return nil
        }

        guard let date = plexAirDateFormatter.date(from: trimmedValue) else {
            return trimmedValue
        }

        return localizedAirDateFormatter.string(from: date)
    }

    static func progress(durationMs: Int?, offsetMs: Int?) -> Double? {
        guard let durationMs,
              let offsetMs,
              durationMs > 0,
              offsetMs > 0 else {
            return nil
        }

        return Double(offsetMs) / Double(durationMs)
    }

    static func mediaTypeIconName(_ type: PlexMediaType) -> String {
        switch type {
        case .movie:
            return "film"
        case .show:
            return "tv.fill"
        case .person:
            return "person.fill"
        case .episode:
            return "play.rectangle"
        case .season:
            return "rectangle.stack"
        default:
            return "square.grid.2x2"
        }
    }

    static func playbackVersionMenuLabel(_ media: PlexMedia) -> String {
        var parts: [String] = []

        if let resolution = playbackVersionResolution(media) {
            parts.append(resolution)
        }

        if let videoCodec = media.videoCodec?.trimmingCharacters(in: .whitespacesAndNewlines),
           !videoCodec.isEmpty {
            parts.append(videoCodec.uppercased())
        }

        if let audioCodec = media.audioCodec?.trimmingCharacters(in: .whitespacesAndNewlines),
           !audioCodec.isEmpty {
            parts.append(audioCodec.uppercased())
        }

        if let container = media.container?.trimmingCharacters(in: .whitespacesAndNewlines),
           !container.isEmpty {
            parts.append(container.uppercased())
        }

        if let bitrateLabel = playbackVersionBitrate(media) {
            parts.append(bitrateLabel)
        }

        if media.optimizedForStreaming == 1 {
            parts.append("Optimized")
        }

        return parts.isEmpty ? "Version \(media.id)" : parts.joined(separator: " · ")
    }

    private static func pluralizedCount(
        _ count: Int?,
        singular: String,
        plural: String
    ) -> String? {
        guard let count, count > 0 else { return nil }
        let label = count == 1 ? singular : plural
        return "\(count) \(label)"
    }

    private static func playbackVersionResolution(_ media: PlexMedia) -> String? {
        if let resolution = media.videoResolution?.trimmingCharacters(in: .whitespacesAndNewlines),
           !resolution.isEmpty {
            let normalized = resolution.lowercased()
            switch normalized {
            case "4k":
                return "4K"
            case "sd":
                return "SD"
            default:
                if normalized.hasSuffix("p") {
                    return normalized.dropLast().allSatisfy(\.isNumber)
                        ? "\(normalized.dropLast())p"
                        : resolution
                }
                return normalized.allSatisfy(\.isNumber) ? "\(normalized)p" : resolution.uppercased()
            }
        }

        guard let height = media.height, height > 0 else { return nil }
        switch height {
        case 2000...:
            return "4K"
        default:
            return "\(height)p"
        }
    }

    private static func playbackVersionBitrate(_ media: PlexMedia) -> String? {
        guard let bitrate = media.bitrate, bitrate > 0 else { return nil }
        if bitrate >= 1000 {
            let megabits = Double(bitrate) / 1000.0
            return String(format: megabits >= 10 ? "%.0f Mbps" : "%.1f Mbps", megabits)
        }
        return "\(bitrate) kbps"
    }

    private static let plexAirDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let localizedAirDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("d MMM y")
        return formatter
    }()
}
