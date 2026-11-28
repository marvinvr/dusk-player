import Foundation

/// A semantic choice, never a Plex stream ID (IDs change between episodes).
struct ShowTrackDescriptor: Codable, Equatable, Sendable {
    let language: String
    let forced: Bool
    let hearingImpaired: Bool
    let commentary: Bool
    let descriptive: Bool
    let codec: String?
    let channels: Int?
    /// A Plex sidecar (a subtitle downloaded through Plex's search, or a file
    /// next to the media). Nil for choices saved before this was recorded.
    let external: Bool?

    @MainActor
    init?(stream: MediaStream) {
        guard let language = PlayerViewModel.normalizedLanguageCode(stream.languageCode ?? stream.languageTag),
              language != "und", language != "unk" else { return nil }
        self.language = language
        let isExternal = stream.key != nil
        // A downloaded sidecar's `title` is the provider's release name, which
        // Plex folds into `extendedDisplayTitle`: different every episode and
        // full of accidental markers ("SUCCESSORS" contains "cc"). Only the
        // short display title and Plex's own flags describe its purpose.
        let title = (isExternal ? stream.displayTitle : stream.extendedDisplayTitle ?? stream.displayTitle) ?? ""
        forced = stream.isForced == true || PlayerViewModel.containsForcedMarker(title)
        hearingImpaired = stream.isHearingImpaired == true || PlayerViewModel.containsHearingImpairedMarker(title)
        commentary = PlayerViewModel.containsCommentaryMarker(title)
        descriptive = PlayerViewModel.containsDescriptiveAudioMarker(title)
        codec = stream.codec?.lowercased()
        channels = stream.channels
        external = stream.kind == .subtitle ? isExternal : nil
    }

    @MainActor
    func match(in streams: [MediaStream], type: StreamKind) -> MediaStream? {
        // Language and purpose are requirements. Codec/channels only break ties;
        // never substitute forced subtitles or commentary for a normal track.
        //
        // A downloaded subtitle is the exception for SDH: which OpenSubtitles
        // result the viewer happened to pick says nothing about the next
        // episode, which usually has no download yet. Its language is the
        // choice, so any same-language sidecar wins, then an embedded track
        // (same SDH flag first).
        let relaxesHearingImpaired = type == .subtitle && external == true
        let candidates = streams.filter { stream in
            guard stream.kind == type, let candidate = Self(stream: stream) else { return false }
            return language == candidate.language && forced == candidate.forced
                && (relaxesHearingImpaired || hearingImpaired == candidate.hearingImpaired)
                && commentary == candidate.commentary && descriptive == candidate.descriptive
        }
        return candidates.enumerated().max { lhs, rhs in
            let left = score(lhs.element)
            let right = score(rhs.element)
            return left == right ? lhs.offset > rhs.offset : left < right
        }?.element
    }

    @MainActor
    private func score(_ stream: MediaStream) -> Int {
        let isExternal = stream.key != nil
        let sameKind = external.map { $0 == isExternal } ?? false
        let sameHearingImpaired = Self(stream: stream)?.hearingImpaired == hearingImpaired
        return (external == true && sameKind ? 16 : 0)
            + (sameHearingImpaired ? 8 : 0)
            + (sameKind ? 1 : 0)
            + (codec != nil && codec == stream.codec?.lowercased() ? 4 : 0)
            + (channels != nil && channels == stream.channels ? 2 : 0)
    }
}

struct ShowTrackPreferences: Codable, Equatable, Sendable {
    enum Subtitles: Codable, Equatable, Sendable {
        case off
        case track(ShowTrackDescriptor)
    }

    var audio: ShowTrackDescriptor?
    var subtitles: Subtitles?

    @MainActor
    static func hasHDRVideo(in part: MediaPart) -> Bool {
        part.streams.contains {
            $0.kind == .video && ($0.isHDRVideo || StreamResolver.hdrTransfer(of: $0) != nil ||
                $0.dolbyVision?.present == true || $0.dolbyVision?.profile != nil ||
                $0.dolbyVision?.blCompatID != nil || $0.dolbyVision?.level != nil)
        }
    }

    /// The subtitle an HDR/DV remux starts with (picture first). A subtitle
    /// the video-copy remux cannot carry (PGS/VobSub would be burned in, a
    /// video transcode; ASS/SSA would lose its styling) gives way to a text
    /// subtitle of the same language and purpose (`textSubtitleFallback`),
    /// or none, instead of sending the video to VLC without HDR. SDR media
    /// and subtitles that ride the remux are returned unchanged.
    @MainActor
    static func remuxSubtitleStreamID(_ streamID: String?, in part: MediaPart) -> String? {
        guard hasHDRVideo(in: part), let streamID,
              let stream = part.streams.first(where: { $0.kind == .subtitle && $0.id == streamID }),
              !StreamResolver.canRideRemux(subtitle: stream) else { return streamID }
        return textSubtitleFallback(for: stream, in: part)?.id
    }

    /// A text subtitle that can ride the remux in place of `stream`: same
    /// language, forced only for forced and commentary only for commentary
    /// (forced-only text must not stand in for full subtitles, nor the
    /// reverse). The same SDH flag is preferred, then Plex's order.
    @MainActor
    static func textSubtitleFallback(for stream: MediaStream, in part: MediaPart) -> MediaStream? {
        guard let wanted = ShowTrackDescriptor(stream: stream) else { return nil }
        let candidates = part.streams.compactMap { candidate -> (stream: MediaStream, descriptor: ShowTrackDescriptor)? in
            guard candidate.kind == .subtitle, candidate.id != stream.id,
                  StreamResolver.canRideRemux(subtitle: candidate),
                  let descriptor = ShowTrackDescriptor(stream: candidate),
                  descriptor.language == wanted.language,
                  descriptor.forced == wanted.forced,
                  descriptor.commentary == wanted.commentary else { return nil }
            return (candidate, descriptor)
        }
        return (candidates.first { $0.descriptor.hearingImpaired == wanted.hearingImpaired } ?? candidates.first)?.stream
    }

    @MainActor
    func audioStream(in part: MediaPart) -> MediaStream? {
        audio?.match(in: part.streams, type: .audio)
    }

    @MainActor
    func subtitleStreamID(in part: MediaPart, fallback: String?) -> String? {
        switch subtitles {
        case .off: nil
        case let .track(descriptor): descriptor.match(in: part.streams, type: .subtitle)?.id ?? fallback
        case nil: fallback
        }
    }

    @MainActor
    func hasMatch(in part: MediaPart) -> Bool {
        if audioStream(in: part) != nil { return true }
        switch subtitles {
        case .off: return true
        case let .track(descriptor): return descriptor.match(in: part.streams, type: .subtitle) != nil
        case nil: return false
        }
    }
}

/// Device-local fallback for choices Plex's language-only show settings cannot
/// express. No unscoped/anonymous bucket: a Home switch cannot inherit a choice.
@MainActor
struct ShowTrackPreferenceStore {
    struct Scope: Codable, Equatable, Sendable {
        let profileID: String
        let serverID: String
        let showRatingKey: String

        init?(profileID: String?, serverID: String?, details: MediaDetails) {
            guard details.type == .episode,
                  let profileID, !profileID.isEmpty,
                  let serverID, !serverID.isEmpty,
                  let showRatingKey = details.grandparentID, !showRatingKey.isEmpty else { return nil }
            self.profileID = profileID
            self.serverID = serverID
            self.showRatingKey = showRatingKey
        }

        var storageKey: String {
            let components = [profileID, serverID, showRatingKey]
            return "ShowTrackPreferences.v1." + components.map { "\($0.utf8.count):\($0)" }.joined()
        }
    }

    var defaults: UserDefaults = .standard

    func preferences(for scope: Scope) -> ShowTrackPreferences? {
        guard let data = defaults.data(forKey: scope.storageKey) else { return nil }
        return try? JSONDecoder().decode(ShowTrackPreferences.self, from: data)
    }

    func save(_ preferences: ShowTrackPreferences, for scope: Scope) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: scope.storageKey)
    }
}
