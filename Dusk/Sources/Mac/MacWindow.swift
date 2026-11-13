#if os(macOS)
import SwiftUI

/// Geometry and identity of the Mac's single main window. See docs/macos.md.
enum MacWindow {
    static let mainID = "main"
    static let defaultSize = CGSize(width: 1280, height: 800)
    static let minimumSize = CGSize(width: 900, height: 600)
    static let settingsSize = CGSize(width: 640, height: 560)
}

/// The Settings scene (⌘,): a native Mac Settings window with toolbar tabs.
/// See `MacSettingsView`.
struct MacSettingsWindow: View {
    var body: some View {
        MacSettingsView()
    }
}
#endif
