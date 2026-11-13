#if os(macOS)
import SwiftUI

/// Geometry and identity of the Mac's single main window. See docs/macos.md.
enum MacWindow {
    static let mainID = "main"
    static let defaultSize = CGSize(width: 1280, height: 800)
    static let minimumSize = CGSize(width: 900, height: 600)
    static let settingsSize = CGSize(width: 640, height: 560)
}

/// The Settings scene (⌘,): the same settings root iOS shows as a tab, in its
/// own navigation stack so its pages push inside the settings window.
struct MacSettingsWindow: View {
    @State private var path = NavigationPath()

    var body: some View {
        SettingsView(path: $path)
            .frame(
                minWidth: MacWindow.settingsSize.width,
                idealWidth: MacWindow.settingsSize.width,
                minHeight: MacWindow.settingsSize.height,
                idealHeight: MacWindow.settingsSize.height
            )
    }
}
#endif
