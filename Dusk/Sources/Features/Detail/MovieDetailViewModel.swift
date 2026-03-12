import Foundation

@MainActor
@Observable
final class MovieDetailViewModel {
    private let plexService: PlexService
    let ratingKey: String

    private(set) var details: PlexMediaDetails?
    private(set) var isLoading = false
    private(set) var error: String?

    init(ratingKey: String, plexService: PlexService) {
        self.ratingKey = ratingKey
        self.plexService = plexService
    }

    func loadDetails() async {
        guard details == nil else { return }
        isLoading = true
        error = nil

        do {
            details = try await plexService.getMediaDetails(ratingKey: ratingKey)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    func toggleWatched() async {
        guard details != nil else { return }
        do {
            if isWatched {
                try await plexService.unscrobble(ratingKey: ratingKey)
            } else {
                try await plexService.scrobble(ratingKey: ratingKey)
            }
            // Reload to get updated watch state
            self.details = try await plexService.getMediaDetails(ratingKey: ratingKey)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Computed Helpers

    var isWatched: Bool {
        guard let count = details?.viewCount else { return false }
        return count > 0
    }

    var resumePositionSeconds: TimeInterval? {
        guard let offset = details?.viewOffset, offset > 0 else { return nil }
        return TimeInterval(offset) / 1000.0
    }

    var formattedDuration: String? {
        guard let ms = details?.duration, ms > 0 else { return nil }
        let totalMinutes = ms / 60_000
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    var formattedResume: String? {
        guard let seconds = resumePositionSeconds else { return nil }
        let totalMinutes = Int(seconds) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    var mediaInfo: String? {
        guard let media = details?.media.first else { return nil }
        var parts: [String] = []
        if let res = media.videoResolution?.uppercased() {
            parts.append(res)
        }
        if let codec = media.videoCodec?.uppercased() {
            parts.append(codec)
        }
        if let audioCodec = media.audioCodec?.uppercased() {
            parts.append(audioCodec)
        }
        if let channels = media.audioChannels {
            parts.append("\(channels)ch")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var genreText: String? {
        guard let genres = details?.genres, !genres.isEmpty else { return nil }
        return genres.prefix(3).map(\.tag).joined(separator: ", ")
    }

    var directorText: String? {
        guard let directors = details?.directors, !directors.isEmpty else { return nil }
        return directors.map(\.tag).joined(separator: ", ")
    }

    func posterURL(width: Int, height: Int) -> URL? {
        plexService.imageURL(for: details?.thumb, width: width, height: height)
    }

    func backdropURL(width: Int, height: Int) -> URL? {
        plexService.imageURL(for: details?.art, width: width, height: height)
    }
}
