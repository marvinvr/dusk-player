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
        #elseif os(macOS)
        self
        #else
        self.navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder
    func duskNavigationBarTitleDisplayModeLarge() -> some View {
        #if os(tvOS)
        self
        #elseif os(macOS)
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
        #elseif os(macOS)
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

    /// Native tvOS poster focus: the system card lifts, scales, and
    /// parallax-shadows the artwork. A custom button style
    /// (`duskSuppressTVOSButtonChrome`) replaces that effect, and
    /// `focusEffectDisabled()` removes the parallax, so library poster
    /// cells must use this instead. iOS is unchanged — `.plain` on the
    /// card keeps the iPad pointer hover.
    ///
    /// No `.hoverEffect(.highlight)` on top, here or on the label: the card
    /// style already is that effect. Stacked on every poster it doubled
    /// Home's per-frame SwiftUI work, so the hero paged and the move down
    /// into the shelves stuttered (1.7.4), and it covered the card's lift
    /// with a flat sheen.
    @ViewBuilder
    func duskTVOSSystemPosterButton() -> some View {
        #if os(tvOS)
        self
            .buttonStyle(.card)
            .buttonBorderShape(.roundedRectangle(radius: PosterArtwork.cornerRadius))
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
    func duskTVOSFocusedScale(_ isFocused: Bool, glow: Bool = true) -> some View {
        #if os(tvOS)
        modifier(DuskTVFocusedScaleModifier(isFocused: isFocused, glow: glow))
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

    /// What a tvOS pop-up sits on: the page behind it under the system blur
    /// and a light dim, so nothing of it reads through (the synopsis cover's
    /// look). Goes on the content of a `fullScreenCover`; no-op on iOS.
    @ViewBuilder
    func duskTVOSPopUpBackground() -> some View {
        #if os(tvOS)
        self
            .background(Color.black.opacity(0.35).ignoresSafeArea())
            .presentationBackground(.regularMaterial)
        #else
        self
        #endif
    }

    /// A pop-up such as Add to Playlist or the Supporter page. iOS: a sheet.
    /// tvOS: a full-screen cover on `duskTVOSPopUpBackground()`, because a tvOS
    /// sheet is a small card that clips focused rows and only lightly dims
    /// the page around it. Menu closes it.
    @ViewBuilder
    func duskPopUp<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(tvOS)
        fullScreenCover(isPresented: isPresented) {
            content().duskTVOSPopUpBackground()
        }
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }

    @ViewBuilder
    func duskPopUp<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        #if os(tvOS)
        fullScreenCover(item: item) { value in
            content(value).duskTVOSPopUpBackground()
        }
        #else
        sheet(item: item, content: content)
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
    /// and lighter fade that reveals more of the backdrop. `.fullBleed` is the
    /// tvOS full-screen home hero: the artwork is held at full strength almost
    /// to the display edge and only vignettes away in the last stretch.
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
    /// Shorter, lighter fade that keeps more of the backdrop visible.
    case compact
    /// Full-bleed fade for a hero that owns the whole display (the tvOS home
    /// cinematic hero). Almost the entire frame stays at full strength; the
    /// mask only vignettes across the last ~14% and still reaches — and holds —
    /// zero alpha *before* the hero boundary, which is what makes the HDR seam
    /// with the page background impossible. Do not let it end above zero.
    case fullBleed

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
        case .fullBleed:
            return [
                .init(color: .white, location: 0),
                .init(color: .white, location: 0.86),
                .init(color: .white.opacity(0.84), location: 0.92),
                .init(color: .white.opacity(0.40), location: 0.965),
                .init(color: .white.opacity(0), location: 0.99),
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

#if os(macOS)
/// The Mac is never an iPhone Duo; shared layout code asks anyway.
enum DuskDuoDisplay {
    static let isActive = false
    static let isInner = false
}
#endif

#if os(iOS)
/// iPhone Duo. Both of its displays are wider on their short side than any
/// slab iPhone (cover 466×678pt, inner 669×951pt; the largest slab is 440pt
/// across), which is how this tells it apart. Always false on every other
/// iPhone and on iPad. Read during `body`: folding, unfolding and rotating all
/// change the size class or the geometry, so the views asking re-render.
@MainActor
enum DuskDuoDisplay {
    private static var shorterSide: CGFloat? {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return nil }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        // No scene yet at launch, when the app orientation mask is first read.
        let bounds = scene?.screen.bounds ?? UIScreen.main.bounds
        return min(bounds.width, bounds.height)
    }

    /// Either display.
    static var isActive: Bool {
        (shorterSide ?? 0) > 450
    }

    /// The inner (unfolded) display.
    static var isInner: Bool {
        (shorterSide ?? 0) >= 600
    }
}

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
    var glow: Bool = true

    func body(content: Content) -> some View {
        let glows = glow && isFocused

        content
            .scaleEffect(isFocused ? 1.05 : 1.0)
            .shadow(
                color: glows ? Color.white.opacity(0.34) : .clear,
                radius: glows ? 16 : 0,
                y: glows ? 6 : 0
            )
            .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}
#endif

enum DuskPosterMetrics {
    static var carouselSectionSpacing: CGFloat {
        #if os(tvOS)
        22
        #else
        12
        #endif
    }

    static var carouselHeaderSpacing: CGFloat {
        #if os(tvOS)
        18
        #else
        12
        #endif
    }

    static var carouselItemSpacing: CGFloat {
        #if os(tvOS)
        34
        #else
        12
        #endif
    }

    static var carouselHorizontalPadding: CGFloat {
        #if os(tvOS)
        52
        #elseif os(macOS)
        MacUILayout.contentInset
        #else
        16
        #endif
    }

    static var libraryPageHorizontalPadding: CGFloat {
        #if os(tvOS)
        carouselHorizontalPadding
        #else
        20
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
        36
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
        16
        #else
        6
        #endif
    }

    /// Artwork-to-title gap of the tvOS poster cards that use the system
    /// `.card` focus (`duskTVOSSystemPosterButton`). Only the artwork lifts;
    /// on a 232 × 348 poster it grows ~20pt per side, so `cardSpacing` let
    /// the focused artwork touch its title (#74). This leaves ~14pt of room,
    /// like the Supporter icon picker. Fixed, so focus never moves a row.
    static var systemCardTextSpacing: CGFloat {
        #if os(tvOS)
        34
        #else
        cardSpacing
        #endif
    }

    static var cardTextSpacing: CGFloat {
        #if os(tvOS)
        4
        #else
        0
        #endif
    }

    static var gridHorizontalPadding: CGFloat {
        #if os(tvOS)
        48
        #elseif os(macOS)
        MacUILayout.contentInset
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
        #elseif os(macOS)
        18
        #else
        12
        #endif
    }

    static var gridRowSpacing: CGFloat {
        #if os(tvOS)
        44
        #elseif os(macOS)
        24
        #else
        18
        #endif
    }

    static var gridPreferredWidth: CGFloat {
        #if os(tvOS)
        196
        #elseif os(macOS)
        // A pointer and a big window: posters closer to the Mac TV app's.
        150
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
        #elseif os(macOS)
        150
        #else
        120
        #endif
    }

    static var carouselPosterWidth: CGFloat {
        #if os(tvOS)
        232
        #elseif os(macOS)
        // One poster size on every Mac shelf, close to the library grid's.
        150
        #else
        130
        #endif
    }

    /// 16:9 video-card width for library grids. Sized so a video card has a
    /// visual footprint similar to a 2:3 `gridPreferredWidth` poster
    /// (~2 columns on iPhone).
    static var videoGridPreferredWidth: CGFloat {
        #if os(tvOS)
        300
        #elseif os(macOS)
        240
        #else
        168
        #endif
    }

    /// 16:9 video-card width for carousels, the landscape counterpart of
    /// `carouselPosterWidth`.
    static var videoCarouselWidth: CGFloat {
        #if os(tvOS)
        340
        #elseif os(macOS)
        // Same as `continueWatchingWidth`: one landscape card size per page.
        260
        #else
        200
        #endif
    }

    static var continueWatchingWidth: CGFloat {
        #if os(tvOS)
        420
        #elseif os(macOS)
        260
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

    static var titleFont: Font { DuskFont.cardTitle(ios: .caption) }

    static var subtitleFont: Font { DuskFont.cardSubtitle(ios: .caption2) }

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
    /// The image is an unwatched episode's own still; see `spoilerBlur`.
    var blursImage = false

    #if canImport(UIKit)
    @State private var retainedImage: UIImage?
    @State private var retainedImageURL: URL?
    /// `blursImage` as it was for `retainedImage`: while the next episode's
    /// still loads, the previous one must keep its own blur, or focusing from
    /// an unwatched episode to a watched one shows the unwatched still sharp.
    @State private var retainedImageBlurs = false
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
                        // The hero's title block sits over the middle; the
                        // blur alone says what happened.
                        .spoilerBlur(blursImage, showsGlyph: false)
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
                .spoilerBlur(retainedImageURL == imageURL ? blursImage : retainedImageBlurs, showsGlyph: false)
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
                retainedImageBlurs = blursImage
            }
        } catch {
            guard retainedImage == nil else { return }
            retainedImageURL = nil
        }
        #endif
    }
}

/// Selects how heavily `DuskHeroBackdropOverlay` scrims the backdrop.
///
/// `.standard` and `.soft` differ on iOS only; on tvOS both render the same
/// full-strength vertical scrim they always have, and rely on
/// `duskHeroBackdropBottomFade()` for the bottom transition. `.cinematic` is the
/// one style that changes the tvOS scrim; only the home hero uses it (tvOS, and
/// the iPad layout on iOS).
enum DuskHeroOverlayStyle {
    /// Full-strength scrim. Used by the iPhone home cinematic hero, whose rotating
    /// backdrops need a dependable dark base for the overlaid text.
    case standard
    /// Lighter scrim that lets more of the backdrop read through. Used by the
    /// movie/show/season/episode detail heroes, where the artwork should lead
    /// and the title block sits in the lower third over a still-solid base.
    case soft
    /// Full-screen home hero (tvOS, and the near-full-screen iPad layout). The
    /// backdrop *is* the screen, so the top two thirds stay nearly clear and
    /// the darkening is deferred to the lower third, where the title block,
    /// pager and scroll hint live. On iOS it also adds a short top band behind
    /// the status bar and toolbar.
    case cinematic

    #if os(tvOS)
    /// Top-to-bottom darkening on tvOS. `.standard` / `.soft` must keep the
    /// long-standing values — the detail heroes share this overlay.
    var tvVerticalDarkeningStops: [Gradient.Stop] {
        switch self {
        case .standard, .soft:
            return [
                .init(color: Color.black.opacity(0.18), location: 0),
                .init(color: Color.black.opacity(0.56), location: 0.62),
                .init(color: Color.black.opacity(0.86), location: 1),
            ]
        case .cinematic:
            return [
                .init(color: Color.black.opacity(0.10), location: 0),
                .init(color: Color.black.opacity(0.20), location: 0.55),
                .init(color: Color.black.opacity(0.62), location: 0.82),
                .init(color: Color.black.opacity(0.88), location: 1),
            ]
        }
    }
    #endif

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
        case .cinematic:
            // A short top band keeps the status bar and toolbar legible; the
            // middle stays nearly clear and the darkening waits for the title block.
            return [
                .init(color: Color.black.opacity(0.30), location: 0),
                .init(color: Color.black.opacity(0.08), location: 0.14),
                .init(color: Color.black.opacity(0.12), location: 0.50),
                .init(color: Color.black.opacity(0.42), location: 0.78),
                .init(color: Color.black.opacity(0.72), location: 1),
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
        case .cinematic:
            return [
                .init(color: Color.duskBackground.opacity(0), location: 0),
                .init(color: Color.duskBackground.opacity(0), location: 0.58),
                .init(color: Color.duskBackground.opacity(0.10), location: 0.70),
                .init(color: Color.duskBackground.opacity(0.36), location: 0.81),
                .init(color: Color.duskBackground.opacity(0.72), location: 0.90),
                .init(color: Color.duskBackground, location: 0.96),
                .init(color: Color.duskBackground, location: 1),
            ]
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
/// On tvOS only `.cinematic` changes anything; `.standard` and `.soft` render
/// the same full-strength scrim they always have.
struct DuskHeroBackdropOverlay: View {
    var style: DuskHeroOverlayStyle = .standard

    #if !os(tvOS)
    private let bottomBackgroundHeight: CGFloat = 24
    #endif

    var body: some View {
        ZStack {
            #if os(tvOS)
            LinearGradient(
                stops: style.tvVerticalDarkeningStops,
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

// MARK: - Mac hero pages

extension View {
    /// Goes on every pushed screen: in the Mac main window the toolbar's
    /// back/forward pair replaces the navigation stack's own back button.
    /// `duskAppNavigationDestinations()` applies it already; screens pushed
    /// through another `navigationDestination` add it themselves. No-op on
    /// iOS and tvOS, and in the Mac Settings window.
    @ViewBuilder
    func macShellBackButtonHidden() -> some View {
        #if os(macOS)
        modifier(MacShellBackButtonHiding())
        #else
        self
        #endif
    }

    /// A hero page (Home, movie/show/season/episode detail) on the Mac: the
    /// page runs edge to edge under the transparent window toolbar, like the
    /// TV app. Apply it to the page's root `ScrollView` (not to the hero
    /// itself). It pulls the scroll content up under the toolbar so the hero
    /// artwork starts at the window's top edge, hides the visible toolbar
    /// title (the window title stays, for the Window menu and Mission
    /// Control) and the soft scroll-edge effect only while the hero is still
    /// under the toolbar: the artwork isn't blurred at rest, and once
    /// shelves/rows scroll under the toolbar the page title and the same soft
    /// edge as every other page come back.
    ///
    /// Every other Mac page needs nothing: the shell leaves the toolbar
    /// background automatic, which macOS 26 draws as the soft scroll edge
    /// over a scroll view. Don't hide the toolbar background on a scrolling
    /// page; that removes the edge effect and lets content overprint the
    /// title. No-op on iOS and tvOS.
    @ViewBuilder
    func macHeroUnderToolbar() -> some View {
        #if os(macOS)
        modifier(MacHeroUnderToolbarModifier())
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct MacHeroUnderToolbarModifier: ViewModifier {
    /// True once the page has scrolled far enough that the hero has left the
    /// toolbar area and shelves pass under it.
    @State private var isPastHero = false
    /// The window toolbar's height (the scroll view's top safe-area inset).
    @State private var toolbarInset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // The scroll view stays inside the safe area, so the system
            // scroll edge effect knows where the toolbar is; the content is
            // pulled up under the toolbar instead. (Ignoring the top safe
            // area on the scroll view put the hero there too, but then no
            // edge effect was ever drawn: scrolled rows ran bare under the
            // toolbar.)
            .contentMargins(.top, -toolbarInset, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { toolbarInset = $0 }
            // Scroll modifiers reach every scroll view inside the page too
            // (the hero pager, horizontal shelves); only the page's own
            // vertical scroll view decides, or a shelf reporting offset 0
            // would switch the edge effect off again.
            .onScrollGeometryChange(for: Bool?.self) { geometry in
                guard geometry.contentSize.height > geometry.containerSize.height + 1 else { return nil }
                let offset = geometry.contentOffset.y + geometry.contentInsets.top
                let heroHeight = geometry.containerSize.height * MacUILayout.heroMaxHeightFraction
                // The toolbar is ~52pt tall; switch the edge effect on as the
                // hero's bottom edge reaches it.
                return offset > max(heroHeight - 80, 120)
            } action: { _, isPast in
                if let isPast {
                    isPastHero = isPast
                }
            }
            // Only the edge effect toggles; the toolbar background stays
            // automatic (on macOS 26 it IS this edge effect, and hiding it
            // dynamically didn't reliably bring the edge back).
            .scrollEdgeEffectStyle(.soft, for: .top)
            .scrollEdgeEffectHidden(!isPastHero, for: .top)
            // The page title comes back once the hero has scrolled away (as
            // in Music/TV): it is what the soft edge sits under, and a page
            // with nothing in its toolbar (Home) gets no edge effect at all.
            .toolbar(removing: isPastHero ? nil : .title)
    }
}
#endif
