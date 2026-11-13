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

    func body(content: Content) -> some View {
        content
            .overlay {
                // A faint white wash, like a system collection item under the pointer.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.06 : 0))
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(isHovered ? 0.28 : 0), radius: 10, y: 5)
            .scaleEffect(isHovered ? 1.03 : 1)
            .animation(.easeOut(duration: 0.16), value: isHovered)
    }
}
#endif
