import SwiftUI

// MARK: - Detail Hero Section

@MainActor
func usesFullWidthDetailActionButtons(for sizeClass: UserInterfaceSizeClass?) -> Bool {
    #if os(iOS)
    sizeClass == .compact && UIDevice.current.userInterfaceIdiom == .phone
    #else
    false
    #endif
}

var detailHeroActionSpacing: CGFloat {
    #if os(tvOS)
    22
    #else
    12
    #endif
}

/// Minimum height of a detail-hero action label. tvOS sits a touch lower than iOS
/// because its label is the 27pt `buttonLabel` token rather than a 38pt semantic
/// style; iOS keeps the value it has always had.
var detailHeroActionLabelMinHeight: CGFloat {
    #if os(tvOS)
    30
    #else
    34
    #endif
}

#if os(tvOS)
/// Contained width for the left-aligned tvOS primary action, so "Play" / "Resume"
/// doesn't hug its own label. Scaled down with the label type.
let detailHeroTVActionLabelMinWidth: CGFloat = 220
#endif

/// Horizontal alignment of the stacked primary + secondary hero actions: the
/// iOS secondary row centres under the full-width primary; the Mac's hugging
/// primary and its secondary row share a leading edge.
var detailHeroActionStackAlignment: HorizontalAlignment {
    #if os(macOS)
    .leading
    #else
    .center
    #endif
}

/// Gap above each detail-page section below the hero.
var detailSectionSpacing: CGFloat {
    #if os(macOS)
    MacUILayout.sectionSpacing
    #else
    40
    #endif
}

/// Height of a detail hero without the top inset. The Mac keeps the hero to
/// `MacUILayout.heroMaxHeightFraction` of the window (with a floor for the
/// title block), so the first section always shows.
func detailHeroBaseHeight(containerHeight: CGFloat, topInset: CGFloat) -> CGFloat {
    #if os(macOS)
    let windowHeight = containerHeight + topInset
    return max(windowHeight * MacUILayout.heroMaxHeightFraction, 400) - topInset
    #else
    min(max(containerHeight * 0.72, 520), 760)
    #endif
}

extension View {
    /// Pulls the detail page's scroll content up under the top safe area so the
    /// hero backdrop runs under the bar. On the Mac the scroll view itself
    /// ignores the top safe area (`macHeroUnderToolbar()`), so nothing moves.
    @ViewBuilder
    func detailHeroPullsUnderTopInset(_ topInset: CGFloat) -> some View {
        #if os(macOS)
        self
        #else
        self.padding(.top, -topInset)
        #endif
    }

    /// Room under the last section of a Mac detail page, so the page never
    /// ends flush with the window's bottom edge. No-op on iOS and tvOS.
    @ViewBuilder
    func detailMacPageBottomInset() -> some View {
        #if os(macOS)
        self.padding(.bottom, 48)
        #else
        self
        #endif
    }

    /// The window title of a detail page (Window menu, Mission Control). The
    /// visible title is hidden over the hero by `macHeroUnderToolbar()`.
    /// No-op on iOS and tvOS, whose detail pages carry no bar title.
    @ViewBuilder
    func detailMacWindowTitle(_ title: String?) -> some View {
        #if os(macOS)
        self.navigationTitle(title ?? "")
        #else
        self
        #endif
    }
}

/// Horizontal alignment for the detail hero's text/action blocks. iPhone centers
/// the whole hero (no poster); iPad and tvOS stay leading-aligned.
@MainActor
func detailHeroContentAlignment(for sizeClass: UserInterfaceSizeClass?) -> HorizontalAlignment {
    usesFullWidthDetailActionButtons(for: sizeClass) ? .center : .leading
}

/// Text alignment counterpart to `detailHeroContentAlignment(for:)`.
@MainActor
func detailHeroTextAlignment(for sizeClass: UserInterfaceSizeClass?) -> TextAlignment {
    usesFullWidthDetailActionButtons(for: sizeClass) ? .center : .leading
}

/// Whether the synopsis should render as its own section below the hero. The iPad
/// (regular) hero shows the description in its right column, so it is suppressed
/// below there; iPhone and tvOS keep the separate section.
@MainActor
func detailShowsSynopsisBelowHero(for sizeClass: UserInterfaceSizeClass?) -> Bool {
    #if os(tvOS)
    true
    #else
    sizeClass != .regular
    #endif
}

struct OfflineMetadataBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(DuskFont.glyphSmall(ios: .caption.weight(.semibold)))
                .foregroundStyle(Color.duskTextSecondary)

            Text(message)
                .font(DuskFont.caption(ios: .caption.weight(.medium)))
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

/// The show-title header shown in the season and episode detail heroes: the
/// show's clear-logo art (centered) when Plex provides it, falling back to the
/// show name, and wrapped in a link to the show so it doubles as navigation.
/// tvOS keeps the plain text — the image treatment is iOS-only.
struct DetailHeroShowTitleLink: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let title: String
    let logoURL: URL?
    let showRoute: AppNavigationRoute?

    // This is the show logo in its subordinate *supertitle* role (above a
    // season/episode text title), so it stays intentionally smaller than the
    // hero's main title artwork (`DetailHeroSection.titleArtworkHeight`).
    private var logoHeight: CGFloat {
        #if os(macOS)
        52
        #else
        sizeClass == .regular ? 68 : 60
        #endif
    }

    var body: some View {
        #if os(tvOS)
        titleText
        #else
        if let showRoute {
            NavigationLink(value: showRoute) {
                content
            }
            .buttonStyle(.plain)
            .duskSuppressTVOSButtonChrome()
        } else {
            content
        }
        #endif
    }

    // Centered on iPhone (the hero is a single centered column); leading on iPad,
    // where the artwork heads the left column of the two-column hero and is capped
    // to the same width as the Play button beneath it.
    #if !os(tvOS)
    private var contentAlignment: Alignment {
        sizeClass == .regular ? .leading : .center
    }

    @ViewBuilder
    private var content: some View {
        if let logoURL {
            DuskAsyncImage(url: logoURL) { phase in
                switch phase {
                case let .success(image):
                    let art = image
                        .resizable()
                        .scaledToFit()
                    #if os(macOS)
                    // A supertitle over the season/episode title: small and
                    // height-bound, whatever the logo's aspect ratio.
                    art.frame(maxWidth: 240, maxHeight: 52, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    #else
                    if sizeClass == .regular {
                        // iPad: fill the column width so it matches the Play button.
                        art.frame(width: detailHeroRegularPrimaryWidth, alignment: contentAlignment)
                    } else {
                        art
                            .frame(maxHeight: logoHeight)
                            .frame(maxWidth: .infinity, alignment: contentAlignment)
                    }
                    #endif
                case .empty:
                    Color.clear
                        .frame(height: logoHeight)
                case .failure:
                    alignedTitleText
                }
            }
        } else {
            alignedTitleText
        }
    }

    private var alignedTitleText: some View {
        titleText
            .frame(maxWidth: .infinity, alignment: contentAlignment)
    }
    #endif

    private var titleText: some View {
        Text(title)
            .font(DuskFont.metadata(ios: .subheadline.weight(.medium)))
            .foregroundStyle(Color.primary.opacity(0.78))
    }
}

/// Pins the iPad hero's right-column synopsis to the top of the Play button in
/// the left column, so anything above the synopsis (a season/episode title and
/// marker) sits above the button rather than level with the metadata.
private extension VerticalAlignment {
    enum HeroDescriptionTop: AlignmentID {
        static func defaultValue(in dimensions: ViewDimensions) -> CGFloat {
            dimensions[.top]
        }
    }

    static let heroDescriptionTop = VerticalAlignment(HeroDescriptionTop.self)
}

struct DetailHeroSection<Supertitle: View, Subtitle: View, Actions: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    let backdropURL: URL?
    /// The backdrop is an unwatched episode's own still; see `spoilerBlur`.
    var blursBackdrop = false
    let titleArtworkURL: URL?
    let title: String
    var descriptionText: String? = nil
    let topInset: CGFloat
    let containerWidth: CGFloat
    var backgroundLeadingInset: CGFloat = 0
    var heroBaseHeight: CGFloat = 380
    var keepsPreviousBackdropWhileLoading = false
    var titleLineLimit: Int = 2
    /// Optional small view shown directly under the title (e.g. an episode's
    /// season·episode marker). Kept as `AnyView` so callers can opt in without
    /// adding another generic parameter to every hero.
    var titleAccessory: AnyView? = nil
    /// iPad: a text title (no clear-logo) that is the page's own name, like a
    /// playlist's, heads the left column above the metadata instead of the
    /// right column a season/episode title uses.
    var leadsWithTextTitle = false
    @ViewBuilder var supertitle: Supertitle
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var actions: Actions

    init(
        backdropURL: URL?,
        blursBackdrop: Bool = false,
        titleArtworkURL: URL? = nil,
        title: String,
        descriptionText: String? = nil,
        topInset: CGFloat,
        containerWidth: CGFloat,
        backgroundLeadingInset: CGFloat = 0,
        heroBaseHeight: CGFloat = 380,
        keepsPreviousBackdropWhileLoading: Bool = false,
        titleLineLimit: Int = 2,
        titleAccessory: AnyView? = nil,
        leadsWithTextTitle: Bool = false,
        @ViewBuilder supertitle: () -> Supertitle,
        @ViewBuilder subtitle: () -> Subtitle,
        @ViewBuilder actions: () -> Actions
    ) {
        self.backdropURL = backdropURL
        self.blursBackdrop = blursBackdrop
        self.titleArtworkURL = titleArtworkURL
        self.title = title
        self.descriptionText = descriptionText
        self.topInset = topInset
        self.containerWidth = containerWidth
        self.backgroundLeadingInset = backgroundLeadingInset
        self.heroBaseHeight = heroBaseHeight
        self.keepsPreviousBackdropWhileLoading = keepsPreviousBackdropWhileLoading
        self.titleLineLimit = titleLineLimit
        self.titleAccessory = titleAccessory
        self.leadsWithTextTitle = leadsWithTextTitle
        self.supertitle = supertitle()
        self.subtitle = subtitle()
        self.actions = actions()
    }

    private var heroHeight: CGFloat { heroBaseHeight + topInset }

    var body: some View {
        let horizontalPadding: CGFloat = {
            #if os(tvOS)
            DuskPosterMetrics.detailHorizontalPadding
            #elseif os(macOS)
            MacUILayout.contentInset
            #else
            20
            #endif
        }()
        let contentTopPadding: CGFloat = {
            #if os(tvOS)
            topInset + 80
            #elseif os(macOS)
            topInset + 20
            #else
            topInset + 64
            #endif
        }()
        let contentBottomPadding: CGFloat = {
            #if os(tvOS)
            40
            #elseif os(macOS)
            Self.macBottomPadding
            #else
            // Sit the title block lower so it reads over the background fade
            // rather than the busier middle of the artwork — easier to read,
            // especially the dark text in Light mode.
            14
            #endif
        }()
        let titleArtworkHeight: CGFloat = {
            // Match the home cinematic hero's title-logo size so the clear-logo
            // reads at the same scale on detail pages as in the home carousel
            // (HomeCinematicHeroLayout.titleLogoMaxHeight: 124 tvOS / 108 iOS).
            #if os(tvOS)
            124
            #else
            108
            #endif
        }()

        let backdrop = ZStack {
            DetailHeroBackdrop(
                imageURL: backdropURL,
                height: heroHeight,
                keepsPreviousImageWhileLoading: keepsPreviousBackdropWhileLoading,
                blursImage: blursBackdrop
            )

            DuskHeroBackdropOverlay(style: .soft)
        }
        .frame(width: containerWidth, height: heroHeight, alignment: .leading)
        .duskHeroBackdropBottomFade()
        .offset(x: -backgroundLeadingInset)
        .allowsHitTesting(false)

        let content = heroContent(titleArtworkHeight: titleArtworkHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, contentBottomPadding)
            .padding(.top, contentTopPadding)

        #if os(tvOS)
        ZStack(alignment: .bottomLeading) {
            backdrop
            content
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        #elseif os(macOS)
        // Always a dark context, in Light mode too: the title block reads over
        // a dark scrim and the hero only fades into the page below it.
        content
            .environment(\.colorScheme, .dark)
            .frame(height: heroHeight)
            .frame(maxWidth: .infinity)
            .background(alignment: .leading) { macBackdrop }
        #else
        // A background, not a ZStack sibling: running under the side insets
        // (iPhone landscape, iPhone Duo's vertical bar) makes the backdrop
        // wider than the page, and as a sibling it widened the hero and pushed
        // the centered iPhone column off the safe area's center.
        content
            .frame(height: heroHeight)
            .frame(maxWidth: .infinity)
            .background(alignment: .leading) { backdrop }
        #endif
    }

    @ViewBuilder
    private func heroContent(titleArtworkHeight: CGFloat) -> some View {
        #if os(tvOS)
        tvOSHeroContent(titleArtworkHeight: titleArtworkHeight)
        #elseif os(macOS)
        macHeroContent
        #else
        if sizeClass == .regular {
            twoColumnHeroContent(titleArtworkHeight: titleArtworkHeight)
        } else {
            centeredHeroContent(titleArtworkHeight: titleArtworkHeight)
        }
        #endif
    }

    #if os(tvOS)
    // tvOS now drops the poster too: a left-aligned column (title, metadata) over
    // the backdrop with a single action row beneath it.
    @ViewBuilder
    private func tvOSHeroContent(titleArtworkHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                supertitle
                titleView(height: titleArtworkHeight, alignment: .leading)
                if let titleAccessory { titleAccessory }
                subtitle
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
        }
    }
    #else
    // iPhone: one centered column over the backdrop, no poster. The logo, title
    // and metadata are a single tightly-spaced text group; the actions sit a
    // step further down as their own group (same grouping tvOS uses).
    @ViewBuilder
    private func centeredHeroContent(titleArtworkHeight: CGFloat) -> some View {
        VStack(alignment: .center, spacing: 16) {
            VStack(alignment: .center, spacing: 8) {
                supertitle
                titleView(height: titleArtworkHeight, alignment: .center)
                if let titleAccessory { titleAccessory }
                subtitle
            }

            actions
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
    }

    // iPad: a two-column hero. The name artwork leads the top of the column at the
    // same width as the Play button. Below it the left column holds the metadata
    // then the Play button + secondary actions; the right column holds the synopsis
    // (for season/episode, preceded by the title + marker). The synopsis lines up
    // with the top of the Play button, so the title/marker sit above the button.
    //
    // Show/movie heroes use the clear-logo as their title (so it leads the left
    // column); season/episode heroes have a text title, so they lead with the show
    // logo and put the title + marker at the head of the right column.
    @ViewBuilder
    private func twoColumnHeroContent(titleArtworkHeight: CGFloat) -> some View {
        let columnWidth = detailHeroRegularPrimaryWidth

        if leadsWithTextTitle, titleArtworkURL == nil {
            HStack(alignment: .bottom, spacing: 36) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        titleView(height: titleArtworkHeight, alignment: .leading)
                        subtitle
                    }
                    actions
                }
                .frame(width: columnWidth, alignment: .leading)

                descriptionColumn
            }
        } else if titleArtworkURL != nil {
            // Show / Movie: the clear-logo is the title and leads the left column;
            // the synopsis sits on the right, level with the metadata under it.
            VStack(alignment: .leading, spacing: 18) {
                titleView(height: titleArtworkHeight, alignment: .leading, width: columnWidth)

                HStack(alignment: .top, spacing: 36) {
                    VStack(alignment: .leading, spacing: 16) {
                        subtitle
                        actions
                    }
                    .frame(width: columnWidth, alignment: .leading)

                    descriptionColumn
                }
            }
        } else {
            // Season / Episode: the show logo leads; the title + marker head the
            // right column, and the synopsis below them lines up with the top of
            // the Play button so it doesn't drop too low.
            VStack(alignment: .leading, spacing: 18) {
                supertitle

                HStack(alignment: .heroDescriptionTop, spacing: 36) {
                    VStack(alignment: .leading, spacing: 16) {
                        subtitle
                        actions
                            .alignmentGuide(.heroDescriptionTop) { $0[.top] }
                    }
                    .frame(width: columnWidth, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        titleView(height: titleArtworkHeight, alignment: .leading)
                        if let titleAccessory { titleAccessory }
                        descriptionColumn
                            .alignmentGuide(.heroDescriptionTop) { $0[.top] }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var descriptionColumn: some View {
        if let descriptionText, !descriptionText.isEmpty {
            #if os(macOS)
            // Readable line length, three lines, the rest behind "More".
            ExpandableSummaryText(
                text: descriptionText,
                title: title,
                collapsedLineLimit: 3,
                font: macIsWide ? .title3 : .body,
                lineSpacing: 2,
                foregroundStyle: Color.primary.opacity(0.82),
                allowsExpansion: false
            )
            .frame(maxWidth: MacUILayout.readableTextWidth * (macIsWide ? 1.2 : 1), alignment: .leading)
            #else
            ExpandableSummaryText(
                text: descriptionText,
                title: title,
                collapsedLineLimit: 8,
                allowsExpansion: false
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            #endif
        }
    }
    #endif

    #if os(macOS)
    /// Gap between the bottom of the title block and the hero's bottom edge;
    /// most of it is the fade into the page, so the text block stays on the
    /// dark scrim.
    static var macBottomPadding: CGFloat { 48 }
    /// The last stretch of the hero, where the artwork fades into the page.
    private static var macFadeHeight: CGFloat { 100 }

    /// Very wide windows (2000pt displays) step the hero's type and controls
    /// up one size so the text block doesn't shrink against the backdrop.
    private var macIsWide: Bool { containerWidth >= 1600 }

    /// Width of the metadata + actions column; the synopsis sits to its right.
    private var macLeadingColumnWidth: CGFloat { macIsWide ? 360 : 300 }

    /// Title artwork stays a fraction of the hero, so a small window still
    /// shows the actions above the fold.
    private var macLogoHeight: CGFloat {
        min(macIsWide ? 180 : 140, max(heroHeight * 0.18, 64))
    }

    /// One layout for every detail page: the title block (show logo
    /// supertitle, title art or text, season·episode marker), then metadata and
    /// actions on the left with the synopsis to their right at a readable
    /// width. Bottom-aligned over the backdrop.
    private var macHeroContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                supertitle
                titleView(height: macLogoHeight, alignment: .leading)
                    .frame(maxWidth: macIsWide ? 460 : 360, alignment: .leading)
                if let titleAccessory { titleAccessory }
            }

            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 16) {
                    subtitle
                    actions
                        .environment(\.detailHeroMacControlSize, macIsWide ? .extraLarge : .large)
                }
                .frame(width: macLeadingColumnWidth, alignment: .leading)

                descriptionColumn
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var macBackdrop: some View {
        let fadeStart = max(0, 1 - Self.macFadeHeight / max(heroHeight, 1))
        let fadeSpan = 1 - fadeStart
        return ZStack {
            DetailHeroBackdrop(
                imageURL: backdropURL,
                height: heroHeight,
                keepsPreviousImageWhileLoading: keepsPreviousBackdropWhileLoading,
                blursImage: blursBackdrop
            )
            MacDetailHeroScrim(fadeStart: fadeStart)
        }
        .environment(\.colorScheme, .dark)
        .frame(width: containerWidth, height: heroHeight, alignment: .leading)
        // Fade the dark hero into the page background with a mask (the page
        // fill is the only colour at the seam). Eased, and only below the
        // text block, so Light mode gets a soft ramp rather than a band.
        .mask {
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: fadeStart),
                    .init(color: .black.opacity(0.9), location: fadeStart + fadeSpan * 0.2),
                    .init(color: .black.opacity(0.62), location: fadeStart + fadeSpan * 0.45),
                    .init(color: .black.opacity(0.28), location: fadeStart + fadeSpan * 0.7),
                    .init(color: .black.opacity(0.07), location: fadeStart + fadeSpan * 0.88),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .offset(x: -backgroundLeadingInset)
        .allowsHitTesting(false)
    }
    #endif

    // `width` (iPad) sizes the artwork to a fixed width so it fills to the Play
    // button's width; without it the logo is height-bound and centered/leading.
    @ViewBuilder
    private func titleView(height: CGFloat, alignment: Alignment, width: CGFloat? = nil) -> some View {
        if let titleArtworkURL {
            DuskAsyncImage(url: titleArtworkURL) { phase in
                switch phase {
                case let .success(image):
                    let art = image
                        .resizable()
                        .scaledToFit()
                        .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
                    if let width {
                        art.frame(width: width, alignment: alignment)
                    } else {
                        art.frame(maxWidth: .infinity, maxHeight: height, alignment: alignment)
                    }
                case .empty:
                    if let width {
                        Color.clear.frame(width: width, height: height)
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: alignment)
                    }
                case .failure:
                    titleFallback(alignment: alignment)
                }
            }
        } else {
            titleFallback(alignment: alignment)
        }
    }

    private func titleFallback(alignment: Alignment) -> some View {
        Text(title)
            #if os(macOS)
            .font(.largeTitle.bold())
            #else
            .font(DuskFont.heroTitle(ios: .title2.bold()))
            #endif
            // Soft near-black/near-white instead of pure `Color.primary` so the
            // title reads as a gentler grey, not harsh black, in Light mode.
            .foregroundStyle(Color.duskTextPrimary)
            .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
            .multilineTextAlignment(alignment == .center ? .center : .leading)
            .lineLimit(titleLineLimit)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: alignment)
            .layoutPriority(1)
    }
}

#if os(macOS)
/// The Mac movie/episode pages' "Information" section, laid out like the TV
/// app's: a grid of labelled cells (Video, Audio, Subtitles, File), each a
/// small semibold label above secondary values.
struct DetailMacMediaSection: View {
    let media: PlexMedia?

    private struct Cell: Identifiable {
        let label: String
        let lines: [String]
        var id: String { label }
    }

    var body: some View {
        let cells = media.map(Self.cells(for:)) ?? []
        if !cells.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Information")
                    .font(DuskFont.sectionHeader(ios: .headline))
                    .foregroundStyle(Color.primary)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190, maximum: 300), spacing: 32, alignment: .topLeading)],
                    alignment: .leading,
                    spacing: 20
                ) {
                    ForEach(cells) { cell in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(cell.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.primary)
                            Text(cell.lines.joined(separator: "\n"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .accessibilityElement(children: .combine)
                    }
                }
                .textSelection(.enabled)
            }
        }
    }

    private static func cells(for media: PlexMedia) -> [Cell] {
        let part = media.firstAvailablePart
        let streams = part?.streams ?? []
        var cells: [Cell] = []

        let video = streams.first { $0.streamType == .video }
        let videoLines = [
            resolutionLine(media: media, stream: video),
            [media.videoCodec.map(videoCodec), video?.frameRate.map(frameRate)]
                .compactMap { $0 }.joined(separator: " · "),
            video.flatMap(dynamicRange),
        ].compactMap { $0 }.filter { !$0.isEmpty }
        if !videoLines.isEmpty { cells.append(Cell(label: "Video", lines: videoLines)) }

        let audio = streams.filter { $0.streamType == .audio }.map(trackTitle)
        let audioLines = audio.isEmpty
            ? [[media.audioCodec.map(audioCodec), media.audioChannels.map(channels)].compactMap { $0 }.joined(separator: " ")]
            : audio
        if let lines = capped(audioLines.filter { !$0.isEmpty }) {
            cells.append(Cell(label: "Audio", lines: lines))
        }

        if let lines = capped(streams.filter { $0.streamType == .subtitle }.map(trackTitle)) {
            cells.append(Cell(label: "Subtitles", lines: lines))
        }

        let fileLines = [
            (part?.container ?? media.container).map { $0.uppercased() },
            part?.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) },
            media.bitrate.map(bitrate),
        ].compactMap { $0 }
        if !fileLines.isEmpty { cells.append(Cell(label: "File", lines: fileLines)) }

        return cells
    }

    /// At most four tracks, then "and N more".
    private static func capped(_ lines: [String]) -> [String]? {
        guard !lines.isEmpty else { return nil }
        guard lines.count > 4 else { return lines }
        return Array(lines.prefix(3)) + ["and \(lines.count - 3) more"]
    }

    private static func trackTitle(_ stream: PlexStream) -> String {
        stream.displayTitle ?? stream.language ?? stream.codec?.uppercased() ?? "Unknown"
    }

    private static func resolutionLine(media: PlexMedia, stream: PlexStream?) -> String? {
        let name = media.videoResolution.map(resolution)
        let width = stream?.width ?? media.width
        let height = stream?.height ?? media.height
        let size = width.flatMap { w in height.map { "\(w)×\($0)" } }
        switch (name, size) {
        case let (name?, size?): return "\(name) (\(size))"
        case let (name?, nil): return name
        case let (nil, size?): return size
        default: return nil
        }
    }

    private static func frameRate(_ value: Double) -> String {
        let rounded = (value * 1000).rounded() / 1000
        return rounded.formatted(.number.precision(.fractionLength(0...3))) + " fps"
    }

    private static func dynamicRange(_ stream: PlexStream) -> String? {
        if stream.doviPresent == true { return "Dolby Vision" }
        switch stream.colorTrc?.lowercased() {
        case "smpte2084": return "HDR10"
        case "arib-std-b67": return "HLG"
        default: return nil
        }
    }

    private static func bitrate(_ kbps: Int) -> String {
        kbps >= 1000
            ? (Double(kbps) / 1000).formatted(.number.precision(.fractionLength(1))) + " Mbps"
            : "\(kbps) kbps"
    }

    private static func resolution(_ value: String) -> String {
        let lower = value.lowercased()
        if lower == "4k" { return "4K" }
        if lower == "sd" { return "SD" }
        if Int(lower) != nil { return lower + "p" }
        return value.uppercased()
    }

    private static func videoCodec(_ value: String) -> String {
        switch value.lowercased() {
        case "h264", "avc", "avc1": "H.264"
        case "hevc", "h265", "hvc1", "hev1": "HEVC"
        case "mpeg2video", "mpeg2": "MPEG-2"
        case "mpeg4": "MPEG-4"
        case "vc1": "VC-1"
        case "vp9": "VP9"
        case let codec where StreamResolver.isAV1Codec(codec.uppercased()): "AV1"
        default: value.uppercased()
        }
    }

    private static func audioCodec(_ value: String) -> String {
        switch value.lowercased() {
        case "aac": "AAC"
        case "ac3": "AC-3"
        case "eac3": "E-AC-3"
        case "truehd": "TrueHD"
        case "dca", "dts": "DTS"
        case "flac": "FLAC"
        case "mp3": "MP3"
        case "opus": "Opus"
        case "vorbis": "Vorbis"
        case "pcm": "PCM"
        default: value.uppercased()
        }
    }

    private static func channels(_ count: Int) -> String {
        switch count {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 7: "6.1"
        case 8: "7.1"
        default: "\(count) ch"
        }
    }
}

/// The Mac detail hero's dark scrim: a light darkening under the toolbar, a
/// strong leading wash behind the title column, a bottom-leading pool behind
/// the metadata and actions (busy, bright art), and a bottom darkening that
/// peaks where the fade into the page starts. Black only, so the hero reads
/// the same in Light and Dark mode.
private struct MacDetailHeroScrim: View {
    /// Where the hero starts fading into the page (fraction of its height).
    var fadeStart: CGFloat = 1

    var body: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.35), location: 0),
                    .init(color: .black.opacity(0), location: 0.22),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.78), location: 0),
                    .init(color: .black.opacity(0.48), location: 0.34),
                    .init(color: .black.opacity(0.12), location: 0.68),
                    .init(color: .black.opacity(0), location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            EllipticalGradient(
                stops: [
                    .init(color: .black.opacity(0.5), location: 0),
                    .init(color: .black.opacity(0.32), location: 0.45),
                    .init(color: .black.opacity(0), location: 1),
                ],
                center: .bottomLeading,
                startRadiusFraction: 0,
                endRadiusFraction: 0.75
            )
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0), location: max(0, fadeStart - 0.6)),
                    .init(color: .black.opacity(0.55), location: max(0, fadeStart - 0.2)),
                    .init(color: .black.opacity(0.8), location: fadeStart),
                    // Eases off inside the fade, so the hero's tail melts
                    // into the page instead of ending in a near-black band.
                    .init(color: .black.opacity(0.45), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .allowsHitTesting(false)
    }
}
#endif

extension DetailHeroSection where Supertitle == EmptyView {
    init(
        backdropURL: URL?,
        blursBackdrop: Bool = false,
        titleArtworkURL: URL? = nil,
        title: String,
        descriptionText: String? = nil,
        topInset: CGFloat,
        containerWidth: CGFloat,
        backgroundLeadingInset: CGFloat = 0,
        heroBaseHeight: CGFloat = 380,
        keepsPreviousBackdropWhileLoading: Bool = false,
        titleLineLimit: Int = 2,
        titleAccessory: AnyView? = nil,
        leadsWithTextTitle: Bool = false,
        @ViewBuilder subtitle: () -> Subtitle,
        @ViewBuilder actions: () -> Actions
    ) {
        self.backdropURL = backdropURL
        self.blursBackdrop = blursBackdrop
        self.titleArtworkURL = titleArtworkURL
        self.title = title
        self.descriptionText = descriptionText
        self.topInset = topInset
        self.containerWidth = containerWidth
        self.backgroundLeadingInset = backgroundLeadingInset
        self.heroBaseHeight = heroBaseHeight
        self.keepsPreviousBackdropWhileLoading = keepsPreviousBackdropWhileLoading
        self.titleLineLimit = titleLineLimit
        self.titleAccessory = titleAccessory
        self.leadsWithTextTitle = leadsWithTextTitle
        self.supertitle = EmptyView()
        self.subtitle = subtitle()
        self.actions = actions()
    }
}

struct MovieCopyVersionMenu: View {
    let versions: [MoviePlaybackVersion]
    let onSelect: (MoviePlaybackVersion) -> Void

    var body: some View {
        if !versions.isEmpty {
            Menu {
                ForEach(versions) { version in
                    Button(version.label) { onSelect(version) }
                }
            } label: {
                Label("Play Version", systemImage: "play.square")
            }
        }
    }
}

struct PlayVersionContextMenu: View {
    let versions: [PlexMedia]
    let onSelectVersion: (PlexMedia) -> Void

    var body: some View {
        if !playableVersions.isEmpty {
            Menu {
                ForEach(playableVersions) { version in
                    Button {
                        onSelectVersion(version)
                    } label: {
                        Text(MediaTextFormatter.playbackVersionMenuLabel(version))
                    }
                }
            } label: {
                Label("Play Version", systemImage: "play.square")
            }
        }
    }

    private var playableVersions: [PlexMedia] {
        versions.filter { !$0.parts.isEmpty }
    }
}

extension View {
    /// Presents the "Download Subtitles" (OpenSubtitles via Plex) flow the way
    /// each platform expects: a detented sheet on iOS/iPadOS, a full-screen
    /// cover on tvOS where sheets and context menus are awkward.
    func detailSubtitleSearchPresentation(
        isPresented: Binding<Bool>,
        viewModel: @escaping () -> SubtitleSearchViewModel
    ) -> some View {
        #if os(tvOS)
        fullScreenCover(isPresented: isPresented) {
            SubtitleSearchView(viewModel: viewModel()) { isPresented.wrappedValue = false }
        }
        #elseif os(macOS)
        sheet(isPresented: isPresented) {
            SubtitleSearchView(viewModel: viewModel()) { isPresented.wrappedValue = false }
                .macUISheetSize(idealHeight: 620)
        }
        #else
        sheet(isPresented: isPresented) {
            SubtitleSearchView(viewModel: viewModel()) { isPresented.wrappedValue = false }
        }
        #endif
    }
}

/// Icon-only secondary action label for detail heroes. Pairs with
/// `detailHeroNativeSecondaryButtonStyle()` to make a compact glass icon button
/// (a capsule pill on iOS, a circle on tvOS) without crowding the row with text.
///
/// On tvOS the focused button grows into icon + `title` so the row can be read
/// (issue #72); unfocused buttons stay round. The row is leading-aligned, so the
/// growth only pushes the buttons to its right and Play never moves. iOS ignores
/// `title` and stays icon-only.
struct DetailHeroSecondaryIconLabel: View {
    let systemImage: String
    var title: String? = nil

    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #elseif os(macOS)
    @Environment(\.detailHeroMacControlSize) private var macControlSize
    #endif

    var body: some View {
        #if os(tvOS)
        HStack(spacing: 0) {
            icon
                .frame(width: iconMinHeight, height: iconMinHeight)
            if showsTitle, let title {
                Text(title)
                    .font(DuskFont.buttonLabel(ios: .headline))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, 12)
                    .transition(.opacity)
            }
        }
        // The capsule glass pads ~12pt more horizontally than vertically; give
        // that back while icon-only so the unfocused button is a true circle.
        // Height stays pinned to the icon so the row never grows vertically.
        .padding(.horizontal, showsTitle ? 0 : -Self.tvCircleInset)
        .frame(height: iconMinHeight)
        .contentShape(Capsule())
        .animation(.smooth(duration: 0.28), value: showsTitle)
        #elseif os(macOS)
        // A fixed square glyph box, so every secondary (buttons and the Rate
        // menu) is the same circle under `.buttonBorderShape(.circle)`.
        let isLarge = macControlSize == .extraLarge
        Image(systemName: systemImage)
            .font(.system(size: isLarge ? 15 : 13, weight: .semibold))
            .frame(
                width: detailHeroMacSecondaryGlyphBox + (isLarge ? 4 : 0),
                height: detailHeroMacSecondaryGlyphBox + (isLarge ? 4 : 0)
            )
            // Full contrast, active window or not, like the download button.
            .foregroundStyle(Color.primary)
            .contentShape(Circle())
            .help(title ?? "")
        #else
        icon
            .frame(minWidth: iconMinWidth, minHeight: iconMinHeight)
            .contentShape(Capsule())
        #endif
    }

    private var icon: some View {
        Image(systemName: systemImage)
            .font(DuskFont.buttonLabel(ios: .subheadline.weight(.semibold)))
            // Slimmer than tall on iOS, where the secondaries sit in a capsule
            // row; tvOS pins it to a square in `body`.
            .frame(minWidth: iconMinWidth, minHeight: iconMinHeight)
    }

    #if os(tvOS)
    private var showsTitle: Bool { isFocused && title != nil }

    /// Horizontal minus vertical content inset of the tvOS `.glass` capsule
    /// button, measured from simulator screenshots (30pt vs 18pt).
    private static let tvCircleInset: CGFloat = 12
    #endif

    private var iconMinWidth: CGFloat {
        #if os(tvOS)
        // Kept equal to `iconMinHeight` — the unfocused tvOS button is a circle
        // and goes oval the moment these diverge.
        iconMinHeight
        #else
        24
        #endif
    }

    private var iconMinHeight: CGFloat {
        #if os(tvOS)
        30
        #else
        32
        #endif
    }
}

#if os(macOS)
/// Side of the square glyph box in a Mac hero secondary button; with the
/// `.large` glass circle's padding the button is ~32pt across.
let detailHeroMacSecondaryGlyphBox: CGFloat = 18

extension EnvironmentValues {
    /// Control size of the Mac detail hero's buttons: `.large`, one step up
    /// in very wide windows (`DetailHeroSection`).
    @Entry var detailHeroMacControlSize: ControlSize = .large
}

/// Applies `detailHeroMacControlSize` to a hero button.
private struct DetailHeroMacControlSizing: ViewModifier {
    @Environment(\.detailHeroMacControlSize) private var size

    func body(content: Content) -> some View {
        content.controlSize(size)
    }
}
#endif

struct DetailHeroPrimaryActionButtonLabel: View {
    let title: String
    let systemImage: String
    var fillsWidth: Bool = false

    #if os(macOS)
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.detailHeroMacControlSize) private var macControlSize
    #endif

    var body: some View {
        #if os(macOS)
        // Hugs its label at the Mac's large control size. On the white
        // prominent platter the label is black; in an inactive window the
        // platter loses its fill, so the label goes back to `primary` (white
        // in the hero's dark context) and stays legible.
        Label(title, systemImage: systemImage)
            .font((macControlSize == .extraLarge ? Font.title3 : .body).weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .foregroundStyle(controlActiveState == .inactive ? Color.primary : Color.black)
        #else
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(DuskFont.buttonLabel(ios: .headline.weight(.semibold)))

            Text(title)
                .font(DuskFont.buttonLabel(ios: .headline))
                .lineLimit(1)
        }
        .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: detailHeroActionLabelMinHeight)
        #if os(tvOS)
        // tvOS is left-aligned, so give the primary a contained width (space to its
        // right) rather than letting it hug the short "Play" / "Resume" label.
        // No label color: the system glass flips it between light (unfocused) and
        // dark (focused, on the white platter) by itself.
        .frame(minWidth: detailHeroTVActionLabelMinWidth)
        #else
        // The iOS primary fills with a translucent-`primary` prominent glass, so
        // the label uses the inverse color to stay legible on it.
        .foregroundStyle(Color.duskPrimaryActionLabel)
        #endif
        .contentShape(Capsule())
        #endif
    }
}

struct DetailHeroStatusActionLabel: View {
    let title: String
    let systemImage: String
    var fillsWidth: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(DuskFont.buttonLabel(ios: .headline.weight(.semibold)))

            Text(title)
                .font(DuskFont.buttonLabel(ios: .headline))
                .lineLimit(1)
        }
        .foregroundStyle(Color.duskTextPrimary)
        .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: detailHeroActionLabelMinHeight)
        #if os(tvOS)
        .frame(minWidth: detailHeroTVActionLabelMinWidth)
        #endif
        .padding(.horizontal, 20)
        .padding(.vertical, 5)
        .background(Color.duskSurface.opacity(0.86), in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.duskTextSecondary.opacity(0.18), lineWidth: 1)
        }
    }
}

extension View {
    @ViewBuilder
    func detailHeroNativePrimaryButtonStyle() -> some View {
        #if os(tvOS)
        // Plain system glass, like the TV app: a dark platter that lifts to white
        // with a dark label on focus. No tint: any explicit colour (even
        // `.primary`) recolours the label too and goes white-on-white on focus.
        self
            .buttonStyle(.glass)
            .controlSize(.regular)
            .buttonBorderShape(.capsule)
        #elseif os(iOS)
        // Prominent glass tinted with a *translucent* `primary`: a contrasting lean
        // (dark in Light mode, light in Dark) that still reads as liquid glass rather
        // than a solid black/white fill. `.regular` height keeps it compact.
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glassProminent)
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
                .tint(Color.duskPrimaryButtonTint)
        } else {
            self
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
                .tint(Color.primary)
        }
        #elseif os(macOS)
        // The TV app's white Play platter over the (always dark) hero, at the
        // Mac's large control size, hugging its label.
        self
            .buttonStyle(.glassProminent)
            .modifier(DetailHeroMacControlSizing())
            .buttonBorderShape(.capsule)
            .tint(.white)
        #else
        self
        #endif
    }

    @ViewBuilder
    func detailHeroNativeSecondaryButtonStyle() -> some View {
        #if os(tvOS)
        // tvOS secondaries are icon-only and sit beside the primary. A capsule
        // around the square icon label reads as a circle, and stretches into a
        // pill when the focused label reveals its title. No tint, same as the
        // primary.
        self
            .buttonStyle(.glass)
            .controlSize(.regular)
            .buttonBorderShape(.capsule)
        #elseif os(iOS)
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
                .tint(Color.primary)
        } else {
            self
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
                .tint(Color.primary)
        }
        #elseif os(macOS)
        // One shape for every secondary: an untinted glass circle around the
        // fixed glyph box of `DetailHeroSecondaryIconLabel`. The Rate menu
        // renders as the same button (no indicator).
        self
            .buttonStyle(.glass)
            .modifier(DetailHeroMacControlSizing())
            .buttonBorderShape(.circle)
            .menuStyle(.button)
            .menuIndicator(.hidden)
        #else
        self
        #endif
    }

    /// Sizes and aligns the stacked iOS detail hero action block so the primary
    /// button and the secondary row underneath share a single width. iPhone uses
    /// ~60% of the screen, centered; iPad/regular uses a capped width, leading
    /// aligned in the hero text column. No-op on tvOS, which keeps its inline row.
    @ViewBuilder
    func detailHeroActionStackFrame(isCompactPhone: Bool) -> some View {
        #if os(iOS)
        if isCompactPhone {
            self
                .containerRelativeFrame(.horizontal) { width, _ in
                    max(width * detailHeroCompactActionWidthFraction, 0)
                }
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            self
                .frame(maxWidth: detailHeroRegularPrimaryWidth, alignment: .leading)
        }
        #elseif os(macOS)
        // The primary hugs its label; the stack sits leading in the hero column.
        self
            .fixedSize(horizontal: true, vertical: false)
        #else
        self
        #endif
    }
}

/// Fraction of the hero (screen) width the iPhone primary action button spans.
let detailHeroCompactActionWidthFraction: CGFloat = 0.6

/// Shared width on iPad/regular for the primary action button and the title
/// artwork, so the logo reads at roughly the same width as the Play button
/// beneath it rather than filling the whole column.
let detailHeroRegularPrimaryWidth: CGFloat = 260

// MARK: - Actor Credit Card

struct ActorCreditCard: View {
    let person: PlexPersonReference
    /// The server this credit was read from; the person's page and avatar both
    /// have to be fetched from it, because person ids are per-server tag ids.
    let serverID: String?
    let plexService: PlexService
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        #if os(tvOS)
        let avatarSize: CGFloat = 144
        let cardWidth: CGFloat = 156
        let avatarTextSpacing: CGFloat = 14
        let artworkShape = RoundedRectangle(cornerRadius: PosterArtwork.cornerRadius, style: .continuous)

        VStack(alignment: .leading, spacing: avatarTextSpacing) {
            NavigationLink(value: AppNavigationRoute.person(person, serverID: serverID)) {
                avatarImage(size: avatarSize)
            }
            .duskSuppressTVOSButtonChrome()
            .focused($isFocused)
            .duskTVOSFocusEffectShape(artworkShape, scales: false)
            .accessibilityLabel(accessibilityLabel)
            .frame(width: avatarSize, height: avatarSize)

            personDetails(width: avatarSize)
        }
        .frame(width: cardWidth, alignment: .topLeading)
        .duskTVOSFocusedScale(isFocused)
        .zIndex(isFocused ? 1 : 0)
        #else
        NavigationLink(value: AppNavigationRoute.person(person, serverID: serverID)) {
            VStack(spacing: 8) {
                avatarImage(size: 72)
                personDetails(width: 80)
            }
            .frame(width: 80)
        }
        .buttonStyle(.plain)
        .duskSuppressTVOSButtonChrome()
        #endif
    }

    @ViewBuilder
    private func avatarImage(size: CGFloat) -> some View {
        let imageSize = Int(size.rounded())
        let artworkShape = RoundedRectangle(cornerRadius: PosterArtwork.cornerRadius, style: .continuous)

        Group {
            if let thumbPath = person.thumb {
                DuskAsyncImage(url: plexService.imageURL(for: thumbPath, serverID: serverID, width: imageSize, height: imageSize)) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        placeholder(size: size)
                    }
                }
            } else {
                placeholder(size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(artworkShape)
        .contentShape(artworkShape)
    }

    private func placeholder(size: CGFloat) -> some View {
        ZStack {
            Color.duskSurface

            Image(systemName: "person.fill")
                .font(.system(size: size * 0.30, weight: .regular))
                .foregroundStyle(Color.duskTextSecondary)
        }
    }

    private func personDetails(width: CGFloat) -> some View {
        VStack(spacing: 2) {
            Text(person.name)
                .font(DuskFont.cardSubtitle(ios: .caption))
                .foregroundStyle(Color.primary)
                .lineLimit(1)

            if let roleName = person.roleName, !roleName.isEmpty {
                Text(roleName)
                    .font(DuskFont.cardSubtitle(ios: .caption2))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .lineLimit(1)
            }
        }
        .frame(width: width)
    }

    private var accessibilityLabel: String {
        if let roleName = person.roleName, !roleName.isEmpty {
            return "View \(person.name), \(roleName)"
        }

        return "View \(person.name)"
    }
}

struct DetailCastSection: View {
    let roles: [PlexRole]
    /// The server the item's metadata came from; its cast lives there too.
    let serverID: String?
    let plexService: PlexService
    var title = "Cast"
    var horizontalPadding: CGFloat = DuskPosterMetrics.detailHorizontalPadding
    var maxVisibleRoles = 20

    var body: some View {
        #if os(tvOS)
        let castSpacing: CGFloat = 24
        let castVerticalPadding: CGFloat = 12
        let headerSpacing: CGFloat = 10
        #else
        let castSpacing: CGFloat = 12
        let castVerticalPadding: CGFloat = 0
        let headerSpacing: CGFloat = 12
        #endif

        VStack(alignment: .leading, spacing: headerSpacing) {
            Text(title)
                .font(DuskFont.sectionHeader(ios: .headline))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, horizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: castSpacing) {
                    ForEach(Array(roles.prefix(maxVisibleRoles).enumerated()), id: \.offset) { _, role in
                        ActorCreditCard(
                            person: PlexPersonReference(role: role),
                            serverID: serverID,
                            plexService: plexService
                        )
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, castVerticalPadding)
            }
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }
}
