#if os(macOS)
import SwiftUI

/// Shared Mac layout tokens, so every page, shelf, grid and hero lines up.
/// See docs/macos.md → "Mac UI rules".
enum MacUILayout {
    /// Leading/trailing inset of page content (shelves, grids, hero text).
    static let contentInset: CGFloat = 20
    /// Vertical gap between page sections.
    static let sectionSpacing: CGFloat = 28
    /// Readable line length for synopses and long text.
    static let readableTextWidth: CGFloat = 560
    /// A hero (Home, detail pages) never takes more of the window height than
    /// this, so the first shelf/section title is always visible.
    static let heroMaxHeightFraction: CGFloat = 0.65
}
#endif
