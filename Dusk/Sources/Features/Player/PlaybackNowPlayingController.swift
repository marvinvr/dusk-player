import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import os

private let nowPlayingLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "PlaybackNowPlaying"
)

@MainActor
final class PlaybackNowPlayingController {
    enum RemoteAction: Sendable {
        case play, pause, togglePlayPause
        case skip(TimeInterval)
        case seek(TimeInterval)
        case beginSeeking(forward: Bool)
        case endSeeking
    }

    private weak var engine: (any PlaybackEngine)?
    private var nowPlayingInfo: [String: Any] = [:]
    private var commandTargets: [(command: MPRemoteCommand, target: Any)] = []
    private var sessionID: UUID?
    private var snapshotTimer: Timer?
    private var remoteSeekTask: Task<Void, Never>?
    private var artworkTask: Task<Void, Never>?
    #if os(iOS)
    private var notificationObservers: [NSObjectProtocol] = []
    private var backgroundPlaybackRecoveryTask: Task<Void, Never>?
    private var isAudioSessionActive = false
    private var isAudioSessionInterrupted = false
    private var isApplicationActive = true
    private var shouldContinuePlaybackWhenInactive = false
    private var wasPlayingBeforeInterruption = false
    #endif
    private var skipBackwardInterval: TimeInterval = 10
    private var skipForwardInterval: TimeInterval = 10
    private var lastPublishedState: PlaybackState?
    private var lastPublishedElapsedTime: TimeInterval = 0
    private var lastPublishedDuration: TimeInterval = 0
    private var lastPublishedRate: Double = 0
    private var lastPublishedAt: TimeInterval = 0
    private var hasPublishedActiveState = false

    private static let playingElapsedUpdateThreshold: TimeInterval = 8
    private static let pausedElapsedUpdateThreshold: TimeInterval = 0.5

    func beginSession(
        details: PlexMediaDetails,
        engine: any PlaybackEngine,
        plexService: PlexService,
        skipBackwardInterval: TimeInterval,
        skipForwardInterval: TimeInterval
    ) {
        // Reset any previous session WITHOUT deactivating the shared
        // AVAudioSession: `setActive(false, .notifyOthersOnDeactivation)`
        // followed by an immediate `setActive(true)` for the new item is a
        // route whiplash (it invites other apps to resume mid-handoff), and
        // rapid deactivate/activate cycles are exactly what produces the
        // transient session errors that latch VLCKit's audio output silent.
        endSession(deactivateAudioSession: false)

        sessionID = UUID()
        self.engine = engine
        self.skipBackwardInterval = skipBackwardInterval
        self.skipForwardInterval = skipForwardInterval
        #if os(iOS)
        isApplicationActive = UIApplication.shared.applicationState == .active
        configureAndActivateAudioSession()
        registerAudioSessionObservers()
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif
        configureRemoteCommands()
        publishInitialMetadata(for: details)
        loadArtwork(for: details, using: plexService)
        startSnapshotUpdates()
    }

    func beginLiveSession(
        title: String,
        channelTitle: String,
        artworkPath: String?,
        serverID: String?,
        engine: any PlaybackEngine,
        plexService: PlexService,
        skipBackwardInterval: TimeInterval,
        skipForwardInterval: TimeInterval,
        isLive: Bool = true
    ) {
        endSession(deactivateAudioSession: false)
        sessionID = UUID()
        self.engine = engine
        self.skipBackwardInterval = skipBackwardInterval
        self.skipForwardInterval = skipForwardInterval
        #if os(iOS)
        isApplicationActive = UIApplication.shared.applicationState == .active
        configureAndActivateAudioSession()
        registerAudioSessionObservers()
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif
        configureRemoteCommands()
        nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: channelTitle,
            MPMediaItemPropertyAlbumTitle: "Live TV",
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackRate: 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: isLive,
            MPNowPlayingInfoPropertyExcludeFromSuggestions: false,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        MPNowPlayingInfoCenter.default().playbackState = .paused
        loadLiveArtwork(path: artworkPath, serverID: serverID, using: plexService)
        startSnapshotUpdates()
    }

    /// Follows the tuned channel's schedule: a live session outlives the
    /// program it started on, and the lock screen should not still be naming
    /// the show that ended an hour ago. Title only — the channel artwork stays
    /// put across program changes.
    func updateLiveProgramTitle(_ title: String) {
        guard let engine, engine.state != .stopped,
              nowPlayingInfo[MPMediaItemPropertyTitle] as? String != title else { return }

        nowPlayingInfo[MPMediaItemPropertyTitle] = title
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    func updatePlaybackState(
        state: PlaybackState,
        currentTime: TimeInterval,
        duration: TimeInterval,
        force: Bool = false
    ) {
        guard engine != nil else { return }
        #if os(iOS)
        updatePlaybackIntent(for: state)
        #endif
        if state == .stopped {
            // Warmed/reused engines can still be stopped when beginSession
            // publishes metadata, just before PlayerSessionView loads them.
            guard hasPublishedActiveState || force else { return }
            remoteSeekTask?.cancel()
            removeRemoteCommandTargets()
            if lastPublishedState != .stopped { clearPublishedInfo() }
            return
        }
        if state != .idle { hasPublishedActiveState = true }
        guard shouldPublish(state: state, currentTime: currentTime, duration: duration, force: force) else {
            return
        }

        publishPlaybackState(state: state, currentTime: currentTime, duration: duration)
    }

    func endSession(deactivateAudioSession: Bool = true) {
        // An unused coordinator must not clear another active player's entry.
        guard sessionID != nil else { return }
        sessionID = nil
        snapshotTimer?.invalidate()
        snapshotTimer = nil
        remoteSeekTask?.cancel()
        remoteSeekTask = nil
        artworkTask?.cancel()
        artworkTask = nil
        removeRemoteCommandTargets()
        clearPublishedInfo()
        #if os(iOS)
        backgroundPlaybackRecoveryTask?.cancel()
        backgroundPlaybackRecoveryTask = nil
        removeAudioSessionObservers()
        UIApplication.shared.endReceivingRemoteControlEvents()

        if isAudioSessionActive {
            if deactivateAudioSession {
                do {
                    try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
                } catch {
                    // Expected when the engine's audio output has not fully
                    // wound down yet (the session reports itself busy);
                    // harmless, so never trap debug builds over it.
                    nowPlayingLogger.warning(
                        "Failed to deactivate playback audio session: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            isAudioSessionActive = false
        }
        isAudioSessionInterrupted = false
        isApplicationActive = true
        shouldContinuePlaybackWhenInactive = false
        wasPlayingBeforeInterruption = false
        #endif
        engine = nil
        nowPlayingInfo = [:]
        lastPublishedState = nil
        lastPublishedElapsedTime = 0
        lastPublishedDuration = 0
        lastPublishedRate = 0
        lastPublishedAt = 0
        hasPublishedActiveState = false
    }

    /// All system commands use the same dispatcher on both playback engines.
    @discardableResult
    func handleRemoteAction(_ action: RemoteAction) -> MPRemoteCommandHandlerStatus {
        guard let engine, engine.state != .stopped else { return .noSuchContent }
        switch action {
        case .play, .pause, .togglePlayPause:
            remoteSeekTask?.cancel()
            let wantsPlay: Bool
            switch action {
            case .play: wantsPlay = true
            case .pause: wantsPlay = false
            default: wantsPlay = engine.state != .playing
            }
            #if os(iOS)
            shouldContinuePlaybackWhenInactive = wantsPlay
            #endif
            if wantsPlay { engine.play() } else { engine.pause() }
            publishEngineSnapshot(force: true)
        case .skip(let interval):
            guard interval.isFinite else { return .commandFailed }
            seek(by: interval)
        case .seek(let position):
            guard position.isFinite else { return .commandFailed }
            seek(to: position)
        case .beginSeeking(let forward):
            remoteSeekTask?.cancel()
            let offset: TimeInterval = forward ? 10 : -10
            seek(by: offset)
            remoteSeekTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    seek(by: offset)
                }
            }
        case .endSeeking:
            remoteSeekTask?.cancel()
            remoteSeekTask = nil
            publishEngineSnapshot(force: true)
        }
        return .success
    }
}

private extension PlaybackNowPlayingController {
    #if os(iOS)
    func configureAndActivateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        let wantsSpatializedAudio = engine?.prefersSpatializedAudioSession ?? true

        do {
            // VLCKit's raw audio output stutters when iOS spatializes it for a
            // Bluetooth route (AirPods), so it asks for a plain `.default`
            // session with no movie signal processing or multichannel content.
            // AVPlayer keeps `.moviePlayback`, which it feeds natively.
            let mode: AVAudioSession.Mode = wantsSpatializedAudio ? .moviePlayback : .default
            try session.setCategory(.playback, mode: mode, policy: .longFormVideo)
            if #available(iOS 15.0, *) {
                try session.setSupportsMultichannelContent(wantsSpatializedAudio)
            }
            if !wantsSpatializedAudio {
                // Give the output more slack against the higher-latency, jittery
                // Bluetooth clock so a brief scheduling hiccup does not underrun.
                try? session.setPreferredIOBufferDuration(0.03)
            }
            try session.setActive(true)
            isAudioSessionActive = true
        } catch {
            // Transient activation failures are normal while a Bluetooth
            // route or another app's session settles. VLCKit's audio output
            // retries activation itself (and self-recovers via an output
            // restart), so log instead of trapping debug builds.
            nowPlayingLogger.warning(
                "Failed to activate playback audio session: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
    #endif

    func startSnapshotUpdates() {
        publishEngineSnapshot(force: false)
        // Independent of the player HUD: PiP, background playback, SharePlay,
        // track changes and engine callbacks must also reach the system.
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publishEngineSnapshot(force: false)
            }
        }
    }

    func clearPublishedInfo() {
        artworkTask?.cancel()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        lastPublishedState = .stopped
        lastPublishedRate = 0
    }

    func publishInitialMetadata(for details: PlexMediaDetails) {
        nowPlayingInfo = [
            MPMediaItemPropertyTitle: nowPlayingTitle(for: details),
            MPNowPlayingInfoPropertyExternalContentIdentifier: details.ratingKey,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyPlaybackRate: 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: 0.0,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyExcludeFromSuggestions: false,
        ]

        if let subtitle = nowPlayingSubtitle(for: details) {
            nowPlayingInfo[MPMediaItemPropertyArtist] = subtitle
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = subtitle
        }
        if details.type == .episode {
            nowPlayingInfo[MPMediaItemPropertyAlbumTrackNumber] = details.index
            nowPlayingInfo[MPMediaItemPropertyDiscNumber] = details.parentIndex
        }

        if let duration = details.duration, duration > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = TimeInterval(duration) / 1000.0
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        MPNowPlayingInfoCenter.default().playbackState = .paused
    }

    func publishPlaybackState(
        state: PlaybackState,
        currentTime: TimeInterval,
        duration: TimeInterval
    ) {
        let elapsed = currentTime.isFinite ? max(0, currentTime) : 0
        let safeDuration = duration.isFinite ? max(0, duration) : 0
        let playbackRate = publishedRate(for: state)

        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = playbackRate
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        if safeDuration > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = safeDuration
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        MPNowPlayingInfoCenter.default().playbackState = nowPlayingPlaybackState(for: state)

        lastPublishedState = state
        lastPublishedElapsedTime = elapsed
        lastPublishedDuration = safeDuration
        lastPublishedRate = playbackRate
        lastPublishedAt = ProcessInfo.processInfo.systemUptime
    }

    func shouldPublish(
        state: PlaybackState,
        currentTime: TimeInterval,
        duration: TimeInterval,
        force: Bool
    ) -> Bool {
        if force { return true }
        if state != lastPublishedState { return true }
        if publishedRate(for: state) != lastPublishedRate { return true }
        if abs(duration - lastPublishedDuration) > 0.5 { return true }

        let sincePublication = ProcessInfo.processInfo.systemUptime - lastPublishedAt
        let expectedElapsed = lastPublishedElapsedTime + sincePublication * lastPublishedRate
        // Compare with the system's extrapolated clock so even a small seek
        // publishes immediately, without sending every normal time tick.
        return abs(currentTime - expectedElapsed) >= Self.pausedElapsedUpdateThreshold
            || sincePublication >= Self.playingElapsedUpdateThreshold
    }

    func publishedRate(for state: PlaybackState) -> Double {
        guard state == .playing, let rate = engine?.playbackRate, rate.isFinite else { return 0 }
        return Double(max(0, rate))
    }

    func nowPlayingPlaybackState(for state: PlaybackState) -> MPNowPlayingPlaybackState {
        switch state {
        case .playing:
            return .playing
        case .paused:
            return .paused
        case .loading:
            return .interrupted
        case .idle, .stopped, .error:
            return .stopped
        }
    }

    func nowPlayingTitle(for details: PlexMediaDetails) -> String {
        if details.type == .episode,
           let grandparentTitle = details.grandparentTitle,
           let parentIndex = details.parentIndex,
           let index = details.index {
            return "\(grandparentTitle) S\(parentIndex)E\(index): \(details.title)"
        }

        return details.title
    }

    func nowPlayingSubtitle(for details: PlexMediaDetails) -> String? {
        switch details.type {
        case .episode:
            return details.grandparentTitle
        case .movie:
            if let year = details.year {
                return String(year)
            }
            return details.studio
        case .show, .season:
            return details.year.map(String.init)
        case .person, .clip, .artist, .album, .track, .collection, .unknown:
            return nil
        }
    }

    func loadArtwork(for details: PlexMediaDetails, using plexService: PlexService) {
        let artworkPath = details.thumb
            ?? details.grandparentThumb
            ?? details.parentThumb
            ?? details.art

        guard let artworkURL = plexService.imageURL(
            for: artworkPath,
            serverID: details.serverID,
            width: 640,
            height: 640
        ) else {
            return
        }

        let artworkSessionID = sessionID
        artworkTask = Task { @MainActor [weak self, weak plexService] in
            guard let self, let plexService else { return }

            do {
                let image = try await DuskImageLoader.shared.image(for: artworkURL, using: plexService)
                guard !Task.isCancelled, self.sessionID == artworkSessionID else { return }

                guard let imageData = image.jpegData(compressionQuality: 0.9) else { return }
                let artwork = makeNowPlayingArtwork(imageData: imageData, imageSize: image.size)
                self.nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = self.nowPlayingInfo
            } catch {
                return
            }
        }
    }

    func loadLiveArtwork(path: String?, serverID: String?, using plexService: PlexService) {
        guard let artworkURL = plexService.imageURL(
            for: path,
            serverID: serverID,
            width: 640,
            height: 360
        ) else {
            return
        }
        let artworkSessionID = sessionID
        artworkTask = Task { @MainActor [weak self, weak plexService] in
            guard let self, let plexService else { return }
            guard let image = try? await DuskImageLoader.shared.image(for: artworkURL, using: plexService),
                  !Task.isCancelled,
                  self.sessionID == artworkSessionID,
                  let imageData = image.jpegData(compressionQuality: 0.9) else { return }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = makeNowPlayingArtwork(
                imageData: imageData,
                imageSize: image.size
            )
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        }
    }

    func configureRemoteCommands() {
        removeRemoteCommandTargets()
        let center = MPRemoteCommandCenter.shared()
        addTarget(to: center.playCommand) { _ in .play }
        addTarget(to: center.pauseCommand) { _ in .pause }
        addTarget(to: center.togglePlayPauseCommand) { _ in .togglePlayPause }

        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackwardInterval)]
        addTarget(to: center.skipBackwardCommand) { event in
            guard let event = event as? MPSkipIntervalCommandEvent else { return nil }
            return .skip(-event.interval)
        }
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForwardInterval)]
        addTarget(to: center.skipForwardCommand) { event in
            guard let event = event as? MPSkipIntervalCommandEvent else { return nil }
            return .skip(event.interval)
        }
        addTarget(to: center.changePlaybackPositionCommand) { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return nil }
            return .seek(event.positionTime)
        }
        addTarget(to: center.seekBackwardCommand) { event in
            guard let event = event as? MPSeekCommandEvent else { return nil }
            return event.type == .beginSeeking ? .beginSeeking(forward: false) : .endSeeking
        }
        addTarget(to: center.seekForwardCommand) { event in
            guard let event = event as? MPSeekCommandEvent else { return nil }
            return event.type == .beginSeeking ? .beginSeeking(forward: true) : .endSeeking
        }
    }

    func addTarget(
        to command: MPRemoteCommand,
        action: @escaping @Sendable (MPRemoteCommandEvent) -> RemoteAction?
    ) {
        command.isEnabled = true
        let targetSessionID = sessionID
        let target = command.addTarget { [weak self] event in
            guard let self else { return .noSuchContent }
            guard let action = action(event) else { return .commandFailed }
            Task { @MainActor [weak self] in
                // A queued command from the outgoing item must never seek or
                // toggle the episode that Up Next has just installed.
                guard let self, sessionID == targetSessionID else { return }
                handleRemoteAction(action)
            }
            return .success
        }
        commandTargets.append((command, target))
    }

    func removeRemoteCommandTargets() {
        for entry in commandTargets {
            entry.command.removeTarget(entry.target)
            entry.command.isEnabled = false
        }

        commandTargets.removeAll()
    }

    func seek(by offset: TimeInterval) {
        guard let engine else { return }

        let range = engine.seekableTimeRange
            ?? (engine.duration > 0 ? 0...engine.duration : 0...(.greatestFiniteMagnitude))
        let target = min(max(engine.currentTime + offset, range.lowerBound), range.upperBound)
        seek(to: target)
    }

    func seek(to position: TimeInterval) {
        guard let engine else { return }

        let range = engine.seekableTimeRange
            ?? (engine.duration > 0 ? 0...engine.duration : 0...(.greatestFiniteMagnitude))
        let clampedPosition = min(max(position, range.lowerBound), range.upperBound)
        engine.seek(to: clampedPosition)
        publishPlaybackState(
            state: engine.state,
            currentTime: clampedPosition,
            duration: engine.duration
        )
    }

    func publishEngineSnapshot(force: Bool) {
        guard let engine else { return }

        updatePlaybackState(
            state: engine.state,
            currentTime: engine.currentTime,
            duration: engine.duration,
            force: force
        )
    }

    #if os(iOS)
    func registerAudioSessionObservers() {
        removeAudioSessionObservers()

        let center = NotificationCenter.default
        notificationObservers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                Task { @MainActor [weak self] in
                    self?.handleAudioSessionInterruption(
                        typeValue: typeValue,
                        optionsValue: optionsValue
                    )
                }
            }
        )

        notificationObservers.append(
            center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleApplicationWillResignActive()
                }
            }
        )

        notificationObservers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleBackgroundPlaybackRecovery()
                }
            }
        )

        notificationObservers.append(
            center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleApplicationDidBecomeActive()
                }
            }
        )

        notificationObservers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                Task { @MainActor [weak self] in
                    self?.handleAudioRouteChange(reasonValue: reasonValue)
                }
            }
        )
    }

    func removeAudioSessionObservers() {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()
    }

    func handleAudioSessionInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard let typeValue,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            isAudioSessionInterrupted = true
            let wasPlaying = engine?.state == .playing
            wasPlayingBeforeInterruption = wasPlaying
            // Only pause when actually playing: interruptions delivered
            // while the engine is still loading/buffering (Bluetooth
            // handoffs love firing mid-startup) must not poke the player
            // mid-open — the engine keeps its own startup sequencing.
            if wasPlaying {
                engine?.pause()
            }
            publishEngineSnapshot(force: true)
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
            isAudioSessionInterrupted = false
            configureAndActivateAudioSession()

            if wasPlayingBeforeInterruption, options.contains(.shouldResume) {
                shouldContinuePlaybackWhenInactive = true
                engine?.play()
            } else if wasPlayingBeforeInterruption {
                shouldContinuePlaybackWhenInactive = false
            }
            wasPlayingBeforeInterruption = false
            publishEngineSnapshot(force: true)
        @unknown default:
            break
        }
    }

    func handleAudioRouteChange(reasonValue: UInt?) {
        guard let reasonValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        if reason == .oldDeviceUnavailable {
            shouldContinuePlaybackWhenInactive = false
            engine?.pause()
            publishEngineSnapshot(force: true)
        }
    }

    func updatePlaybackIntent(for state: PlaybackState) {
        switch state {
        case .playing:
            shouldContinuePlaybackWhenInactive = true
        case .paused:
            // A paused engine state alone does not identify who paused it. The
            // intent is captured from the live engine at resign-active, while
            // explicit Control Center commands update it directly above.
            break
        case .idle, .stopped, .error:
            shouldContinuePlaybackWhenInactive = false
        case .loading:
            break
        }
    }

    func handleApplicationWillResignActive() {
        if isApplicationActive {
            shouldContinuePlaybackWhenInactive = engine?.state == .playing
        }
        isApplicationActive = false
        scheduleBackgroundPlaybackRecovery()
    }

    func handleApplicationDidBecomeActive() {
        backgroundPlaybackRecoveryTask?.cancel()
        backgroundPlaybackRecoveryTask = nil
        isApplicationActive = true
        recoverBackgroundPlaybackIfNeeded()
    }

    func scheduleBackgroundPlaybackRecovery() {
        guard shouldContinuePlaybackWhenInactive else { return }

        backgroundPlaybackRecoveryTask?.cancel()
        backgroundPlaybackRecoveryTask = Task { @MainActor [weak self] in
            // Some engine/system pause callbacks arrive after resign-active.
            // Recheck twice so Control Center and a full background transition
            // are both covered without polling for the lifetime of the session.
            for delay in [Duration.milliseconds(150), .milliseconds(500)] {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                self.recoverBackgroundPlaybackIfNeeded()
            }
        }
    }

    func recoverBackgroundPlaybackIfNeeded() {
        guard shouldContinuePlaybackWhenInactive,
              !isAudioSessionInterrupted,
              let engine,
              engine.state == .paused else {
            return
        }

        configureAndActivateAudioSession()
        nowPlayingLogger.notice("Recovering an unsolicited lifecycle playback pause")
        engine.play()
        publishEngineSnapshot(force: true)
    }
    #endif
}

private nonisolated func makeNowPlayingArtwork(
    imageData: Data,
    imageSize: CGSize
) -> MPMediaItemArtwork {
    MPMediaItemArtwork(boundsSize: imageSize) { _ in
        UIImage(data: imageData) ?? UIImage()
    }
}
