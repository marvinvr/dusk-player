import SwiftUI

extension View {
    @ViewBuilder
    func duskNavigationTitle(_ title: String) -> some View {
        #if os(tvOS)
        self
        #else
        self.navigationTitle(title)
        #endif
    }

    @ViewBuilder
    func duskNavigationBarTitleDisplayModeInline() -> some View {
        #if os(tvOS)
        self
        #else
        self.navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    func duskNavigationBarTitleDisplayModeLarge() -> some View {
        #if os(tvOS)
        self
        #else
        self.navigationBarTitleDisplayMode(.large)
        #endif
    }

    @ViewBuilder
    func duskScrollContentBackgroundHidden() -> some View {
        #if os(tvOS)
        self
        #else
        self.scrollContentBackground(.hidden)
        #endif
    }

    @ViewBuilder
    func duskListRowSeparatorHidden() -> some View {
        #if os(tvOS)
        self
        #else
        self.listRowSeparator(.hidden)
        #endif
    }

    @ViewBuilder
    func duskStatusBarHidden() -> some View {
        #if os(tvOS)
        self
        #else
        self.statusBarHidden()
        #endif
    }

    @ViewBuilder
    func duskSuppressTVOSButtonChrome() -> some View {
        #if os(tvOS)
        self.buttonStyle(.plain)
        #else
        self
        #endif
    }

    @ViewBuilder
    func duskTVOSFocusEffectShape<S: Shape>(_ shape: S) -> some View {
        #if os(tvOS)
        self
            .contentShape(.interaction, shape)
            .contentShape(.hoverEffect, shape)
        #else
        self
        #endif
    }
}
