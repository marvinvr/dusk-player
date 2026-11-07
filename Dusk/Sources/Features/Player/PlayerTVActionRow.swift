#if os(tvOS)
import SwiftUI

/// The circular glass buttons above the play bar.
///
/// These are **not** focusable. Selection is drawn from
/// `PlayerTVHUDController.transportFocus`, which the remote bridge drives, so
/// the focus engine never competes with the bridge for the remote. The
/// selected button is drawn like a focused native tvOS button.
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
            .foregroundStyle(isSelected ? Color.black.opacity(0.86) : Color.white)
            .frame(
                width: PlayerTVHUDLayout.actionButtonDiameter,
                height: PlayerTVHUDLayout.actionButtonDiameter
            )
            // Selected = a focused tvOS button: a solid white platter with a
            // dark glyph, lifted. The old faint brightening (10% → 22% white)
            // was invisible over most video, so the row read as unselectable.
            .background {
                if isSelected {
                    Circle().fill(.white)
                } else {
                    Circle()
                        .fill(.white.opacity(0.10))
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(isSelected ? 0 : 0.16), lineWidth: 1)
            }
            .scaleEffect(isSelected ? PlayerTVHUDLayout.bottomTrailingSelectedScale : 1.0)
            .shadow(
                color: .black.opacity(isSelected ? 0.35 : 0),
                radius: isSelected ? 16 : 0,
                y: isSelected ? 10 : 0
            )
            // Trailing-aligned: the only button with a tooltip (Next Episode)
            // ends the row, so a centered tooltip would run past the safe
            // inset. An overlay lifted by the button's own height, so it
            // never changes the row's height.
            .overlay(alignment: .bottomTrailing) {
                if isSelected, let tooltip = action.tooltip {
                    PlayerTVActionTooltip(text: tooltip)
                        .padding(.bottom, PlayerTVHUDLayout.actionButtonDiameter + PlayerTVHUDLayout.actionTooltipGap)
                        .transition(.opacity)
                }
            }
            .accessibilityLabel(action.accessibilityLabel)
            .accessibilityValue(action.tooltip ?? "")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Small glass capsule over a selected action button, drawn like the play
/// bar's scrub time tooltip.
private struct PlayerTVActionTooltip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DuskFont.TV.badge.monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                Capsule()
                    .fill(.white.opacity(0.08))
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .overlay { Capsule().strokeBorder(.white.opacity(0.24), lineWidth: 1) }
    }
}

/// The Skip Intro / Skip Credits chip, drawn like a native tvOS `.glass`
/// button: light Liquid Glass with a dark label while it owns Select — the HUD
/// is hidden — and dark glass with a white label while the play bar has the
/// remote. The glass tints mirror the system button's focused and unfocused
/// looks; the auto-skip countdown sweeps across inside it.
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
            .background { countdownFill }
            .clipShape(Capsule())
            .glassEffect(glass, in: Capsule())
            .scaleEffect(isSelected ? PlayerTVHUDLayout.bottomTrailingSelectedScale : 1)
            .shadow(
                color: .black.opacity(isSelected ? 0.3 : 0),
                radius: isSelected ? 16 : 0,
                y: isSelected ? 10 : 0
            )
            .animation(
                PlayerTVHUDLayout.animation(PlayerTVHUDLayout.selectionAnimation, reduceMotion: reduceMotion),
                value: isSelected
            )
    }

    private var glass: Glass {
        isSelected ? .regular.tint(.white.opacity(0.78)) : .regular.tint(.black.opacity(0.3))
    }

    @ViewBuilder
    private var countdownFill: some View {
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
#endif
