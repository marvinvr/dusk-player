import AVFoundation
import Combine
import Foundation
import GroupActivities
import Observation
import OSLog

private let sharePlayLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "SharePlay"
)

enum SharePlayPlaybackPreparation {
    case ready
    case waitingForAccount(String)
    case failed(String)
}

/// Owns Group Activities lifecycle and connects the active Dusk playback engine
/// to Apple's coordinated-playback transport.
@MainActor @Observable
final class PlaybackSharePlayController {
    private(set) var isActive = false
    private(set) var isStarting = false
    private(set) var participantCount = 0
    var errorMessage: String?

    @ObservationIgnored weak var playbackCoordinator: PlaybackCoordinator?
    @ObservationIgnored private var groupSession: GroupSession<DuskWatchTogetherActivity>?
    @ObservationIgnored private var sessionListenerTask: Task<Void, Never>?
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var participantsTask: Task<Void, Never>?
    @ObservationIgnored private var pendingActivity: DuskWatchTogetherActivity?
    @ObservationIgnored private var isPreparingActivity = false

    var isSessionAvailable: Bool {
        groupSession != nil
    }

    func startListening() {
        guard sessionListenerTask == nil else { return }

        sessionListenerTask = Task { @MainActor [weak self] in
            for await session in DuskWatchTogetherActivity.sessions() {
                guard !Task.isCancelled else { return }
                await self?.receive(session)
            }
        }
    }

    func toggleForCurrentPlayback() async {
        if groupSession != nil {
            leave()
            return
        }

        guard !isStarting,
              let activity = playbackCoordinator?.currentSharePlayActivity else {
            presentError("SharePlay is unavailable for this playback.")
            return
        }

        isStarting = true
        defer { isStarting = false }

        // This is an explicit SharePlay-only control, not an ordinary Play
        // button whose local-vs-group intent needs prepareForActivation().
        do {
            _ = try await activity.activate()
        } catch {
            sharePlayLogger.error(
                "SharePlay activation failed: \(error.localizedDescription, privacy: .public)"
            )
            presentError("Couldn’t start SharePlay. Start or join a FaceTime call and try again.")
        }
    }

    /// Called whenever Dusk commits or replaces an engine. During an active
    /// session this also publishes local item transitions (including Up Next).
    func playbackItemDidChange(
        activity: DuskWatchTogetherActivity?,
        engine: (any PlaybackEngine)?
    ) {
        guard let session = groupSession,
              let activity,
              let engine else { return }

        if session.activity != activity {
            session.activity = activity
        }
        connect(engine: engine, activity: activity, session: session)
    }

    func retryPendingActivityIfPossible() async {
        guard pendingActivity != nil else { return }
        await preparePendingActivity()
    }

    func leave() {
        groupSession?.leave()
        tearDownSession(leaveCurrentSession: false)
    }

    func dismissError() {
        errorMessage = nil
    }

    private func receive(_ session: GroupSession<DuskWatchTogetherActivity>) async {
        if let current = groupSession, current.id != session.id {
            current.leave()
        }
        tearDownSession(leaveCurrentSession: false)

        groupSession = session
        pendingActivity = session.activity
        participantCount = session.activeParticipants.count
        isActive = session.state == .joined

        activityTask = Task { @MainActor [weak self, weak session] in
            guard let session else { return }
            for await activity in session.$activity.values {
                guard !Task.isCancelled else { return }
                guard self?.groupSession?.id == session.id else { return }
                self?.pendingActivity = activity
                await self?.preparePendingActivity()
            }
        }

        stateTask = Task { @MainActor [weak self, weak session] in
            guard let session else { return }
            for await state in session.$state.values {
                guard !Task.isCancelled else { return }
                guard self?.groupSession?.id == session.id else { return }
                switch state {
                case .waiting:
                    self?.isActive = false
                case .joined:
                    self?.isActive = true
                case let .invalidated(reason):
                    sharePlayLogger.notice(
                        "SharePlay session invalidated: \(reason.localizedDescription, privacy: .public)"
                    )
                    self?.tearDownSession(leaveCurrentSession: false)
                    return
                @unknown default:
                    self?.isActive = false
                }
            }
        }

        participantsTask = Task { @MainActor [weak self, weak session] in
            guard let session else { return }
            for await participants in session.$activeParticipants.values {
                guard !Task.isCancelled else { return }
                guard self?.groupSession?.id == session.id else { return }
                self?.participantCount = participants.count
            }
        }

        await preparePendingActivity()
    }

    private func preparePendingActivity() async {
        guard !isPreparingActivity,
              playbackCoordinator != nil else { return }

        isPreparingActivity = true
        defer { isPreparingActivity = false }

        // Activity changes can arrive while Plex is still resolving the prior
        // item. Drain the latest pending value before returning so a fast Up
        // Next transition is never consumed by the publisher and then stranded.
        while let session = groupSession,
              let activity = pendingActivity,
              let playbackCoordinator {
            switch await playbackCoordinator.prepareForSharePlay(activity) {
            case .ready:
                guard groupSession?.id == session.id else { return }
                if pendingActivity == activity {
                    pendingActivity = nil
                }
                if let engine = playbackCoordinator.engine {
                    connect(engine: engine, activity: activity, session: session)
                }
                if session.state == .waiting {
                    session.join()
                }
                errorMessage = nil

            case let .waitingForAccount(message):
                guard groupSession?.id == session.id else { return }
                session.requestForegroundPresentation()
                presentError(message)
                return

            case let .failed(message):
                guard groupSession?.id == session.id else { return }
                session.requestForegroundPresentation()
                presentError(message)
                session.leave()
                tearDownSession(leaveCurrentSession: false)
                return
            }
        }
    }

    private func connect(
        engine: any PlaybackEngine,
        activity: DuskWatchTogetherActivity,
        session: GroupSession<DuskWatchTogetherActivity>
    ) {
        engine.configureCoordinatedPlayback(itemIdentifier: activity.playbackItemIdentifier)
        engine.playbackCoordinator.coordinateWithSession(session)
    }

    private func tearDownSession(leaveCurrentSession: Bool) {
        if leaveCurrentSession {
            groupSession?.leave()
        }
        activityTask?.cancel()
        activityTask = nil
        stateTask?.cancel()
        stateTask = nil
        participantsTask?.cancel()
        participantsTask = nil
        playbackCoordinator?.engine?.configureCoordinatedPlayback(itemIdentifier: nil)
        groupSession = nil
        pendingActivity = nil
        isPreparingActivity = false
        isActive = false
        isStarting = false
        participantCount = 0
    }

    private func presentError(_ message: String) {
        errorMessage = message
    }

    deinit {
        sessionListenerTask?.cancel()
        activityTask?.cancel()
        stateTask?.cancel()
        participantsTask?.cancel()
    }
}
