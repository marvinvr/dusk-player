#if os(macOS)
import SwiftUI

// The shared iOS screens put their toolbar buttons in the navigation bar's
// trailing/leading slot, which macOS doesn't have. On the Mac those same
// call sites land in the window toolbar's standard spots instead, so the
// shared code needs no per-site branch. Declared here (macOS only) on
// purpose: these names are unavailable in the macOS SDK.

extension ToolbarItemPlacement {
    /// The window toolbar's trailing primary-action spot.
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }

    /// The window toolbar's leading navigation spot.
    static var topBarLeading: ToolbarItemPlacement { .navigation }
}
#endif
