import SwiftUI

struct SettingsContainer<Content: View>: View {
    @Environment(MediaService.self) private var media
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
        #if os(tvOS)
        .fullScreenCover(isPresented: homeUserPickerPresented) {
            homeUserPicker
        }
        #elseif os(macOS)
        .sheet(isPresented: homeUserPickerPresented) {
            homeUserPicker
                .macUISheetSize(minWidth: 560, idealWidth: 720, minHeight: 440, idealHeight: 560)
        }
        #else
        .sheet(isPresented: homeUserPickerPresented) {
            homeUserPicker
        }
        #endif
        .duskNavigationTitle("Settings")
        .duskNavigationBarTitleDisplayModeLarge()
    }

    private var homeUserPicker: some View {
        HomeUserPickerView(
            profiles: media.profiles,
            rememberSelection: media.automaticHomeSignIn,
            onComplete: {
                viewModel.showHomeUserPicker = false
            },
            onCancel: {
                viewModel.showHomeUserPicker = false
            }
        )
    }

    private var homeUserPickerPresented: Binding<Bool> {
        Binding(
            get: { viewModel.showHomeUserPicker && media.canSwitchProfiles },
            set: { viewModel.showHomeUserPicker = $0 }
        )
    }
}
