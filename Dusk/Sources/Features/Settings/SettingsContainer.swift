import SwiftUI

struct SettingsContainer<Content: View>: View {
    @Environment(PlexService.self) private var plexService
    @Binding var path: NavigationPath
    let viewModel: SettingsViewModel
    private let content: Content

    init(
        path: Binding<NavigationPath>,
        viewModel: SettingsViewModel,
        @ViewBuilder content: () -> Content
    ) {
        self._path = path
        self.viewModel = viewModel
        self.content = content()
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.duskBackground.ignoresSafeArea()
                content
            }
            .sheet(isPresented: serverPickerPresented) {
                ServerPickerView(servers: viewModel.availableServers) { server in
                    try await viewModel.connect(to: server, using: plexService)
                } onCancel: {
                    viewModel.showServerPicker = false
                }
            }
            .duskNavigationTitle("Settings")
            .duskNavigationBarTitleDisplayModeLarge()
            .duskAppNavigationDestinations()
        }
    }

    private var serverPickerPresented: Binding<Bool> {
        Binding(
            get: { viewModel.showServerPicker && !viewModel.availableServers.isEmpty },
            set: { viewModel.showServerPicker = $0 }
        )
    }
}
