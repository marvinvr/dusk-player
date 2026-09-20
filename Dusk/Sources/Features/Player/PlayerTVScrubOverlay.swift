#if os(tvOS)
import SwiftUI

/// The one-line affordance under the play bar while a scrub is in flight.
/// Nothing has been sent to the engine yet at this point, so the hint has to
/// say both how to commit and how to back out.
struct PlayerTVScrubHint: View {
    var body: some View {
        Text("Click to seek · Menu to cancel")
            .font(DuskFont.TV.caption)
            .foregroundStyle(.white.opacity(0.66))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
                Capsule()
                    .fill(.white.opacity(0.06))
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1) }
            .accessibilityHidden(true)
    }
}

/// Centred feedback shown over the video while the HUD is hidden: the running
/// total of a held left/right seek, or the state a play/pause press just put
/// the session in. The transport is not up in this mode, so this badge is the
/// only thing that makes the press legible.
struct PlayerTVTransientBadgeOverlay: View {
    let badge: PlayerTVTransientBadge

    private let diameter: CGFloat = 132

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.14))
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay { Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1) }

                Image(systemName: symbolName)
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: diameter, height: diameter)

            if let caption {
                Text(caption)
                    .font(DuskFont.TV.badge.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .shadow(color: .black.opacity(0.32), radius: 22, y: 10)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var symbolName: String {
        switch badge {
        case let .seek(direction, _):
            return direction.symbolName
        case let .playPause(isPlaying):
            return isPlaying ? "play.fill" : "pause.fill"
        }
    }

    private var caption: String? {
        switch badge {
        case let .seek(direction, seconds):
            let sign = direction == .backward ? "−" : "+"
            return "\(sign)\(PlayerTVTimeFormatter.string(TimeInterval(seconds)))"
        case .playPause:
            return nil
        }
    }
}
#endif
