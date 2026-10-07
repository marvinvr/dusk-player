#if os(tvOS)
import SwiftUI

/// The circular glass buttons above the play bar.
///
/// These are **not** focusable. Selection is drawn from
/// `PlayerTVHUDController.transportFocus`, which the remote bridge drives, so
/// the focus engine never competes with the bridge for the remote. The visual
/// treatment matches the rest of the app's tvOS focus language (1.05× plus a
/// tight neutral glow — see `duskTVOSFocusedScale`).
struct PlayerTVActionRow: View {
    let actions: [PlayerTVActionItem]
    let selectedIndex: Int?
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: PlayerTVHUDLayout.actionRowSpacing) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                button(action, isSelected: index == selectedIndex)
            }
        }
        .animation(
            PlayerTVHUDLayout.animation(PlayerTVHUDLayout.selectionAnimation, reduceMotion: reduceMotion),
            value: selectedIndex
        )
    }

    private func button(_ action: PlayerTVActionItem, isSelected: Bool) -> some View {
        Image(systemName: action.systemImage)
            .font(DuskFont.TV.glyphSmall.weight(.semibold))
            .foregroundStyle(.white)
            .frame(
                width: PlayerTVHUDLayout.actionButtonDiameter,
                height: PlayerTVHUDLayout.actionButtonDiameter
            )
            .background {
                Circle()
                    .fill(.white.opacity(isSelected ? 0.22 : 0.10))
                    .background(.ultraThinMaterial, in: Circle())
            }
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(isSelected ? 0.5 : 0.16), lineWidth: 1)
            }
            .scaleEffect(isSelected ? 1.05 : 1.0)
            .shadow(
                color: isSelected ? .white.opacity(0.34) : .clear,
                radius: isSelected ? 16 : 0,
                y: isSelected ? 6 : 0
            )
            .accessibilityLabel(action.accessibilityLabel)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The Skip Intro / Skip Credits chip, drawn like AVKit's contextual action
/// button ("Skip Intro" in the TV app): a plain text capsule that is a white
/// platter with a dark label while it owns Select — the HUD is hidden — and a
/// dark translucent one while the play bar has the remote.
///
/// Not focusable, for the same reason as the action row: Select reaches it
/// through `PlayerTVHUDController`, never through the focus engine.
struct PlayerTVSkipChip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    /// Auto-skip countdown, 0...1, swept across the platter.
    let countdownProgress: Double?
    let isSelected: Bool

    var body: some View {
        Text(title)
            .font(DuskFont.TV.buttonLabel)
            .lineLimit(1)
            .foregroundStyle(isSelected ? Color.black.opacity(0.86) : Color.white)
            .padding(.horizontal, PlayerTVHUDLayout.skipChipHorizontalPadding)
            .frame(
                minWidth: PlayerTVHUDLayout.skipChipMinWidth,
                minHeight: PlayerTVHUDLayout.skipChipHeight
            )
            .background { platter }
            .clipShape(Capsule())
            .scaleEffect(isSelected ? PlayerTVHUDLayout.bottomTrailingSelectedScale : 1)
            // The lift shadow of a focused tvOS button: soft, dark and low,
            // never a white glow over bright video.
            .shadow(
                color: .black.opacity(isSelected ? 0.4 : 0),
                radius: isSelected ? 20 : 0,
                y: isSelected ? 12 : 0
            )
            .animation(
                PlayerTVHUDLayout.animation(PlayerTVHUDLayout.selectionAnimation, reduceMotion: reduceMotion),
                value: isSelected
            )
    }

    private var platter: some View {
        ZStack(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(.white)
            } else {
                Capsule()
                    .fill(.white.opacity(0.12))
                    .background(.ultraThinMaterial, in: Capsule())
            }

            if let countdownProgress {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(isSelected ? Color.black.opacity(0.12) : Color.white.opacity(0.2))
                        .frame(width: geometry.size.width * min(max(countdownProgress, 0), 1))
                        .animation(.linear(duration: 0.1), value: countdownProgress)
                }
            }
        }
    }
}
#endif
