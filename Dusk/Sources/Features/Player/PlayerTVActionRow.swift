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
            .foregroundStyle(tint(for: action))
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

    private func tint(for action: PlayerTVActionItem) -> Color {
        if case let .sharePlay(isActive) = action, isActive {
            return Color.duskAccent
        }
        return .white
    }
}
#endif
