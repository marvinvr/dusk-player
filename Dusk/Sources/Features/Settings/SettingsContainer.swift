import SwiftUI

struct SettingsContainer<Content: View>: View {
    @Environment(PlexService.self) private var plexService
    let viewModel: SettingsViewModel
    private let content: Content

    init(
        viewModel: SettingsViewModel,
        @ViewBuilder content: () -> Content
    ) {
        self.viewModel = viewModel
        self.content = content()
    }

    var body: some View {
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
        .sheet(isPresented: homeUserPickerPresented) {
            HomeUserPickerView(
                users: plexService.homeUsers,
                rememberSelection: plexService.automaticHomeSignIn,
                onComplete: {
                    viewModel.showHomeUserPicker = false
                },
                onCancel: {
                    viewModel.showHomeUserPicker = false
                }
            )
        }
        .task {
            await viewModel.refreshAvailableServers(using: plexService)
        }
        .duskNavigationTitle("Settings")
        .duskNavigationBarTitleDisplayModeLarge()
    }

    private var serverPickerPresented: Binding<Bool> {
        Binding(
            get: { viewModel.showServerPicker && !viewModel.availableServers.isEmpty },
            set: { viewModel.showServerPicker = $0 }
        )
    }

    private var homeUserPickerPresented: Binding<Bool> {
        Binding(
            get: { viewModel.showHomeUserPicker && plexService.homeUsers.count > 1 },
            set: { viewModel.showHomeUserPicker = $0 }
        )
    }
}
