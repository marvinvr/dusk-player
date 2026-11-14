#if os(macOS)
import SwiftUI

// Pointer hover for clickable artwork on the Mac. The clickable card tracks
// the pointer (`macUIHoverSource()`) and hands the state down through the
// environment, so only the artwork responds (`macUIHoverLift`), the way the
// Mac TV app lifts a poster without moving its title. Neutral: a small scale
// and a soft shadow, no colour. See docs/macos.md.

extension EnvironmentValues {
    /// True while the pointer is over the clickable card this view sits in.
    @Entry var macUIIsHovered = false
}

extension View {
    /// Marks a clickable card: hovering it lifts the artwork inside.
    func macUIHoverSource() -> some View {
        modifier(MacUIHoverSourceModifier())
    }

    /// The artwork's response to `macUIHoverSource()` on its card.
    func macUIHoverLift(cornerRadius: CGFloat) -> some View {
        modifier(MacUIHoverLiftModifier(cornerRadius: cornerRadius))
    }
}

private struct MacUIHoverSourceModifier: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .environment(\.macUIIsHovered, isHovered)
            .onHover { isHovered = $0 }
    }
}

private struct MacUIHoverLiftModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.macUIIsHovered) private var isHovered
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        content
            .overlay {
                // STYLE §3.2's 1pt border, so a white poster keeps its edge
                // on the light page (and a black one on the dark page). It
                // brightens under the pointer on the dark page, where the
                // lift's shadow disappears.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor(isDark: isDark), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(
                color: .black.opacity(shadowOpacity(isDark: isDark)),
                radius: isHovered ? 12 : 3,
                y: isHovered ? 6 : 1
            )
            .scaleEffect(isHovered ? 1.04 : 1)
            .offset(y: isHovered ? -2 : 0)
            .animation(.easeOut(duration: 0.16), value: isHovered)
    }

    private func borderColor(isDark: Bool) -> Color {
        if isDark {
            return .white.opacity(isHovered ? 0.22 : 0.06)
        }
        return .black.opacity(0.08)
    }

    /// A very soft resting shadow on the light page only; the lift's shadow
    /// in both.
    private func shadowOpacity(isDark: Bool) -> Double {
        if isHovered { return isDark ? 0.55 : 0.28 }
        return isDark ? 0 : 0.08
    }
}

extension EnvironmentValues {
    /// Lines a poster card's title takes on the Mac (one, truncated with a
    /// tooltip, on shelves and grids alike). See `PosterCardText`.
    @Entry var macUIPosterTitleLines = 1
}
#endif
