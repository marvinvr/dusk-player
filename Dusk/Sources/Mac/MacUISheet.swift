#if os(macOS)
import SwiftUI

extension View {
    /// Gives a sheet a sensible window size on the Mac. A Mac sheet sizes to
    /// its content, and a `NavigationStack`, `List` or `Form` has no ideal
    /// size of its own, so the shared iOS sheets would open tiny.
    func macUISheetSize(
        minWidth: CGFloat = 420,
        idealWidth: CGFloat = 520,
        minHeight: CGFloat = 360,
        idealHeight: CGFloat = 560
    ) -> some View {
        frame(
            minWidth: minWidth,
            idealWidth: idealWidth,
            minHeight: minHeight,
            idealHeight: idealHeight
        )
    }
}
#endif
