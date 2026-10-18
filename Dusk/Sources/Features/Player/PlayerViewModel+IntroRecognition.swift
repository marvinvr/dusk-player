import Foundation
import OSLog

private enum IntroRecognitionConfiguration {
    static let minimumForwardSeekJump: TimeInterval = 2
    static let maximumContinuousPlaybackRate = 4.0
    static let forwardSeekClockSlack: TimeInterval = 0.5
    static let maximumBackwardClockStep: TimeInterval = 0.75
    static let minimumFrameRequestInterval: TimeInterval = 0.1
    static let checkpointFrameInterval = 20
}

extension PlayerViewModel {
    var isIntroFingerprintCacheCurrent: Bool {
        guard let key = introFingerprintSeasonKey else { return false }
        return introOpeningSessionState.fingerprintCacheGeneration == introFingerprintStore.generation(for: key)
    }

    func updateIntroRecognition(for marker: PlexMarker) {
        guard isIntroFingerprintCacheCurrent, let seasonKey = introFingerprintSeasonKey,
              let episode = currentEpisodeRatingKey else { return }
        let now = engine.currentTime
        guard now.isFinite else { return }
        if let previousMarkerID = introFrameSamplingMarkerID, previousMarkerID != marker.id {
            finishIntroObservation(reason: "marker-changed", resolve: true)
        }
        if let existing = introOpeningSessionState.observations[marker.id],
           existing.mediaPartID != sourcePart?.id {
            checkpointIntroObservation(markerID: marker.id, force: true)
            finishIntroObservation(reason: "media-part-changed", resolve: true, discardSegment: true)
            // A rebuilt view model has not installed its sampler yet, so the
            // detach helper may have no active marker to remove.
            noteIntroFingerprintResolved(for: marker)
            introOpeningSessionState.observations[marker.id] = nil
        }
        if introOpeningSessionState.observations[marker.id] == nil {
            guard engine.isReadyForIntroFrameSampling else { return }
            let observation = IntroOpeningObservation(
                playbackSessionID: introOpeningSessionState.id,
                episodeRatingKey: episode, mediaPartID: sourcePart?.id,
                markerID: marker.id, markerStart: Double(marker.startTimeOffset) / 1_000,
                markerEnd: Double(marker.endTimeOffset) / 1_000, enteredAt: now,
                references: introFingerprintStore.fingerprints(for: seasonKey, excluding: introOpeningSessionState.id),
                allowRecognition: !resolvedIntroFingerprintMarkerIDs.contains(marker.id)
            )
            introOpeningSessionState.observations[marker.id] = observation
            autoSkipIntroLogger.notice("Observation started episode=\(episode, privacy: .public) marker=\(marker.id) observation=\(observation.id.uuidString, privacy: .public) references=\(observation.references.count) phase=\(observation.phase.rawValue, privacy: .public) mediaTime=\(now, format: .fixed(precision: 3))")
        }
        guard var observation = introOpeningSessionState.observations[marker.id] else { return }
        if engine.isReadyForIntroFrameSampling {
            // External transport controls can seek without calling this view
            // model. Distinguish discontinuities from ordinary 1x/2x progress.
            if let previous = lastIntroPlaybackTime, let wallTime = lastIntroPlaybackWallTime {
                let delta = now - previous
                let allowance = max(IntroRecognitionConfiguration.minimumForwardSeekJump,
                                    Date().timeIntervalSince(wallTime) * IntroRecognitionConfiguration.maximumContinuousPlaybackRate
                                        + IntroRecognitionConfiguration.forwardSeekClockSlack)
                if delta < -IntroRecognitionConfiguration.maximumBackwardClockStep || delta > allowance {
                    finishIntroObservation(reason: "transport-discontinuity", resolve: true, discardSegment: true)
                    return
                }
            }
            lastIntroPlaybackTime = now
            lastIntroPlaybackWallTime = Date()
            observation.advance(to: now)
            introOpeningSessionState.observations[marker.id] = observation
            presentIntroDecision(observation, marker: marker, at: now)
        }
        guard observation.canRecord else {
            finishIntroObservation(reason: "recording-complete", resolve: true)
            return
        }
        if introFrameSamplingMarkerID != marker.id {
            beginIntroSampling(for: marker)
        }
    }

    private func beginIntroSampling(for marker: PlexMarker) {
        // A new handler generation abandons any old asynchronous snapshot.
        engine.setIntroFrameSampleHandler(nil)
        introFrameSamplingGeneration = UUID()
        let generation = introFrameSamplingGeneration
        introFrameSamplingMarkerID = marker.id
        introFingerprintSampleRequestCount = 0
        lastIntroFrameRequestTime = nil
        engine.setIntroFrameSampleHandler { [weak self] sample in
            self?.acceptIntroSample(sample, marker: marker, generation: generation)
        }
        introFrameSamplingTask?.cancel()
        introFrameSamplingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // No strong reference to the view model spans the suspension.
                guard self?.requestIntroSample(markerID: marker.id, generation: generation) == true else { return }
                let interval = self?.introSamplingInterval(markerID: marker.id) ?? IntroOpeningObservation.learningSamplingInterval
                do { try await Task.sleep(for: .seconds(interval)) }
                catch { return }
            }
        }
        autoSkipIntroLogger.notice("Sampling installed marker=\(marker.id) interval=\(IntroOpeningObservation.denseSamplingInterval)s-then-\(IntroOpeningObservation.learningSamplingInterval)s maxWindow=\(IntroOpeningFingerprintMatcher.sampleWindow)s courtesyDelay=\(IntroOpeningObservation.courtesyDelay)s recognitionLimit=\(IntroOpeningObservation.recognitionLimit)s")
    }

    private func introSamplingInterval(markerID: Int) -> TimeInterval {
        introOpeningSessionState.observations[markerID]?.samplingInterval(at: engine.currentTime)
            ?? IntroOpeningObservation.learningSamplingInterval
    }

    private func requestIntroSample(markerID: Int, generation: UUID) -> Bool {
        guard introFrameSamplingGeneration == generation,
              introFrameSamplingMarkerID == markerID,
              shouldClassifyIntroFingerprint,
              isIntroFingerprintCacheCurrent,
              userPreferences?.autoSkipIntroMode == .alwaysExceptFirstEpisode,
              activeSkipMarker?.id == markerID,
              !introOpeningSessionState.hasSkippedIntro,
              !spentAutoSkipMarkerIDs.contains(markerID), !isScrubbing,
              introOpeningSessionState.observations[markerID]?.canRecord == true else { return false }
        guard engine.isReadyForIntroFrameSampling else { return true }
        let time = engine.currentTime
        guard time.isFinite,
              lastIntroFrameRequestTime.map({ time > $0 + IntroRecognitionConfiguration.minimumFrameRequestInterval }) ?? true else { return true }
        lastIntroFrameRequestTime = time
        introFingerprintSampleRequestCount += 1
        autoSkipIntroLogger.notice("Frame requested marker=\(markerID) request=\(self.introFingerprintSampleRequestCount) time=\(time, format: .fixed(precision: 3))")
        engine.requestIntroFrameSample()
        return true
    }

    private func acceptIntroSample(_ sample: IntroFrameSample, marker: PlexMarker, generation: UUID) {
        guard generation == introFrameSamplingGeneration,
              introFrameSamplingMarkerID == marker.id,
              activeSkipMarker?.id == marker.id,
              shouldClassifyIntroFingerprint,
              isIntroFingerprintCacheCurrent,
              !introOpeningSessionState.hasSkippedIntro,
              userPreferences?.autoSkipIntroMode == .alwaysExceptFirstEpisode,
              engine.isReadyForIntroFrameSampling, !isScrubbing,
              var observation = introOpeningSessionState.observations[marker.id] else { return }
        guard observation.record(sample) else {
            autoSkipIntroLogger.notice("Frame rejected marker=\(marker.id) reason=timing-duplicate-quality-or-limit time=\(sample.mediaTime, format: .fixed(precision: 3)) uncertainty=\(sample.timingUncertainty, format: .fixed(precision: 3))")
            return
        }
        observation.advance(to: engine.currentTime)
        introOpeningSessionState.observations[marker.id] = observation
        autoSkipIntroLogger.notice("Frame accepted marker=\(marker.id) count=\(observation.points.count) time=\(sample.mediaTime, format: .fixed(precision: 3)) quality=\(sample.signature.quality, format: .fixed(precision: 2)) uncertainty=\(sample.timingUncertainty, format: .fixed(precision: 3))")
        checkpointIntroObservation(markerID: marker.id, force: false)
        presentIntroDecision(observation, marker: marker, at: engine.currentTime)
        scheduleIntroComparison(for: marker, generation: generation)
    }

    private func scheduleIntroComparison(for marker: PlexMarker, generation: UUID) {
        guard isIntroFingerprintCacheCurrent, !introOpeningSessionState.hasSkippedIntro,
              introFingerprintMatchingTask == nil,
              let observation = introOpeningSessionState.observations[marker.id],
              let candidate = observation.candidate(at: engine.currentTime) else { return }
        let observationID = observation.id
        let pointCount = observation.points.count
        let relativeTime = observation.comparisonTime(at: engine.currentTime)
        let references = observation.references
        introFingerprintMatchingTask = Task { @MainActor [weak self] in
            let result = await IntroFingerprintMatchingWorker.shared.recognize(candidate, among: references, at: relativeTime)
            guard !Task.isCancelled, let self,
                  self.introFrameSamplingGeneration == generation,
                  self.introOpeningSessionState.observations[marker.id]?.id == observationID else { return }
            self.introFingerprintMatchingTask = nil
            guard self.activeSkipMarker?.id == marker.id,
                  self.engine.isReadyForIntroFrameSampling,
                  self.shouldClassifyIntroFingerprint,
                  self.isIntroFingerprintCacheCurrent,
                  self.userPreferences?.autoSkipIntroMode == .alwaysExceptFirstEpisode,
                  !self.introOpeningSessionState.hasSkippedIntro,
                  !self.isScrubbing, !self.spentAutoSkipMarkerIDs.contains(marker.id),
                  var current = self.introOpeningSessionState.observations[marker.id] else { return }
            // Never confirm from a matrix superseded by a newer capture. The
            // next job evaluates the complete current window instead.
            guard current.points.count == pointCount else {
                self.scheduleIntroComparison(for: marker, generation: generation)
                return
            }
            let now = self.engine.currentTime
            current.advance(to: now)
            let shouldSkip = current.apply(result, at: now)
            self.introOpeningSessionState.observations[marker.id] = current
            autoSkipIntroLogger.notice("Alignment marker=\(marker.id) episode=\(current.episodeRatingKey, privacy: .public) phase=\(current.phase.rawValue, privacy: .public) \(result.summary, privacy: .public)")
            self.presentIntroDecision(current, marker: marker, at: now)
            if shouldSkip {
                // These are live engine/preferences reads on the main actor,
                // immediately before the existing one-shot skip action.
                self.noteIntroFingerprintResolved(for: marker)
                self.finishIntroObservation(reason: "confirmed-repeat", resolve: true)
                self.performAutomaticIntroSkip(for: marker)
            }
        }
    }

    private func presentIntroDecision(_ observation: IntroOpeningObservation, marker: PlexMarker, at time: TimeInterval) {
        let progress = observation.progress(at: time)
        autoSkipCountdownMarkerID = progress == nil ? nil : marker.id
        autoSkipCountdownProgress = progress
        if observation.phase == .playThrough || observation.phase == .skipped {
            noteIntroFingerprintResolved(for: marker)
        }
    }

    private func checkpointIntroObservation(markerID: Int, force: Bool) {
        guard isIntroFingerprintCacheCurrent, let key = introFingerprintSeasonKey,
              var observation = introOpeningSessionState.observations[markerID],
              observation.points.count > observation.persistedPointCount,
              force || observation.persistedPointCount == 0
                || observation.points.count - observation.persistedPointCount >= IntroRecognitionConfiguration.checkpointFrameInterval else { return }
        if introFingerprintStore.insert(observation.fingerprint, for: key, generation: introOpeningSessionState.fingerprintCacheGeneration) {
            observation.persistedPointCount = observation.points.count
            introOpeningSessionState.observations[markerID] = observation
        }
    }

    func finishIntroObservation(reason: String, resolve: Bool, discardSegment: Bool = false) {
        guard let markerID = introFrameSamplingMarkerID else { return }
        checkpointIntroObservation(markerID: markerID, force: true)
        if var observation = introOpeningSessionState.observations[markerID] {
            // A departing presentation must preserve an in-flight recognition
            // decision for its successor. Explicit interruptions are terminal.
            if resolve && reason != "cancelled" && reason != "configuration-changed" {
                observation.allowPlayThrough()
                introOpeningSessionState.observations[markerID] = observation
                resolvedIntroFingerprintMarkerIDs.insert(markerID)
                introFingerprintResolvedHandler?(markerID)
            }
            autoSkipIntroLogger.notice("Observation detached marker=\(markerID) reason=\(reason, privacy: .public) phase=\(observation.phase.rawValue, privacy: .public) samples=\(observation.points.count) requests=\(self.introFingerprintSampleRequestCount)")
        }
        if discardSegment { introOpeningSessionState.observations[markerID] = nil }
        introFrameSamplingGeneration = UUID()
        introFrameSamplingTask?.cancel()
        introFrameSamplingTask = nil
        introFingerprintMatchingTask?.cancel()
        introFingerprintMatchingTask = nil
        introFrameSamplingMarkerID = nil
        lastIntroFrameRequestTime = nil
        lastIntroPlaybackTime = nil
        lastIntroPlaybackWallTime = nil
        engine.setIntroFrameSampleHandler(nil)
        autoSkipCountdownMarkerID = nil
        autoSkipCountdownProgress = nil
    }
}
