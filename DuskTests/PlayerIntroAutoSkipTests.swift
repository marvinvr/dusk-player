import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import Dusk

@Suite("Intro auto-skip configuration", .serialized)
@MainActor
struct PlayerIntroAutoSkipTests {
    @Test func engineReadinessControlsLearningWhenTheRawBufferingFlagStaysSet() throws {
        let preferences = UserPreferences()
        let previousMode = preferences.autoSkipIntroMode
        preferences.autoSkipIntroMode = .alwaysExceptFirstEpisode
        defer { preferences.autoSkipIntroMode = previousMode }
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = "plex-a"
        let details = try decoder.decode(PlexMediaDetails.self, from: Data(
            #"{"ratingKey":"episode-1","key":"/library/metadata/episode-1","type":"episode","title":"Episode 1","parentRatingKey":"season-1"}"#.utf8
        ))
        for isReady in [false, true] {
            let suite = "IntroBufferingTests-\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = IntroFingerprintStore(defaults: defaults)
            let engine = IntroAutoSkipPlaybackEngine(currentTime: 0)
            engine.isBuffering = true
            engine.introSamplingReadyOverride = isReady
            let marker = PlexMarker(id: 80, type: "intro", startTimeOffset: 0, endTimeOffset: 90_000)
            let viewModel = PlayerViewModel(engine: engine, markers: [marker], introFingerprintStore: store)
            defer { viewModel.cleanup() }
            viewModel.sync()
            viewModel.configureAutomaticTrackSelection(preferences: preferences, part: nil, mediaDetails: details,
                                                       viewerProfileID: "viewer")
            for point in fingerprint().points {
                engine.currentTime = point.time
                viewModel.sync()
                engine.deliverIntroSample(IntroFrameSample(mediaTime: point.time, signature: .init(hash: point.hash, quality: point.quality)))
            }
            let key = IntroFingerprintSeasonKey(viewerProfileID: "viewer", serverID: "plex-a", seasonRatingKey: "season-1")
            #expect(store.fingerprints(for: key).count == (isReady ? 1 : 0))
            #expect(engine.seekTargets.isEmpty)
        }
    }

    @Test func repeatOnlyModeFailsOpenWithoutAnOpeningFingerprint() async throws {
        let preferences = UserPreferences()
        let previousMode = preferences.autoSkipIntroMode
        preferences.autoSkipIntroMode = .alwaysExceptFirstEpisode
        defer { preferences.autoSkipIntroMode = previousMode }

        let marker = PlexMarker(
            id: 73,
            type: "intro",
            startTimeOffset: 5_000,
            endTimeOffset: 20_000
        )
        let engine = IntroAutoSkipPlaybackEngine(currentTime: 10)
        let viewModel = PlayerViewModel(engine: engine, markers: [marker])
        defer { viewModel.cleanup() }

        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = "plex-a"
        let details = try decoder.decode(
            PlexMediaDetails.self,
            from: Data(#"{"ratingKey":"episode-2","key":"/library/metadata/episode-2","type":"episode","title":"Episode 2","index":2,"parentRatingKey":"season-1"}"#.utf8)
        )
        viewModel.sync()
        viewModel.configureAutomaticTrackSelection(
            preferences: preferences,
            part: nil,
            mediaDetails: details,
            viewerProfileID: "viewer"
        )

        // An empty reference gallery chooses play-through immediately while learning.
        await Task.yield()
        #expect(engine.seekTargets.isEmpty)
        #expect(engine.introSampleRequestCount > 0)
        #expect(viewModel.resolvedIntroFingerprintMarkerIDs == [marker.id])

        let rebuiltViewModel = PlayerViewModel(engine: engine, markers: [marker])
        defer { rebuiltViewModel.cleanup() }
        rebuiltViewModel.configureAutomaticTrackSelection(
            preferences: preferences,
            part: nil,
            mediaDetails: details,
            resolvedIntroFingerprintMarkerIDs: viewModel.resolvedIntroFingerprintMarkerIDs,
            introOpeningSessionState: viewModel.introOpeningSessionState,
            viewerProfileID: "viewer"
        )
        #expect(rebuiltViewModel.autoSkipCountdownMarkerID == nil)
    }

    @Test func startupSyncDoesNotArmDefaultModeBeforeOffPreferenceIsApplied() {
        let preferences = UserPreferences()
        let previousMode = preferences.autoSkipIntroMode
        preferences.autoSkipIntroMode = .off
        defer { preferences.autoSkipIntroMode = previousMode }

        let marker = PlexMarker(
            id: 42,
            type: "intro",
            startTimeOffset: 5_000,
            endTimeOffset: 20_000
        )
        let engine = IntroAutoSkipPlaybackEngine(currentTime: 10)
        let viewModel = PlayerViewModel(engine: engine, markers: [marker])
        defer { viewModel.cleanup() }

        // The first timer sync can run before PlayerSessionView applies the
        // saved settings. It must not use PlayerViewModel's default mode.
        viewModel.sync()
        #expect(viewModel.autoSkipCountdownMarkerID == nil)

        viewModel.configureAutomaticTrackSelection(
            preferences: preferences,
            part: nil
        )
        #expect(viewModel.autoSkipIntroMode == .off)
        #expect(viewModel.autoSkipCountdownMarkerID == nil)

        preferences.autoSkipIntroMode = .always
        viewModel.configureAutomaticTrackSelection(preferences: preferences, part: nil)
        #expect(viewModel.autoSkipCountdownMarkerID == marker.id)

        preferences.autoSkipIntroMode = .off
        viewModel.configureAutomaticTrackSelection(preferences: preferences, part: nil)
        #expect(viewModel.autoSkipCountdownMarkerID == nil)
    }

    @Test func repeatOnlyModeDoesNotArmWithoutPlexServerIdentity() throws {
        let preferences = UserPreferences()
        let previousMode = preferences.autoSkipIntroMode
        preferences.autoSkipIntroMode = .alwaysExceptFirstEpisode
        defer { preferences.autoSkipIntroMode = previousMode }

        let marker = PlexMarker(
            id: 76,
            type: "intro",
            startTimeOffset: 5_000,
            endTimeOffset: 20_000
        )
        let details = try JSONDecoder().decode(
            PlexMediaDetails.self,
            from: Data(#"{"ratingKey":"episode-4","key":"/library/metadata/episode-4","type":"episode","title":"Episode 4","index":4,"parentRatingKey":"season-1"}"#.utf8)
        )
        let engine = IntroAutoSkipPlaybackEngine(currentTime: 10)
        let viewModel = PlayerViewModel(engine: engine, markers: [marker])
        defer { viewModel.cleanup() }

        viewModel.sync()
        viewModel.configureAutomaticTrackSelection(
            preferences: preferences,
            part: nil,
            mediaDetails: details,
            viewerProfileID: "viewer"
        )

        #expect(viewModel.autoSkipCountdownMarkerID == nil)
        #expect(engine.introSampleRequestCount == 0)
    }

    @Test func alwaysModeStillSkipsWithoutFingerprintSamples() async throws {
        let preferences = UserPreferences()
        let previousMode = preferences.autoSkipIntroMode
        preferences.autoSkipIntroMode = .always
        defer { preferences.autoSkipIntroMode = previousMode }

        let marker = PlexMarker(
            id: 74,
            type: "intro",
            startTimeOffset: 5_000,
            endTimeOffset: 20_000
        )
        let engine = IntroAutoSkipPlaybackEngine(currentTime: 10)
        let viewModel = PlayerViewModel(engine: engine, markers: [marker])
        defer { viewModel.cleanup() }

        viewModel.sync()
        viewModel.configureAutomaticTrackSelection(preferences: preferences, part: nil)
        try await Task.sleep(for: .seconds(5.2))

        #expect(engine.seekTargets == [20.5])
        #expect(engine.introSampleRequestCount == 0)
    }

    @Test func repeatConfirmsWithinFiveSecondCourtesyDelay() {
        let reference = fingerprint()
        var observation = makeObservation(references: [reference])
        var skippedAt: Double?
        for point in fingerprint().points {
            record(point, in: &observation)
            observation.advance(to: point.time)
            guard let candidate = observation.candidate(at: point.time) else { continue }
            let result = IntroOpeningFingerprintMatcher.recognize(candidate, among: observation.references, at: point.time)
            if observation.apply(result, at: point.time) { skippedAt = point.time; break }
        }
        #expect(skippedAt == 5)
    }

    @Test func periodicPlayerClockLagDoesNotExcludeTheNewestFrame() {
        let reference = IntroOpeningFingerprint(points: fingerprint().points.enumerated().map {
            IntroFingerprintPoint(time: 0.125 + Double($0.offset) * 0.25, hash: $0.element.hash)
        })
        var observation = makeObservation(references: [reference])
        var skippedAt: Double?
        for (i, point) in reference.points.prefix(21).enumerated() {
            let engineTime = Double(i) * 0.25
            record(point, in: &observation)
            observation.advance(to: engineTime)
            if let candidate = observation.candidate(at: engineTime) {
                let result = IntroOpeningFingerprintMatcher.recognize(candidate, among: [reference], at: observation.comparisonTime(at: engineTime))
                if observation.apply(result, at: engineTime) { skippedAt = engineTime; break }
            }
        }
        #expect(skippedAt == 5)
    }

    @Test func dimStructureIsRetainedWhileUniformPicturesAreRejected() {
        let side = IntroFrameHasher.side
        let structure = (0..<(side * side)).map { i in
            Double(((i % side) / 8 + (i / side) / 8) % 2) * 8 + Double(i % 8) / 8
        }
        #expect(IntroFrameHasher.hash(luminance: structure) != nil)
        #expect(IntroFrameHasher.hash(luminance: structure.map { $0 / 4 }) == nil)
        #expect(IntroFrameHasher.hash(luminance: [Double](repeating: 0, count: side * side)) == nil)
    }

    @Test func staleFramesCannotCompleteConfirmation() {
        let reference = fingerprint()
        var observation = makeObservation(references: [reference])
        for point in reference.points where point.time <= 4.5 { record(point, in: &observation) }
        let comparison = IntroOpeningFingerprintMatcher.recognize(observation.fingerprint, among: [reference], at: 4.5)
        #expect(comparison.isRepeat)
        let armedImmediately = observation.apply(comparison, at: 4.5)
        #expect(!armedImmediately)
        let skippedWithoutFreshFrame = observation.apply(comparison, at: 5)
        #expect(!skippedWithoutFreshFrame)
        observation.advance(to: 7)
        #expect(observation.phase == .collecting)
    }

    @Test func confirmationCannotSeekBeyondTheMarkerEnd() {
        let reference = fingerprint()
        var observation = IntroOpeningObservation(playbackSessionID: UUID(), episodeRatingKey: "episode", mediaPartID: 1,
            markerID: 1, markerStart: 0, markerEnd: 6.5, enteredAt: 0, references: [reference])
        for point in reference.points where point.time <= 4.5 { record(point, in: &observation) }
        let result = IntroOpeningFingerprintMatcher.recognize(observation.fingerprint, among: [reference], at: 4.5)
        let skippedWhenArmed = observation.apply(result, at: 4.5)
        #expect(!skippedWhenArmed)
        record(reference.points[12], in: &observation)
        let endResult = IntroOpeningFingerprintMatcher.recognize(observation.fingerprint, among: [reference], at: 6)
        #expect(endResult.isRepeat)
        let skippedBeyondMarker = observation.apply(endResult, at: 6.75)
        #expect(!skippedBeyondMarker)
    }

    @Test func scrubbingCancelsTheVisibleCountdownImmediately() {
        let preferences = UserPreferences()
        let previousMode = preferences.autoSkipIntroMode
        preferences.autoSkipIntroMode = .always
        defer { preferences.autoSkipIntroMode = previousMode }
        let marker = PlexMarker(id: 90, type: "intro", startTimeOffset: 5_000, endTimeOffset: 20_000)
        let engine = IntroAutoSkipPlaybackEngine(currentTime: 10)
        let viewModel = PlayerViewModel(engine: engine, markers: [marker])
        defer { viewModel.cleanup() }
        viewModel.sync()
        viewModel.configureAutomaticTrackSelection(preferences: preferences, part: nil)
        #expect(viewModel.autoSkipCountdownMarkerID == marker.id)
        viewModel.beginScrub()
        #expect(viewModel.autoSkipCountdownMarkerID == nil)
        #expect(engine.seekTargets.isEmpty)
    }

    @Test func divergingSuffixCannotConfirmFromOldMatches() {
        let dense = IntroOpeningFingerprint(points: fingerprint().points.map {
            IntroFingerprintPoint(time: $0.time / 2, hash: $0.hash)
        })
        var observation = makeObservation(references: [dense])
        for point in dense.points where point.time <= 4.5 { record(point, in: &observation) }
        let established = IntroOpeningFingerprintMatcher.recognize(observation.fingerprint, among: [dense], at: 4.5)
        #expect(established.isRepeat)
        let skippedWhenEstablished = observation.apply(established, at: 4.5)
        #expect(!skippedWhenEstablished)
        for i in 19...22 {
            let point = IntroFingerprintPoint(time: Double(i) * 0.25, hash: fingerprint(variant: 1_000).points[i - 19].hash)
            record(point, in: &observation)
            let comparison = IntroOpeningFingerprintMatcher.recognize(observation.fingerprint, among: [dense], at: point.time)
            let skippedAfterDivergence = observation.apply(comparison, at: point.time)
            #expect(!skippedAfterDivergence)
        }
    }

    @Test func firstOpeningLearnsWithoutArmingAndCannotMatchItsOwnRebuild() {
        var observation = makeObservation(references: [])
        #expect(observation.phase == .playThrough)
        for point in fingerprint().points { record(point, in: &observation) }
        #expect(observation.fingerprint.isEligibleReference)
        let rebuilt = makeObservation(references: [observation.fingerprint], sessionID: observation.playbackSessionID)
        #expect(rebuilt.references.isEmpty)
        #expect(rebuilt.phase == .playThrough)
    }

    @Test func incompleteRecognitionTerminatesButStillLearns() {
        var observation = makeObservation(references: [fingerprint()])
        observation.advance(to: 12.1)
        #expect(observation.phase == .playThrough)
        for point in fingerprint().points { record(point, in: &observation) }
        #expect(observation.fingerprint.isEligibleReference)
        #expect(observation.candidate(at: 15) == nil)
    }

    @Test func matcherAlignsFractionalOffsetsAndRejectsUnorderedStaticOrDistantEvidence() {
        let reference = fingerprint()
        let shifted = IntroOpeningFingerprint(points: reference.points.map {
            IntroFingerprintPoint(time: $0.time + 0.35,
                                  hash: IntroFrameHash(horizontal: $0.hash.horizontal ^ 3, vertical: $0.hash.vertical))
        })
        #expect(IntroOpeningFingerprintMatcher.compare(shifted, reference, at: 5.35).isRepeat)
        let reversed = IntroOpeningFingerprint(points: reference.points.enumerated().map {
            IntroFingerprintPoint(time: $0.element.time, hash: reference.points[reference.points.count - 1 - $0.offset].hash)
        })
        #expect(!IntroOpeningFingerprintMatcher.compare(reversed, reference, at: 5).isRepeat)
        let staticCard = IntroOpeningFingerprint(points: reference.points.map {
            IntroFingerprintPoint(time: $0.time, hash: reference.points[0].hash)
        })
        #expect(!staticCard.isEligibleReference)
        #expect(!IntroOpeningFingerprintMatcher.compare(staticCard, staticCard, at: 5).isRepeat)
        let distant = IntroOpeningFingerprint(points: reference.points.map {
            IntroFingerprintPoint(time: $0.time + 10, hash: $0.hash)
        })
        #expect(!IntroOpeningFingerprintMatcher.compare(reference, distant, at: 5).isRepeat)
    }

    @Test func repeatedOpeningRecognitionHandlesAABAAcrossASeason() {
        let suiteName = "IntroFingerprintTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = IntroFingerprintStore(defaults: defaults)
        let season = IntroFingerprintSeasonKey(viewerProfileID: "viewer", serverID: "plex-a", seasonRatingKey: "season-1")
        var wasRepeat: [Bool] = []
        for variant in [0, 0, 100, 0] {
            let candidate = fingerprint(variant: variant)
            let result = IntroOpeningFingerprintMatcher.recognize(candidate, among: store.fingerprints(for: season), at: 5)
            wasRepeat.append(result.isRepeat)
            if !result.isRepeat { store.insert(candidate, for: season) }
        }
        #expect(wasRepeat == [false, true, false, true])
        let reloaded = IntroFingerprintStore(defaults: defaults)
        #expect(reloaded.fingerprints(for: season).count == 2)
        #expect(reloaded.fingerprints(for: .init(viewerProfileID: "other", serverID: "plex-a", seasonRatingKey: "season-1")).isEmpty)
        #expect(reloaded.fingerprints(for: .init(viewerProfileID: "viewer", serverID: "plex-b", seasonRatingKey: "season-1")).isEmpty)
        #expect(reloaded.fingerprints(for: .init(viewerProfileID: "viewer", serverID: "plex-a", seasonRatingKey: "season-2")).isEmpty)
    }

    @Test func rebuiltPlayerDoesNotReuseSamplesFromAnotherMediaPart() throws {
        let preferences = UserPreferences()
        let previousMode = preferences.autoSkipIntroMode
        preferences.autoSkipIntroMode = .alwaysExceptFirstEpisode
        defer { preferences.autoSkipIntroMode = previousMode }
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = "plex-a"
        let details = try decoder.decode(PlexMediaDetails.self, from: Data(#"{"ratingKey":"episode-2","key":"/library/metadata/episode-2","type":"episode","title":"Episode 2","parentRatingKey":"season-1"}"#.utf8))
        let part = try decoder.decode(PlexMediaPart.self, from: Data(#"{"id":2,"key":"/library/parts/2/file.mkv"}"#.utf8))
        let owner = IntroOpeningSessionState()
        let old = IntroOpeningObservation(playbackSessionID: owner.id, episodeRatingKey: "episode-2", mediaPartID: 1,
                                          markerID: 91, markerStart: 5, markerEnd: 20, enteredAt: 5, references: [])
        owner.observations[91] = old
        let marker = PlexMarker(id: 91, type: "intro", startTimeOffset: 5_000, endTimeOffset: 20_000)
        let viewModel = PlayerViewModel(engine: IntroAutoSkipPlaybackEngine(currentTime: 10), markers: [marker])
        defer { viewModel.cleanup() }
        viewModel.sync()
        viewModel.configureAutomaticTrackSelection(preferences: preferences, part: part, mediaDetails: details,
                                                  introOpeningSessionState: owner, viewerProfileID: "viewer")
        #expect(owner.observations[91]?.id != old.id)
        #expect(owner.observations[91]?.mediaPartID == 2)
        #expect(owner.observations[91]?.phase == .playThrough)
        #expect(viewModel.autoSkipCountdownMarkerID == nil)
    }

    @Test func repeatOnlyPreferenceKeepsItsStoredValueAndNewLabel() {
        #expect(AutoSkipIntroMode(rawValue: "alwaysExceptFirstEpisode") == .alwaysExceptFirstEpisode)
        #expect(AutoSkipIntroMode.alwaysExceptFirstEpisode.displayName == "Skip Repeated Intros")
    }
}

private func fingerprint(variant: Int = 0) -> IntroOpeningFingerprint {
    func mix(_ value: UInt64) -> UInt64 {
        var value = value &+ 0x9e3779b97f4a7c15
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
    return IntroOpeningFingerprint(points: (0..<24).map { index in
        IntroFingerprintPoint(time: Double(index) * 0.5,
                              hash: IntroFrameHash(horizontal: mix(UInt64(index + variant)), vertical: mix(UInt64(index + variant + 100))))
    })
}

private func makeObservation(references: [IntroOpeningFingerprint], sessionID: UUID = UUID()) -> IntroOpeningObservation {
    IntroOpeningObservation(playbackSessionID: sessionID, episodeRatingKey: "episode", mediaPartID: 1,
                            markerID: 1, markerStart: 0, markerEnd: 90, enteredAt: 0, references: references)
}

private func record(_ point: IntroFingerprintPoint, in observation: inout IntroOpeningObservation) {
    _ = observation.record(IntroFrameSample(mediaTime: point.time, signature: .init(hash: point.hash, quality: point.quality)))
}

@MainActor
private final class IntroAutoSkipPlaybackEngine: PlaybackEngine {
    var state: PlaybackState
    var currentTime: TimeInterval
    let duration: TimeInterval = 120
    var isBuffering = false
    var introSamplingReadyOverride: Bool?
    var isReadyForIntroFrameSampling: Bool {
        introSamplingReadyOverride ?? (state == .playing && !isBuffering)
    }
    let error: PlaybackError? = nil
    let videoEnhancementStatus = VideoEnhancementStatus.disabled
    var onPlaybackEnded: (@MainActor () -> Void)?
    let availableSubtitleTracks: [SubtitleTrack] = []
    let availableAudioTracks: [AudioTrack] = []
    let selectedSubtitleTrackID: Int? = nil
    let selectedAudioTrackID: Int? = nil
    private let player = AVPlayer()
    private(set) var seekTargets: [TimeInterval] = []
    private(set) var introSampleRequestCount = 0
    private var introSampleHandler: (@MainActor (IntroFrameSample) -> Void)?

    var playbackCoordinator: AVPlaybackCoordinator { player.playbackCoordinator }

    init(currentTime: TimeInterval, state: PlaybackState = .playing) {
        self.currentTime = currentTime
        self.state = state
    }

    func load(source: PlaybackSource) {}
    func configureVideoEnhancement(_ request: VideoEnhancementRequest) {}
    func setIntroFrameSampleHandler(_ handler: (@MainActor (IntroFrameSample) -> Void)?) {
        introSampleHandler = handler
    }
    func requestIntroFrameSample() {
        introSampleRequestCount += 1
    }
    func deliverIntroSample(_ sample: IntroFrameSample) {
        introSampleHandler?(sample)
    }
    func play() {}
    func pause() {}
    func stop() {}
    func seek(to position: TimeInterval) { seekTargets.append(position) }
    func setPlaybackRate(_ rate: Float) {}
    func configureCoordinatedPlayback(itemIdentifier: String?) {}
    func recoverFromStall() {}
    func handleReturnToForeground() {}
    func selectSubtitleTrack(_ track: SubtitleTrack?) {}
    func selectAudioTrack(_ track: AudioTrack) {}
    func makePlayerView() -> AnyView { AnyView(EmptyView()) }
}
