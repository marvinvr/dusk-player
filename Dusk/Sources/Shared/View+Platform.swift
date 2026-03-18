import SwiftUI
#if os(iOS)
import UIKit
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

struct DetailHeroBackdrop: View {
    let imageURL: URL?
    let height: CGFloat

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
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                                .frame(
                                    width: geometry.size.width,
                                    height: geometry.size.height,
                                    alignment: .center
                                )
                                .clipped()
                        default:
                            Color.clear
                        }
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
            .clipped()
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
    }
}
