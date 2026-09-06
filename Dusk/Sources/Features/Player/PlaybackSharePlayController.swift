import AVFoundation
import Combine
import Foundation
import GroupActivities
import Observation
import OSLog
import UIKit

private let sharePlayLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "SharePlay"
)

enum SharePlayPlaybackPreparation {
    case ready
    case waitingForAccount(String)
    case failed(String)
    case cancelled
}

/// Owns Group Activities lifecycle and connects the active Dusk playback engine
/// to Apple's coordinated-playback transport.
@MainActor @Observable
final class PlaybackSharePlayController {
    private(set) var isActive = false
    private var isActivating = false
    private var isJoining = false
    private(set) var participantCount = 0
    var errorMessage: String?
    #if os(iOS)
    var invitation: SharePlayInvitation?
    #endif

    @ObservationIgnored weak var playbackCoordinator: PlaybackCoordinator?
    @ObservationIgnored private let groupStateObserver = GroupStateObserver()
    @ObservationIgnored private var groupSession: GroupSession<DuskWatchTogetherActivity>?
    @ObservationIgnored private var sessionListenerTask: Task<Void, Never>?
    @ObservationIgnored private var activityTask: Task<Void, Never>?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var participantsTask: Task<Void, Never>?
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var pendingActivity: DuskWatchTogetherActivity?
    @ObservationIgnored private weak var connectedEngine: (any PlaybackEngine)?
    @ObservationIgnored private var connectedItemIdentifier: String?

    var isStarting: Bool {
        #if os(iOS)
        if invitation != nil { return true }
        #endif
        return isActivating || isJoining
    }

    var isSessionAvailable: Bool {
        groupSession != nil
    }

    func startListening() {
        guard sessionListenerTask == nil else { return }

        sessionListenerTask = Task { @MainActor [weak self] in
            for await session in DuskWatchTogetherActivity.sessions() {
                guard !Task.isCancelled else { return }
                self?.receive(session)
            }
        }
    }

    func toggleForCurrentPlayback() async {
        if groupSession != nil {
            leave()
            return
        }

        guard !isStarting else { return }
        guard let activity = playbackCoordinator?.currentSharePlayActivity else {
            presentError("SharePlay is unavailable for this playback.")
            return
        }

        errorMessage = nil
        isActivating = true
        defer { isActivating = false }

        do {
            // activate() requires an eligible conversation. Outside a call,
            // iPhone/iPad must present Apple's participant/invitation picker.
            guard groupStateObserver.isEligibleForGroupSession else {
                #if os(iOS)
                invitation = SharePlayInvitation(
                    controller: try GroupActivitySharingController(activity)
                )
                #else
                presentError("Start or join a FaceTime call on your Apple TV, or start SharePlay in Dusk on your iPhone or iPad and continue on Apple TV.")
                #endif
                return
            }

            let activated = try await activity.activate()
            if !activated, groupSession == nil {
                // false also covers handing the activity off to Apple TV;
                // it does not necessarily mean activation failed everywhere.
                presentError("No SharePlay session started on this device. If you moved SharePlay to Apple TV, continue there; otherwise, try again.")
            }
        } catch {
            sharePlayLogger.error(
                "SharePlay activation failed: \(error.localizedDescription, privacy: .public)"
            )
            presentError("Couldn’t start SharePlay: \(error.localizedDescription)")
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

        // Loading an incoming item must not publish its local metadata back
        // into the group, especially if a newer activity arrived during load.
        if preparationTask != nil {
            guard session.activity.playbackItemIdentifier == activity.playbackItemIdentifier else { return }
        } else if session.activity != activity {
            session.activity = activity
        }
        connect(engine: engine, activity: activity, session: session)
    }

    func retryPendingActivityIfPossible() async {
        guard pendingActivity != nil else { return }
        schedulePreparation()
        await preparationTask?.value
    }

    func leave() {
        #if os(iOS)
        invitation = nil
        #endif
        groupSession?.leave()
        tearDownSession(leaveCurrentSession: false)
    }

    func dismissError() {
        errorMessage = nil
    }

    private func receive(_ session: GroupSession<DuskWatchTogetherActivity>) {
        guard groupSession?.id != session.id else { return }
        if let current = groupSession, current.id != session.id {
            current.leave()
        }
        tearDownSession(leaveCurrentSession: false)

        groupSession = session
        pendingActivity = session.activity
        participantCount = session.activeParticipants.count
        isActive = session.state == .joined
        isJoining = session.state == .waiting

        activityTask = Task { @MainActor [weak self, weak session] in
            guard let session else { return }
            for await activity in session.$activity.values {
                guard !Task.isCancelled else { return }
                guard self?.groupSession?.id == session.id else { return }
                self?.pendingActivity = activity
                self?.schedulePreparation()
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
                    self?.isJoining = true
                case .joined:
                    self?.isActive = true
                    self?.isJoining = false
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

        schedulePreparation()
    }

    private func schedulePreparation() {
        guard preparationTask == nil, pendingActivity != nil,
              let sessionID = groupSession?.id else { return }
        preparationTask = Task { @MainActor [weak self] in
            await self?.preparePendingActivity()
            // An invalidated/replaced session may already own a new worker.
            if self?.groupSession?.id == sessionID {
                self?.preparationTask = nil
            }
        }
    }

    private func preparePendingActivity() async {
        // Activity changes can arrive while Plex is still resolving the prior
        // item. Drain the latest pending value before returning so a fast Up
        // Next transition is never consumed by the publisher and then stranded.
        while !Task.isCancelled,
              let session = groupSession,
              let activity = pendingActivity,
              let playbackCoordinator {
            let result = await playbackCoordinator.prepareForSharePlay(activity)
            guard !Task.isCancelled, groupSession?.id == session.id else { return }
            guard pendingActivity == activity else { continue }
            switch result {
            case .ready:
                pendingActivity = nil
                if let engine = playbackCoordinator.engine {
                    connect(engine: engine, activity: activity, session: session)
                }
                if session.state == .waiting {
                    session.join()
                }
                errorMessage = nil

            case let .waitingForAccount(message):
                isJoining = false
                session.requestForegroundPresentation()
                presentError(message)
                return

            case let .failed(message):
                session.requestForegroundPresentation()
                presentError(message)
                session.leave()
                tearDownSession(leaveCurrentSession: false)
                return

            case .cancelled:
                return
            }
        }
    }

    private func connect(
        engine: any PlaybackEngine,
        activity: DuskWatchTogetherActivity,
        session: GroupSession<DuskWatchTogetherActivity>
    ) {
        // Initial activity publication and playback preparation can both reach
        // here. Reattaching VLCKit resets its scheduled transport commands.
        guard connectedEngine !== engine ||
                connectedItemIdentifier != activity.playbackItemIdentifier else { return }
        if connectedEngine !== engine {
            connectedEngine?.configureCoordinatedPlayback(itemIdentifier: nil)
        }
        engine.configureCoordinatedPlayback(itemIdentifier: activity.playbackItemIdentifier)
        engine.playbackCoordinator.coordinateWithSession(session)
        connectedEngine = engine
        connectedItemIdentifier = activity.playbackItemIdentifier
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
        preparationTask?.cancel()
        preparationTask = nil
        connectedEngine?.configureCoordinatedPlayback(itemIdentifier: nil)
        connectedEngine = nil
        connectedItemIdentifier = nil
        groupSession = nil
        pendingActivity = nil
        isActive = false
        isJoining = false
        isActivating = false
        // Receiving a session can precede the invitation controller's own
        // dismissal. Let that controller finish instead of dismissing it twice.
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
        preparationTask?.cancel()
    }
}
