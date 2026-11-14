#if os(macOS)
import AppKit
import SwiftUI

/// Reports the `NSWindow` the player is in, so full screen and the window's
/// full-screen notifications can be reached from SwiftUI.
struct MacPlayerWindowReader: NSViewRepresentable {
    let onWindowChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> MacPlayerWindowReaderView {
        let view = MacPlayerWindowReaderView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ nsView: MacPlayerWindowReaderView, context: Context) {
        nsView.onWindowChange = onWindowChange
    }
}

final class MacPlayerWindowReaderView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let window = window
        // Reported after the current layout pass: the callback writes state.
        DispatchQueue.main.async { [weak self] in
            self?.onWindowChange?(window)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Skip Intro / Skip Credits, with the auto-skip countdown filling the chip
/// from the leading edge (same model as the iOS capsule).
struct MacPlayerSkipChip: View {
    let title: String
    let systemImage: String
    let countdownProgress: Double?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background {
                if let countdownProgress {
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.white.opacity(0.18))
                            .frame(width: geometry.size.width * max(0, min(countdownProgress, 1)))
                    }
                    .clipShape(Capsule())
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(.black.opacity(0.18)).interactive(), in: Capsule())
        .accessibilityLabel(title)
    }
}

/// The ±N s readout after a keyboard or button skip, left or right of center
/// like the iOS double-tap zones.
struct MacPlayerSeekFeedbackView: View {
    let presentation: PlayerSeekFeedbackPresentation

    var body: some View {
        GeometryReader { geometry in
            let offset = geometry.size.width / 4

            badge
                .offset(x: presentation.direction == .backward ? -offset : offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }

    private var badge: some View {
        VStack(spacing: 4) {
            Image(systemName: presentation.direction.symbolName)
                .font(.system(size: 30, weight: .medium))
            Text(presentation.direction == .backward ? "−\(presentation.seconds)s" : "+\(presentation.seconds)s")
                .font(.callout.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(.white.opacity(0.9))
        .frame(width: 84, height: 84)
        .glassEffect(.regular, in: Circle())
    }
}

/// Manual audio sync (#67) as a small Mac sheet: the same 50 ms stepper,
/// value and Reset as the iOS Audio sheet's section.
struct MacPlayerAudioOffsetSheet: View {
    @Environment(PlaybackCoordinator.self) private var playback

    let onDone: () -> Void

    var body: some View {
        let availability = playback.audioOffsetAvailability
        let offset = playback.audioOffsetMilliseconds

        VStack(alignment: .leading, spacing: 16) {
            Text("Audio Offset")
                .font(.headline)

            HStack {
                Stepper(
                    value: Binding(
                        get: { playback.audioOffsetMilliseconds },
                        set: { playback.setAudioOffset(milliseconds: $0) }
                    ),
                    in: AudioOffsetPolicy.range,
                    step: AudioOffsetPolicy.stepMilliseconds
                ) {
                    Text(AudioOffsetPolicy.title(for: offset))
                        .monospacedDigit()
                        .frame(minWidth: 80, alignment: .leading)
                }
                .disabled(!availability.isAvailable)
                .accessibilityValue(AudioOffsetPolicy.title(for: offset))

                Spacer()

                Button("Reset") {
                    playback.setAudioOffset(milliseconds: 0)
                }
                .disabled(offset == 0 || !availability.isAvailable)
            }

            Text(availability.unavailableReason ?? AudioOffsetPolicy.timingDescription)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
/// The player's failure state: a compact card in the shape of
/// `ContentUnavailableView` ("Can't Play …", one line of reason, the raw
/// message quietly below it) with Close (Esc) and an optional default action.
struct MacPlayerErrorCard: View {
    struct Action {
        let title: String
        let perform: () -> Void
    }

    let title: String?
    let reason: String
    let detail: String?
    let primary: Action?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            Text(title.map { "Can\u{2019}t Play \u{201C}\($0)\u{201D}" } ?? "Can\u{2019}t Play This Video")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(reason)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            HStack(spacing: 10) {
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
                if let primary {
                    Button(primary.title, action: primary.perform)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
            .padding(.top, 8)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 20)
        .frame(width: 360)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    static func reason(for error: PlaybackError) -> String {
        switch error {
        case .unsupportedFormat:
            return "This video's format can't be played on this Mac."
        case .sourceUnavailable:
            return "Plex couldn't find or open the file on the server."
        case .networkError:
            return "The connection to the server was interrupted."
        case .serverUnreachable:
            return "The Plex server can't be reached."
        case .unauthorized:
            return "Your Plex sign-in has expired."
        case .unknown(let message):
            return reason(forMessage: message)
        }
    }

    /// The technical message under the reason, when it adds something.
    static func detail(for error: PlaybackError) -> String? {
        switch error {
        case .unsupportedFormat(let container, let videoCodec, let audioCodec):
            let parts = [container, videoCodec, audioCodec].compactMap { $0 }
            return parts.isEmpty ? nil : parts.map { $0.uppercased() }.joined(separator: " · ")
        case .networkError(let message):
            return message
        case .unknown(let message):
            return detail(forMessage: message)
        case .sourceUnavailable, .serverUnreachable, .unauthorized:
            return nil
        }
    }

    /// A full sentence is shown as the reason; a bare engine message ("Cannot
    /// Open") gets a plain reason and moves to the detail line.
    static func reason(forMessage message: String) -> String {
        isSentence(message) ? message : "The video couldn\u{2019}t be opened. The file may be damaged or unavailable."
    }

    static func detail(forMessage message: String) -> String? {
        isSentence(message) ? nil : message
    }

    private static func isSentence(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: " ").count >= 4 && (trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!"))
    }
}
#endif
