import SwiftUI

/// Full-screen video player with controls overlay, track pickers, and auto-hide.
///
/// Present via `.fullScreenCover`. Playback starts on first appearance so the
/// underlying render surface is attached before the engine begins loading.
struct PlayerView: View {
    @Environment(UserPreferences.self) private var preferences
    @State private var viewModel: PlayerViewModel
    @Environment(\.dismiss) private var dismiss
    private let playbackSource: PlaybackSource
    private let debugInfo: PlaybackDebugInfo?

    init(
        engine: any PlaybackEngine,
        playbackSource: PlaybackSource,
        debugInfo: PlaybackDebugInfo? = nil
    ) {
        _viewModel = State(initialValue: PlayerViewModel(engine: engine))
        self.playbackSource = playbackSource
        self.debugInfo = debugInfo
    }

    var body: some View {
        @Bindable var vm = viewModel

        ZStack {
            // Black letterbox behind video
            Color.black.ignoresSafeArea()

            // Video surface
            viewModel.engineView
                .ignoresSafeArea()

            // Invisible tap target to toggle controls
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { viewModel.toggleControls() }

            // Buffering spinner
            if viewModel.shouldShowBufferingIndicator {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(.white)
            }

            // Error overlay
            if let error = viewModel.playbackError {
                errorOverlay(error)
            }

            if preferences.playerDebugOverlayEnabled,
               let debugInfo,
               viewModel.playbackError == nil {
                debugOverlay(debugInfo)
            }

            // Controls overlay
            if viewModel.showControls, viewModel.playbackError == nil {
                controlsOverlay
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.showControls)
        .duskStatusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            // Start playback only after the full-screen player view exists.
            viewModel.startPlaybackIfNeeded(source: playbackSource)
        }
        .onDisappear { viewModel.cleanup() }
        .sheet(isPresented: $vm.showSubtitlePicker) { subtitlePicker }
        .sheet(isPresented: $vm.showAudioPicker) { audioPicker }
    }

    // MARK: - Controls Overlay

    private var controlsOverlay: some View {
        ZStack {
            // Gradient scrim (extends behind safe area)
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.black.opacity(0.7), .clear],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 120)

                Spacer()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.7)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 160)
            }
            .ignoresSafeArea()

            // Actual controls (respect safe area)
            VStack {
                topBar
                Spacer()
                centerControls
                Spacer()
                bottomBar
            }
            .padding()
        }
    }

    // MARK: - Debug Overlay

    private func debugOverlay(_ debugInfo: PlaybackDebugInfo) -> some View {
        GeometryReader { geometry in
            VStack {
                HStack {
                    Spacer()
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(minimum: 110), spacing: 12, alignment: .top),
                            GridItem(.flexible(minimum: 110), spacing: 12, alignment: .top),
                        ],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(debugEntries(for: debugInfo)) { entry in
                            debugRow(entry.label, entry.value)
                        }
                    }
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    }
                    .frame(width: 288, alignment: .leading)
                }
                Spacer()
            }
            .padding(.top, max(16, geometry.safeAreaInsets.top + 8))
            .padding(.horizontal, 16)
        }
        .allowsHitTesting(false)
    }

    private func debugEntries(for debugInfo: PlaybackDebugInfo) -> [DebugOverlayEntry] {
        [
            DebugOverlayEntry(label: "Engine", value: debugInfo.engineLabel),
            DebugOverlayEntry(label: "Mode", value: debugInfo.decisionLabel),
            DebugOverlayEntry(label: "Transcode", value: debugInfo.transcodeLabel),
            DebugOverlayEntry(label: "Container", value: debugInfo.containerLabel),
            DebugOverlayEntry(label: "Bitrate", value: debugInfo.bitrateLabel),
            DebugOverlayEntry(label: "Video", value: debugInfo.videoLabel),
            DebugOverlayEntry(label: "Audio", value: debugInfo.audioLabel),
            DebugOverlayEntry(label: "Resolution", value: debugInfo.resolutionLabel),
            DebugOverlayEntry(label: "File", value: debugInfo.fileSizeLabel),
            DebugOverlayEntry(label: "Subtitles", value: debugInfo.subtitleLabel),
            DebugOverlayEntry(label: "State", value: debugStateLabel),
        ]
    }

    private func debugRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.65))
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.white)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var debugStateLabel: String {
        let stateText: String
        switch viewModel.state {
        case .idle: stateText = "Idle"
        case .loading: stateText = "Loading"
        case .playing: stateText = "Playing"
        case .paused: stateText = "Paused"
        case .stopped: stateText = "Stopped"
        case .error: stateText = "Error"
        }

        if viewModel.isBuffering {
            return "\(stateText) / Buffering"
        }
        return stateText
    }

    private struct DebugOverlayEntry: Identifiable {
        let label: String
        let value: String

        var id: String { label }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button {
                viewModel.cleanup()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
        }
    }

    // MARK: - Center Controls

    private var centerControls: some View {
        HStack(spacing: 48) {
            Button { viewModel.skipBackward() } label: {
                Image(systemName: "gobackward.15")
                    .font(.title)
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
            }

            Button { viewModel.togglePlayPause() } label: {
                Image(systemName: viewModel.state == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Button { viewModel.skipForward() } label: {
                Image(systemName: "goforward.15")
                    .font(.title)
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        VStack(spacing: 8) {
            seekBar

            HStack {
                Text(viewModel.formattedTime)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))

                Text("/")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))

                Text(viewModel.formattedDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))

                Spacer()

                if !viewModel.subtitleTracks.isEmpty {
                    Button { viewModel.showSubtitlePicker = true } label: {
                        Image(systemName: "captions.bubble")
                            .font(.body)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                    }
                }

                if !viewModel.audioTracks.isEmpty {
                    Button { viewModel.showAudioPicker = true } label: {
                        Image(systemName: "speaker.wave.2")
                            .font(.body)
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                    }
                }
            }
        }
    }

    // MARK: - Seek Bar

    private var seekBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = viewModel.duration > 0
                ? viewModel.displayPosition / viewModel.duration
                : 0
            let seekTrack = ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white.opacity(0.3))
                    .frame(height: 4)

                // Filled track
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.duskAccent)
                    .frame(width: max(0, width * progress), height: 4)

                // Thumb
                Circle()
                    .fill(Color.duskAccent)
                    .frame(
                        width: viewModel.isScrubbing ? 16 : 12,
                        height: viewModel.isScrubbing ? 16 : 12
                    )
                    .offset(x: thumbOffset(progress: progress, trackWidth: width))
                    .animation(.easeOut(duration: 0.15), value: viewModel.isScrubbing)
            }
            .frame(height: 32) // tall hit area
            .contentShape(Rectangle())

            #if os(tvOS)
            seekTrack
            #else
            seekTrack.gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !viewModel.isScrubbing {
                            viewModel.beginScrub()
                        }
                        let fraction = max(0, min(1, value.location.x / width))
                        viewModel.updateScrub(to: fraction * viewModel.duration)
                    }
                    .onEnded { _ in
                        viewModel.endScrub()
                    }
            )
            #endif
        }
        .frame(height: 32)
    }

    private func thumbOffset(progress: Double, trackWidth: Double) -> Double {
        let thumbRadius: Double = viewModel.isScrubbing ? 8 : 6
        return max(0, min(trackWidth * progress - thumbRadius, trackWidth - thumbRadius * 2))
    }

    // MARK: - Error Overlay

    private func errorOverlay(_ error: PlaybackError) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(Color.duskAccent)

            Text(error.localizedDescription)
                .font(.headline)
                .foregroundStyle(Color.duskTextPrimary)
                .multilineTextAlignment(.center)

            Button("Close") {
                viewModel.cleanup()
                dismiss()
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 12)
            .background(Color.duskAccent, in: Capsule())
            .duskSuppressTVOSButtonChrome()
        }
        .padding(32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
    }

    // MARK: - Subtitle Picker

    private var subtitlePicker: some View {
        NavigationStack {
            List {
                Button {
                    viewModel.selectSubtitle(nil)
                } label: {
                    Text("Off")
                        .foregroundStyle(Color.duskTextPrimary)
                }
                .listRowBackground(Color.duskSurface)
                .duskSuppressTVOSButtonChrome()

                ForEach(viewModel.subtitleTracks) { track in
                    Button {
                        viewModel.selectSubtitle(track)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.displayTitle)
                                .foregroundStyle(Color.duskTextPrimary)
                            if let lang = track.language {
                                Text(lang)
                                    .font(.caption)
                                    .foregroundStyle(Color.duskTextSecondary)
                            }
                        }
                    }
                    .listRowBackground(Color.duskSurface)
                    .duskSuppressTVOSButtonChrome()
                }
            }
            .duskScrollContentBackgroundHidden()
            .background(Color.duskBackground)
            .duskNavigationTitle("Subtitles")
            .duskNavigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { viewModel.showSubtitlePicker = false }
                        .duskSuppressTVOSButtonChrome()
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(Color.duskBackground)
    }

    // MARK: - Audio Picker

    private var audioPicker: some View {
        NavigationStack {
            List {
                ForEach(viewModel.audioTracks) { track in
                    Button {
                        viewModel.selectAudio(track)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.displayTitle)
                                .foregroundStyle(Color.duskTextPrimary)
                            if let lang = track.language {
                                Text(lang)
                                    .font(.caption)
                                    .foregroundStyle(Color.duskTextSecondary)
                            }
                        }
                    }
                    .listRowBackground(Color.duskSurface)
                    .duskSuppressTVOSButtonChrome()
                }
            }
            .duskScrollContentBackgroundHidden()
            .background(Color.duskBackground)
            .duskNavigationTitle("Audio")
            .duskNavigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { viewModel.showAudioPicker = false }
                        .duskSuppressTVOSButtonChrome()
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(Color.duskBackground)
    }
}
