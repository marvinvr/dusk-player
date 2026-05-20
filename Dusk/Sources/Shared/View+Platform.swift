import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if os(iOS)
import SafariServices
#endif

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
    func duskStatusBarHidden(_ hidden: Bool = true) -> some View {
        #if os(tvOS)
        self
        #else
        self.statusBarHidden(hidden)
        #endif
    }

    @ViewBuilder
    func duskCaptureStatusBarAppearance() -> some View {
        #if os(iOS)
        self.background {
            DuskStatusBarAppearanceCaptureView()
                .frame(width: 0, height: 0)
        }
        #else
        self
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
        modifier(DuskTVFocusEffectModifier(shape: shape))
        #else
        self
        #endif
    }

}

#if os(iOS)
struct DuskSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = false

        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

private struct DuskStatusBarAppearanceCaptureView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> DuskStatusBarAppearanceCaptureController {
        DuskStatusBarAppearanceCaptureController()
    }

    func updateUIViewController(
        _ uiViewController: DuskStatusBarAppearanceCaptureController,
        context: Context
    ) {
        uiViewController.captureStatusBarAppearance()
    }
}

private final class DuskStatusBarAppearanceCaptureController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        captureStatusBarAppearance()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        captureStatusBarAppearance()
    }

    func captureStatusBarAppearance() {
        parent?.modalPresentationCapturesStatusBarAppearance = true
        parent?.setNeedsStatusBarAppearanceUpdate()
        parent?.presentingViewController?.setNeedsStatusBarAppearanceUpdate()
    }
}
#endif

private struct DuskTVFocusEffectModifier<S: Shape>: ViewModifier {
    @Environment(\.isFocused) private var isFocused

    let shape: S

    func body(content: Content) -> some View {
        content
            .contentShape(.interaction, shape)
            .contentShape(.hoverEffect, shape)
            .focusEffectDisabled()
            .hoverEffect(.highlight)
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .shadow(
                color: isFocused ? Color.duskAccent.opacity(0.30) : .clear,
                radius: isFocused ? 20 : 0,
                y: isFocused ? 10 : 0
            )
            .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

enum DuskPosterMetrics {
    static var carouselSectionSpacing: CGFloat {
        #if os(tvOS)
        30
        #else
        12
        #endif
    }

    static var carouselHeaderSpacing: CGFloat {
        #if os(tvOS)
        24
        #else
        12
        #endif
    }

    static var carouselItemSpacing: CGFloat {
        #if os(tvOS)
        40
        #else
        12
        #endif
    }

    static var carouselHorizontalPadding: CGFloat {
        #if os(tvOS)
        52
        #else
        16
        #endif
    }

    static var carouselBottomPadding: CGFloat {
        #if os(tvOS)
        24
        #else
        2
        #endif
    }

    static var pageSectionSpacing: CGFloat {
        #if os(tvOS)
        44
        #else
        18
        #endif
    }

    static var pageBottomPadding: CGFloat {
        #if os(tvOS)
        88
        #else
        24
        #endif
    }

    static var cardSpacing: CGFloat {
        #if os(tvOS)
        28
        #else
        6
        #endif
    }

    static var cardTextSpacing: CGFloat {
        #if os(tvOS)
        6
        #else
        0
        #endif
    }

    static var gridHorizontalPadding: CGFloat {
        #if os(tvOS)
        48
        #else
        12
        #endif
    }

    static var detailHorizontalPadding: CGFloat {
        #if os(tvOS)
        48
        #else
        20
        #endif
    }

    static var gridSpacing: CGFloat {
        #if os(tvOS)
        40
        #else
        12
        #endif
    }

    static var gridRowSpacing: CGFloat {
        #if os(tvOS)
        44
        #else
        18
        #endif
    }

    static var gridPreferredWidth: CGFloat {
        #if os(tvOS)
        196
        #else
        104
        #endif
    }

    static var detailGridSpacing: CGFloat {
        #if os(tvOS)
        40
        #else
        14
        #endif
    }

    static var detailGridRowSpacing: CGFloat {
        #if os(tvOS)
        44
        #else
        18
        #endif
    }

    static var detailGridPreferredWidth: CGFloat {
        #if os(tvOS)
        204
        #else
        120
        #endif
    }

    static var carouselPosterWidth: CGFloat {
        #if os(tvOS)
        232
        #else
        130
        #endif
    }

    static var continueWatchingWidth: CGFloat {
        #if os(tvOS)
        420
        #else
        280
        #endif
    }

    static var heroPosterWidth: CGFloat {
        #if os(tvOS)
        300
        #else
        180
        #endif
    }

    static var titleFont: Font {
        #if os(tvOS)
        .subheadline.weight(.semibold)
        #else
        .caption
        #endif
    }

    static var subtitleFont: Font {
        #if os(tvOS)
        .caption
        #else
        .caption2
        #endif
    }
}

struct DetailHeroBackdrop: View {
    let imageURL: URL?
    let height: CGFloat
    var imageAlignment: Alignment = .center

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.duskSurface

                if let imageURL {
                    DuskAsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: imageAlignment)
                                .frame(
                                    width: geometry.size.width,
                                    height: geometry.size.height,
                                    alignment: imageAlignment
                                )
                                .clipped()
                        default:
                            Color.clear
                        }
                    }
                }
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: imageAlignment
            )
            .clipped()
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }
}
