import SwiftUI

struct SettingsView: View {
    @Binding var path: NavigationPath

    var body: some View {
        NavigationStack(path: $path) {
            SettingsRootContent()
                .duskAppNavigationDestinations()
        }
    }
}

/// The settings screen without its own `NavigationStack`, usable both as the
/// Settings tab's root and as a destination pushed from the More tab.
struct SettingsRootContent: View {
    @State private var viewModel = SettingsViewModel()

    var body: some View {
        #if os(tvOS)
        SettingsTVView(viewModel: viewModel)
        #else
        SettingsIOSView(viewModel: viewModel)
        #endif
    }
}
