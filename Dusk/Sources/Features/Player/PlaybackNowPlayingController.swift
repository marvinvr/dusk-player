import Foundation

#if os(iOS)
import AVFoundation
import MediaPlayer
import UIKit
#endif

@MainActor
final class PlaybackNowPlayingController {
    #if os(iOS)
    private weak var engine: (any PlaybackEngine)?
    private weak var plexService: PlexService?
    private var details: PlexMediaDetails?
    private var nowPlayingInfo: [String: Any] = [:]
    private var commandTargets: [(command: MPRemoteCommand, target: Any)] = []
    private var notificationObservers: [NSObjectProtocol] = []
    private var artworkTask: Task<Void, Never>?
    private var isAudioSessionActive = false
    private var wasPlayingBeforeInterruption = false
    private var skipBackwardInterval: TimeInterval = 10
    private var skipForwardInterval: TimeInterval = 10
    private var lastPublishedState: PlaybackState?
    private var lastPublishedElapsedTime: TimeInterval = 0
    private var lastPublishedDuration: TimeInterval = 0

    private static let playingElapsedUpdateThreshold: TimeInterval = 8
    private static let pausedElapsedUpdateThreshold: TimeInterval = 0.5
    #endif

    func beginSession(
        details: PlexMediaDetails,
        engine: any PlaybackEngine,
        plexService: PlexService,
        skipBackwardInterval: TimeInterval,
        skipForwardInterval: TimeInterval
    ) {
        #if os(iOS)
        endSession()

        self.details = details
        self.engine = engine
        self.plexService = plexService
        self.skipBackwardInterval = skipBackwardInterval
        self.skipForwardInterval = skipForwardInterval

        configureAndActivateAudioSession()
        configureRemoteCommands()
        registerAudioSessionObservers()
        publishInitialMetadata(for: details)
        loadArtwork(for: details, using: plexService)
        UIApplication.shared.beginReceivingRemoteControlEvents()
        #endif
    }

    func updatePlaybackState(
        state: PlaybackState,
        currentTime: TimeInterval,
        duration: TimeInterval,
        force: Bool = false
    ) {
        #if os(iOS)
        guard details != nil else { return }
        guard shouldPublish(state: state, currentTime: currentTime, duration: duration, force: force) else {
            return
        }

        publishPlaybackState(state: state, currentTime: currentTime, duration: duration)
        #endif
    }

    func endSession() {
        #if os(iOS)
        artworkTask?.cancel()
        artworkTask = nil
        removeRemoteCommandTargets()
        removeAudioSessionObservers()

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        UIApplication.shared.endReceivingRemoteControlEvents()

        if isAudioSessionActive {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            } catch {
                assertionFailure("Failed to deactivate playback audio session: \(error.localizedDescription)")
            }
            isAudioSessionActive = false
        }

        engine = nil
        plexService = nil
        details = nil
        nowPlayingInfo = [:]
        wasPlayingBeforeInterruption = false
        lastPublishedState = nil
        lastPublishedElapsedTime = 0
        lastPublishedDuration = 0
        #endif
    }
}

#if os(iOS)
private extension PlaybackNowPlayingController {
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
            assertionFailure("Failed to activate playback audio session: \(error.localizedDescription)")
        }
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
        let elapsed = max(0, currentTime)
        let safeDuration = max(0, duration)
        let playbackRate = state == .playing ? 1.0 : 0.0

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
    }

    func shouldPublish(
        state: PlaybackState,
        currentTime: TimeInterval,
        duration: TimeInterval,
        force: Bool
    ) -> Bool {
        if force { return true }
        if state != lastPublishedState { return true }
        if abs(duration - lastPublishedDuration) > 0.5 { return true }

        let elapsedDelta = abs(currentTime - lastPublishedElapsedTime)
        if state == .playing {
            return elapsedDelta >= Self.playingElapsedUpdateThreshold
        }

        return elapsedDelta >= Self.pausedElapsedUpdateThreshold
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
        case .person, .clip, .artist, .album, .track, .unknown:
            return nil
        }
    }

    func loadArtwork(for details: PlexMediaDetails, using plexService: PlexService) {
        let artworkPath = details.thumb
            ?? details.grandparentThumb
            ?? details.parentThumb
            ?? details.art

        guard let artworkURL = plexService.imageURL(for: artworkPath, width: 640, height: 640) else {
            return
        }

        artworkTask = Task { @MainActor [weak self, weak plexService] in
            guard let self, let plexService else { return }

            do {
                let image = try await DuskImageLoader.shared.image(for: artworkURL, using: plexService)
                guard !Task.isCancelled, self.details?.ratingKey == details.ratingKey else { return }

                guard let imageData = image.jpegData(compressionQuality: 0.9) else { return }
                let artwork = makeNowPlayingArtwork(imageData: imageData, imageSize: image.size)
                self.nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = self.nowPlayingInfo
            } catch {
                return
            }
        }
    }

    func configureRemoteCommands() {
        removeRemoteCommandTargets()

        let commandCenter = MPRemoteCommandCenter.shared()

        addTarget(to: commandCenter.playCommand) { [weak self] in
            self?.engine?.play()
            self?.publishEngineSnapshot(force: true)
        }

        addTarget(to: commandCenter.pauseCommand) { [weak self] in
            self?.engine?.pause()
            self?.publishEngineSnapshot(force: true)
        }

        addTarget(to: commandCenter.togglePlayPauseCommand) { [weak self] in
            guard let self, let engine else { return }
            if engine.state == .playing {
                engine.pause()
            } else {
                engine.play()
            }
            publishEngineSnapshot(force: true)
        }

        commandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackwardInterval)]
        addTarget(to: commandCenter.skipBackwardCommand) { [weak self] in
            self?.seek(by: -(self?.skipBackwardInterval ?? 10))
        }

        commandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForwardInterval)]
        addTarget(to: commandCenter.skipForwardCommand) { [weak self] in
            self?.seek(by: self?.skipForwardInterval ?? 10)
        }

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        let changePositionTarget = commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let positionTime = event.positionTime
            Task { @MainActor [weak self] in
                self?.seek(to: positionTime)
            }
            return .success
        }
        commandTargets.append((commandCenter.changePlaybackPositionCommand, changePositionTarget))
    }

    func addTarget(
        to command: MPRemoteCommand,
        handler: @escaping @MainActor () -> Void
    ) {
        command.isEnabled = true
        let target = command.addTarget { _ in
            Task { @MainActor in
                handler()
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

        let upperBound = engine.duration > 0 ? engine.duration : .greatestFiniteMagnitude
        let target = min(max(engine.currentTime + offset, 0), upperBound)
        seek(to: target)
    }

    func seek(to position: TimeInterval) {
        guard let engine else { return }

        engine.seek(to: position)
        publishPlaybackState(
            state: engine.state,
            currentTime: position,
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
            wasPlayingBeforeInterruption = engine?.state == .playing
            engine?.pause()
            publishEngineSnapshot(force: true)
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
            configureAndActivateAudioSession()

            if wasPlayingBeforeInterruption, options.contains(.shouldResume) {
                engine?.play()
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
            engine?.pause()
            publishEngineSnapshot(force: true)
        }
    }
}

private nonisolated func makeNowPlayingArtwork(
    imageData: Data,
    imageSize: CGSize
) -> MPMediaItemArtwork {
    MPMediaItemArtwork(boundsSize: imageSize) { _ in
        UIImage(data: imageData) ?? UIImage()
    }
}
#endif
