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
        self.buttonStyle(DuskTVChromeSuppressedButtonStyle())
        #else
        self
        #endif
    }

    @ViewBuilder
    func duskTVOSFocusEffectShape<S: Shape>(_ shape: S, scales: Bool = true) -> some View {
        #if os(tvOS)
        modifier(DuskTVFocusEffectModifier(shape: shape, scales: scales))
        #else
        self
        #endif
    }

    @ViewBuilder
    func duskTVOSFocusedScale(_ isFocused: Bool) -> some View {
        #if os(tvOS)
        modifier(DuskTVFocusedScaleModifier(isFocused: isFocused))
        #else
        self
        #endif
    }

    @ViewBuilder
    func duskTVOSPageBackground() -> some View {
        #if os(tvOS)
        self.background(Color.duskBackground.ignoresSafeArea())
        #else
        self
        #endif
    }

    @ViewBuilder
    func duskTVOSStandardImageDynamicRange() -> some View {
        #if os(tvOS)
        self.allowedDynamicRange(.standard)
        #else
        self
        #endif
    }

    /// Fades the bottom of a hero backdrop + `DuskHeroBackdropOverlay` stack
    /// into the page background.
    ///
    /// On tvOS this masks the hero to transparent instead of painting
    /// `Color.duskBackground` over it. Real Apple TV HDR output resolves fills
    /// drawn inside the hero subtree and the page background through different
    /// color pipelines, so two stacked fills of the same color can still meet
    /// with a visible seam and gray mismatch. With the mask, the page
    /// background is the only fill at the boundary, which makes a seam
    /// impossible regardless of the output color pipeline. The mask always
    /// reaches zero alpha before the hero boundary so the seam stays impossible.
    ///
    /// `.standard` mirrors the inverse of the overlay's iOS bottom fade so both
    /// platforms produce the same composite. `.compact` is a tvOS-only, shorter
    /// and lighter fade that reveals more of the backdrop, used by the home
    /// cinematic hero banner.
    @ViewBuilder
    func duskHeroBackdropBottomFade(_ style: DuskHeroBottomFadeStyle = .standard) -> some View {
        #if os(tvOS)
        self.mask {
            LinearGradient(
                stops: style.maskStops,
                startPoint: .top,
                endPoint: .bottom
            )
        }
        #else
        self
        #endif
    }

}

/// Selects the bottom-fade curve used by `duskHeroBackdropBottomFade()` on tvOS.
enum DuskHeroBottomFadeStyle {
    /// Full fade. Used by detail heroes.
    case standard
    /// Shorter, lighter fade that keeps more of the backdrop visible. Used by
    /// the home cinematic hero banner.
    case compact

    #if os(tvOS)
    var maskStops: [Gradient.Stop] {
        switch self {
        case .standard:
            return [
                .init(color: .white, location: 0),
                .init(color: .white, location: 0.20),
                .init(color: .white.opacity(0.92), location: 0.38),
                .init(color: .white.opacity(0.72), location: 0.54),
                .init(color: .white.opacity(0.40), location: 0.68),
                .init(color: .white.opacity(0.10), location: 0.80),
                .init(color: .white.opacity(0), location: 0.88),
                .init(color: .white.opacity(0), location: 1),
            ]
        case .compact:
            return [
                .init(color: .white, location: 0),
                .init(color: .white, location: 0.30),
                .init(color: .white.opacity(0.90), location: 0.46),
                .init(color: .white.opacity(0.64), location: 0.60),
                .init(color: .white.opacity(0.34), location: 0.72),
                .init(color: .white.opacity(0.10), location: 0.82),
                .init(color: .white.opacity(0), location: 0.90),
                .init(color: .white.opacity(0), location: 1),
            ]
        }
    }
    #endif
}

#if os(tvOS)
private struct DuskTVChromeSuppressedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.86 : 1.0)
    }
}
#endif

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

#if os(tvOS)
private struct DuskTVFocusEffectModifier<S: Shape>: ViewModifier {
    @Environment(\.isFocused) private var isFocused

    let shape: S
    let scales: Bool

    func body(content: Content) -> some View {
        content
            .contentShape(.interaction, shape)
            .contentShape(.hoverEffect, shape)
            .focusEffectDisabled()
            .hoverEffect(.highlight)
            .scaleEffect(scales && isFocused ? 1.05 : 1.0)
            .shadow(
                color: scales && isFocused ? Color.white.opacity(0.34) : .clear,
                radius: scales && isFocused ? 16 : 0,
                y: scales && isFocused ? 6 : 0
            )
            .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

private struct DuskTVFocusedScaleModifier: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .shadow(
                color: isFocused ? Color.white.opacity(0.34) : .clear,
                radius: isFocused ? 16 : 0,
                y: isFocused ? 6 : 0
            )
            .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}
#endif

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

    static var posterProgressBarHeight: CGFloat {
        #if os(tvOS)
        7
        #else
        5
        #endif
    }
}

struct DetailHeroBackdrop: View {
    @Environment(PlexService.self) private var plexService

    let imageURL: URL?
    let height: CGFloat
    var imageAlignment: Alignment = .center
    var keepsPreviousImageWhileLoading = false

    #if canImport(UIKit)
    @State private var retainedImage: UIImage?
    @State private var retainedImageURL: URL?
    #endif

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.duskSurface

                if keepsPreviousImageWhileLoading {
                    retainedBackdropImage(size: geometry.size)
                } else {
                    asyncBackdropImage(size: geometry.size)
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
        .task(id: imageURL) {
            await loadRetainedImageIfNeeded()
        }
    }

    @ViewBuilder
    private func asyncBackdropImage(size: CGSize) -> some View {
        if let imageURL {
            DuskAsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let image):
                    backdropImage(image, size: size)
                default:
                    Color.clear
                }
            }
        }
    }

    @ViewBuilder
    private func retainedBackdropImage(size: CGSize) -> some View {
        #if canImport(UIKit)
        if let retainedImage {
            backdropImage(Image(uiImage: retainedImage), size: size)
                .id(retainedImageURL)
                .transition(.opacity)
        }
        #else
        asyncBackdropImage(size: size)
        #endif
    }

    private func backdropImage(_ image: Image, size: CGSize) -> some View {
        image
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: imageAlignment)
            .frame(
                width: size.width,
                height: size.height,
                alignment: imageAlignment
            )
            .clipped()
    }

    @MainActor
    private func loadRetainedImageIfNeeded() async {
        guard keepsPreviousImageWhileLoading else { return }

        #if canImport(UIKit)
        guard let imageURL else {
            withAnimation(.easeInOut(duration: 0.16)) {
                retainedImage = nil
                retainedImageURL = nil
            }
            return
        }

        do {
            let image = try await DuskImageLoader.shared.image(for: imageURL, using: plexService)
            guard !Task.isCancelled else { return }

            withAnimation(.easeInOut(duration: 0.18)) {
                retainedImage = image
                retainedImageURL = imageURL
            }
        } catch {
            guard retainedImage == nil else { return }
            retainedImageURL = nil
        }
        #endif
    }
}

/// Selects how heavily `DuskHeroBackdropOverlay` scrims the backdrop on iOS.
/// tvOS is unaffected — it always renders the full-strength vertical scrim and
/// relies on `duskHeroBackdropBottomFade()` for the bottom transition.
enum DuskHeroOverlayStyle {
    /// Full-strength scrim. Used by the home cinematic hero, whose rotating
    /// backdrops need a dependable dark base for the overlaid text.
    case standard
    /// Lighter scrim that lets more of the backdrop read through. Used by the
    /// movie/show/season/episode detail heroes, where the artwork should lead
    /// and the title block sits in the lower third over a still-solid base.
    case soft

    #if !os(tvOS)
    /// Top-to-bottom darkening applied across the whole hero. `.soft` keeps the
    /// upper two thirds close to clear and only ramps up behind the title block.
    var verticalDarkeningStops: [Gradient.Stop] {
        switch self {
        case .standard:
            return [
                .init(color: Color.black.opacity(0.18), location: 0),
                .init(color: Color.black.opacity(0.56), location: 0.62),
                .init(color: Color.black.opacity(0.86), location: 1),
            ]
        case .soft:
            return [
                .init(color: Color.black.opacity(0.14), location: 0),
                .init(color: Color.black.opacity(0.14), location: 0.34),
                .init(color: Color.black.opacity(0.24), location: 0.62),
                .init(color: Color.black.opacity(0.48), location: 0.82),
                .init(color: Color.black.opacity(0.70), location: 1),
            ]
        }
    }

    /// Bottom fade into `Color.duskBackground` that blends the hero into the
    /// page and backs the title block. Both styles still reach full opacity
    /// before the hero edge so the join to the page stays seamless; `.soft`
    /// simply holds the fade off until the lower third.
    var bottomBackgroundFadeStops: [Gradient.Stop] {
        switch self {
        case .standard:
            return [
                .init(color: Color.duskBackground.opacity(0), location: 0),
                .init(color: Color.duskBackground.opacity(0), location: 0.20),
                .init(color: Color.duskBackground.opacity(0.08), location: 0.38),
                .init(color: Color.duskBackground.opacity(0.28), location: 0.54),
                .init(color: Color.duskBackground.opacity(0.60), location: 0.68),
                .init(color: Color.duskBackground.opacity(0.90), location: 0.80),
                .init(color: Color.duskBackground, location: 0.88),
                .init(color: Color.duskBackground, location: 1),
            ]
        case .soft:
            return [
                .init(color: Color.duskBackground.opacity(0), location: 0),
                .init(color: Color.duskBackground.opacity(0), location: 0.40),
                .init(color: Color.duskBackground.opacity(0.06), location: 0.52),
                .init(color: Color.duskBackground.opacity(0.22), location: 0.64),
                .init(color: Color.duskBackground.opacity(0.48), location: 0.74),
                .init(color: Color.duskBackground.opacity(0.80), location: 0.84),
                .init(color: Color.duskBackground, location: 0.92),
                .init(color: Color.duskBackground, location: 1),
            ]
        }
    }
    #endif
}

/// Shared hero scrims. Always pair the backdrop + overlay stack with
/// `duskHeroBackdropBottomFade()`: on iOS the overlay paints the bottom fade
/// itself, on tvOS the modifier masks the hero out instead. Never paint
/// `Color.duskBackground` inside the hero on tvOS — see
/// `duskHeroBackdropBottomFade()` for why.
///
/// `style` only affects iOS; tvOS always renders the full-strength scrim.
struct DuskHeroBackdropOverlay: View {
    var style: DuskHeroOverlayStyle = .standard

    #if !os(tvOS)
    private let bottomBackgroundHeight: CGFloat = 24
    #endif

    var body: some View {
        ZStack {
            #if os(tvOS)
            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.18), location: 0),
                    .init(color: Color.black.opacity(0.56), location: 0.62),
                    .init(color: Color.black.opacity(0.86), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            #else
            LinearGradient(
                stops: style.verticalDarkeningStops,
                startPoint: .top,
                endPoint: .bottom
            )
            #endif

            LinearGradient(
                stops: [
                    .init(color: Color.black.opacity(0.86), location: 0),
                    .init(color: Color.black.opacity(0.50), location: 0.34),
                    .init(color: Color.black.opacity(0.12), location: 0.68),
                    .init(color: Color.black.opacity(0), location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            #if !os(tvOS)
            LinearGradient(
                stops: style.bottomBackgroundFadeStops,
                startPoint: .top,
                endPoint: .bottom
            )

            Color.duskBackground
                .frame(maxWidth: .infinity)
                .frame(height: bottomBackgroundHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            #endif
        }
        .allowsHitTesting(false)
    }
}
