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
        content
            .overlay {
                // A hairline rim, so the lift also reads on a dark page where
                // the shadow disappears; the light page has the shadow.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(isHovered && colorScheme == .dark ? 0.22 : 0),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
            }
            .shadow(
                color: .black.opacity(isHovered ? (colorScheme == .dark ? 0.55 : 0.28) : 0),
                radius: 12,
                y: 6
            )
            .scaleEffect(isHovered ? 1.04 : 1)
            .offset(y: isHovered ? -2 : 0)
            .animation(.easeOut(duration: 0.16), value: isHovered)
    }
}

extension EnvironmentValues {
    /// Lines a poster card's title takes on the Mac: shelves keep one line,
    /// grids reserve two so every row lines up. See `PosterCardText`.
    @Entry var macUIPosterTitleLines = 1
}
#endif
