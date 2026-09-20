#if os(tvOS)
import SwiftUI

/// The play bar itself: capsule track, live-reachable shading, marker ticks,
/// the playhead, and the elapsed / remaining readouts inline beneath it.
///
/// Nothing in here is focusable. The playhead's position comes from
/// `PlayerTVHUDController.previewPosition` while a seek or a scrub is being
/// previewed, and from the engine otherwise, so a held left/right click and a
/// swipe both animate the same bar without touching the engine.
struct PlayerTVTransportBar: View {
    let viewModel: PlayerViewModel
    let controller: PlayerTVHUDController
    let scrubPreviewSource: PlexScrubPreviewSource?
    let reduceMotion: Bool

    private var isScrubbing: Bool {
        controller.mode == .scrubbing
    }

    private var position: TimeInterval {
        controller.previewPosition ?? viewModel.currentTime
    }

    var body: some View {
        VStack(spacing: PlayerTVHUDLayout.barLabelSpacing) {
            GeometryReader { geometry in
                bar(width: geometry.size.width)
            }
            .frame(height: PlayerTVHUDLayout.barRowHeight)

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                leadingLabel
                Spacer(minLength: 24)
                trailingLabel
            }
        }
    }

    // MARK: - Bar

    private func bar(width: CGFloat) -> some View {
        let centerY = PlayerTVHUDLayout.barRowHeight / 2
        let progress = min(max(viewModel.timelineProgress(for: position), 0), 1)
        let headX = min(max(width * progress, 0), width)

        return ZStack(alignment: .topLeading) {
            track(width: width, progress: progress)
                .frame(width: width, height: PlayerTVHUDLayout.barHeight)
                .position(x: width / 2, y: centerY)

            if isScrubbing {
                Capsule()
                    .fill(.white.opacity(0.7))
                    .frame(
                        width: PlayerTVHUDLayout.scrubStemWidth,
                        height: PlayerTVHUDLayout.scrubStemHeight
                    )
                    .position(x: headX, y: centerY)
                    .transition(.opacity)
            }

            head
                .position(x: headX, y: centerY)

            scrubTooltip(headX: headX, width: width)
        }
        .frame(width: width, height: PlayerTVHUDLayout.barRowHeight)
        .animation(
            PlayerTVHUDLayout.animation(PlayerTVHUDLayout.headGrowAnimation, reduceMotion: reduceMotion),
            value: isScrubbing
        )
    }

    private func track(width: CGFloat, progress: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(0.16))
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1)
                }

            // Live: the stretch of the program the tuned session still holds,
            // ending at the live edge. Everything outside it is either already
            // out of the DVR window or has not aired yet.
            if let reachable = viewModel.liveReachableTrackRange, width > 0 {
                let reachableWidth = width * (reachable.upperBound - reachable.lowerBound)
                if reachableWidth >= PlayerTVHUDLayout.barHeight {
                    Capsule()
                        .fill(.white.opacity(0.24))
                        .frame(width: reachableWidth)
                        .offset(x: width * reachable.lowerBound)
                }
            }

            if progress > 0 {
                Capsule()
                    .fill(.white.opacity(0.96))
                    .frame(width: min(max(PlayerTVHUDLayout.barHeight, width * progress), width))
                    .shadow(color: .white.opacity(0.18), radius: 5)
            }

            markerTicks(width: width)
        }
        .frame(height: PlayerTVHUDLayout.barHeight)
    }

    /// Intro / credits ticks. Plex ships no real chapter list, so these are the
    /// only structural landmarks the bar can show (and the same set the
    /// Chapters tab lists).
    @ViewBuilder
    private func markerTicks(width: CGFloat) -> some View {
        if width > 0 {
            ForEach(viewModel.chapterMarkers) { marker in
                let markerProgress = viewModel.timelineProgress(
                    for: TimeInterval(marker.startTimeOffset) / 1000
                )
                if markerProgress > 0.001, markerProgress < 0.999 {
                    Capsule()
                        .fill(.black.opacity(0.55))
                        .frame(width: PlayerTVHUDLayout.markerTickWidth)
                        .offset(x: width * markerProgress - PlayerTVHUDLayout.markerTickWidth / 2)
                }
            }
        }
    }

    private var head: some View {
        let diameter = isScrubbing
            ? PlayerTVHUDLayout.scrubbingHeadDiameter
            : PlayerTVHUDLayout.headDiameter

        return Circle()
            .fill(.white)
            .frame(width: diameter, height: diameter)
            .shadow(color: .white.opacity(isScrubbing ? 0.4 : 0.2), radius: isScrubbing ? 14 : 7)
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }

    // MARK: - Scrub tooltip

    @ViewBuilder
    private func scrubTooltip(headX: CGFloat, width: CGFloat) -> some View {
        if isScrubbing {
            if let scrubPreviewSource, scrubPreviewSource.isAvailable {
                PlayerScrubPreviewPopup(source: scrubPreviewSource, position: position)
                    .position(
                        x: clampedPopupX(headX, totalWidth: width),
                        y: PlayerScrubPreviewPopup.verticalPosition
                    )
                    .transition(.scale(scale: 0.96, anchor: .bottom).combined(with: .opacity))
            } else if let clockLabel = viewModel.liveClockLabel(for: position) {
                // Live has no thumbnails; the useful answer while dragging is
                // what time of the broadcast the cursor is on.
                PlayerLiveClockBubble(label: clockLabel)
                    .position(x: min(max(headX, 60), max(width - 60, 60)), y: -12)
                    .transition(.scale(scale: 0.96, anchor: .bottom).combined(with: .opacity))
            } else {
                Text(PlayerTVTimeFormatter.string(position))
                    .font(DuskFont.TV.badge.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background {
                        Capsule()
                            .fill(.white.opacity(0.08))
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .overlay { Capsule().strokeBorder(.white.opacity(0.24), lineWidth: 1) }
                    .position(x: min(max(headX, 70), max(width - 70, 70)), y: -14)
                    .transition(.scale(scale: 0.96, anchor: .bottom).combined(with: .opacity))
            }
        }
    }

    private func clampedPopupX(_ proposedX: CGFloat, totalWidth: CGFloat) -> CGFloat {
        let halfWidth = PlayerScrubPreviewPopup.width / 2
        guard totalWidth > halfWidth * 2 else {
            return max(totalWidth / 2, halfWidth)
        }
        return min(max(proposedX, halfWidth), totalWidth - halfWidth)
    }

    // MARK: - Readouts

    @ViewBuilder
    private var leadingLabel: some View {
        if viewModel.isLiveTV {
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.isAtLiveEdge ? Color.red : Color.white.opacity(0.5))
                    .frame(width: 9, height: 9)

                Text(viewModel.formattedLiveOffset)
                    .font(DuskFont.TV.metadata.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
            }
        } else {
            Text(PlayerTVTimeFormatter.string(position))
                .font(DuskFont.TV.metadata.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    @ViewBuilder
    private var trailingLabel: some View {
        if viewModel.isLiveTV {
            if let programWindow = viewModel.liveProgramWindowLabel {
                Text(programWindow)
                    .font(DuskFont.TV.metadata.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
        } else if viewModel.duration > 0 {
            Text("−" + PlayerTVTimeFormatter.string(max(0, viewModel.duration - position)))
                .font(DuskFont.TV.metadata.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}

enum PlayerTVTimeFormatter {
    static func string(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
#endif
