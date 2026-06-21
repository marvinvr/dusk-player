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
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.duskAccent)

            Text(message)
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.duskAccent.opacity(0.22), lineWidth: 1)
        )
    }
}

/// The show-title header shown in the season and episode detail heroes: the
/// show's clear-logo art (centered) when Plex provides it, falling back to the
/// show name, and wrapped in a link to the show so it doubles as navigation.
/// tvOS keeps the plain accent text — the image treatment is iOS-only.
struct DetailHeroShowTitleLink: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    let title: String
    let logoURL: URL?
    let showRoute: AppNavigationRoute?

    // This is the show logo in its subordinate *supertitle* role (above a
    // season/episode text title), so it stays intentionally smaller than the
    // hero's main title artwork (`DetailHeroSection.titleArtworkHeight`).
    private var logoHeight: CGFloat {
        sizeClass == .regular ? 68 : 60
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
                    if sizeClass == .regular {
                        // iPad: fill the column width so it matches the Play button.
                        art.frame(width: detailHeroRegularPrimaryWidth, alignment: contentAlignment)
                    } else {
                        art
                            .frame(maxHeight: logoHeight)
                            .frame(maxWidth: .infinity, alignment: contentAlignment)
                    }
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
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.duskAccent)
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
    @ViewBuilder var supertitle: Supertitle
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var actions: Actions

    init(
        backdropURL: URL?,
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
        @ViewBuilder supertitle: () -> Supertitle,
        @ViewBuilder subtitle: () -> Subtitle,
        @ViewBuilder actions: () -> Actions
    ) {
        self.backdropURL = backdropURL
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
        self.supertitle = supertitle()
        self.subtitle = subtitle()
        self.actions = actions()
    }

    private var heroHeight: CGFloat { heroBaseHeight + topInset }

    var body: some View {
        let horizontalPadding: CGFloat = {
            #if os(tvOS)
            DuskPosterMetrics.detailHorizontalPadding
            #else
            20
            #endif
        }()
        let contentTopPadding: CGFloat = {
            #if os(tvOS)
            topInset + 80
            #else
            topInset + 64
            #endif
        }()
        let contentBottomPadding: CGFloat = {
            #if os(tvOS)
            40
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

        ZStack(alignment: .bottomLeading) {
            ZStack {
                DetailHeroBackdrop(
                    imageURL: backdropURL,
                    height: heroHeight,
                    keepsPreviousImageWhileLoading: keepsPreviousBackdropWhileLoading
                )

                DuskHeroBackdropOverlay(style: .soft)
            }
            .frame(width: containerWidth, height: heroHeight, alignment: .leading)
            .duskHeroBackdropBottomFade()
            .offset(x: -backgroundLeadingInset)
            .allowsHitTesting(false)

            heroContent(titleArtworkHeight: titleArtworkHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(.horizontal, horizontalPadding)
                .padding(.bottom, contentBottomPadding)
                .padding(.top, contentTopPadding)
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func heroContent(titleArtworkHeight: CGFloat) -> some View {
        #if os(tvOS)
        tvOSHeroContent(titleArtworkHeight: titleArtworkHeight)
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
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
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

        if titleArtworkURL != nil {
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
            ExpandableSummaryText(
                text: descriptionText,
                collapsedLineLimit: 8,
                allowsExpansion: false
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            .font(.title2.bold())
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

extension DetailHeroSection where Supertitle == EmptyView {
    init(
        backdropURL: URL?,
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
        @ViewBuilder subtitle: () -> Subtitle,
        @ViewBuilder actions: () -> Actions
    ) {
        self.backdropURL = backdropURL
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
        self.supertitle = EmptyView()
        self.subtitle = subtitle()
        self.actions = actions()
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

/// Icon-only secondary action label for detail heroes. Pairs with
/// `detailHeroNativeSecondaryButtonStyle()` to make a compact glass icon button
/// (a capsule pill on iOS, a circle on tvOS) without crowding the row with text.
struct DetailHeroSecondaryIconLabel: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.subheadline.weight(.semibold))
            // Square on tvOS so the circular button reads as round; a slimmer pill
            // on iOS where the secondaries sit in a capsule row.
            .frame(minWidth: iconMinWidth, minHeight: 32)
            .contentShape(Capsule())
    }

    private var iconMinWidth: CGFloat {
        #if os(tvOS)
        32
        #else
        24
        #endif
    }
}

struct DetailHeroPrimaryActionButtonLabel: View {
    let title: String
    let systemImage: String
    var fillsWidth: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))

            Text(title)
                .font(.headline)
                .lineLimit(1)
        }
        .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 34)
        #if os(tvOS)
        // tvOS is left-aligned, so give the primary a contained width (space to its
        // right) rather than letting it hug the short "Play" / "Resume" label.
        .frame(minWidth: 260)
        #endif
        // The primary fills with a translucent-`primary` prominent glass on every
        // platform, so the label uses the inverse color to stay legible on it.
        .foregroundStyle(Color.duskPrimaryActionLabel)
        .contentShape(Capsule())
    }
}

extension View {
    @ViewBuilder
    func detailHeroNativePrimaryButtonStyle() -> some View {
        #if os(tvOS)
        // A fully custom style so the fill *and* label colors are ours in both the
        // focused and unfocused states. The system `.glassProminent` focus highlight
        // forces the fill and label to white when focused — white-on-white in Dark
        // mode, and a fill that flips to white in Light mode (it should stay dark).
        // Here the capsule keeps its translucent-`primary` lean (white in Dark, black
        // in Light) and the label keeps its inverse, focused or not; focus only adds
        // the app's standard scale + glow.
        self.buttonStyle(DetailHeroPrimaryTVButtonStyle())
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
        #else
        self
        #endif
    }

    @ViewBuilder
    func detailHeroNativeSecondaryButtonStyle() -> some View {
        #if os(tvOS)
        // tvOS secondaries are icon-only and sit beside the primary, so make them
        // round — there is no width to match.
        self
            .buttonStyle(.glass)
            .controlSize(.regular)
            .buttonBorderShape(.circle)
            .tint(Color.primary)
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
        #else
        self
        #endif
    }
}

#if os(tvOS)
/// tvOS play button. A custom `ButtonStyle` so the capsule fill and the label
/// color are ours in both the focused and unfocused states — the system
/// `.glassProminent` focus highlight otherwise forces both to white, which reads
/// as white-on-white in Dark mode and turns the Light-mode fill white when it
/// should stay dark. The capsule keeps the same translucent-`primary` lean (white
/// in Dark, black in Light) regardless of focus, and the label keeps its inverse
/// (`duskPrimaryActionLabel`); focus only adds the app's standard scale + glow.
private struct DetailHeroPrimaryTVButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration)
    }

    private struct Content: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isFocused) private var isFocused

        var body: some View {
            configuration.label
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .glassEffect(.regular.tint(Color.duskPrimaryButtonTint), in: Capsule())
                .scaleEffect(isFocused ? 1.05 : 1.0)
                .shadow(
                    color: isFocused ? Color.white.opacity(0.34) : .clear,
                    radius: isFocused ? 16 : 0,
                    y: isFocused ? 6 : 0
                )
                .opacity(configuration.isPressed ? 0.86 : 1.0)
                .animation(.easeOut(duration: 0.18), value: isFocused)
        }
    }
}
#endif

/// Fraction of the hero (screen) width the iPhone primary action button spans.
let detailHeroCompactActionWidthFraction: CGFloat = 0.6

/// Shared width on iPad/regular for the primary action button and the title
/// artwork, so the logo reads at roughly the same width as the Play button
/// beneath it rather than filling the whole column.
let detailHeroRegularPrimaryWidth: CGFloat = 260

// MARK: - Actor Credit Card

struct ActorCreditCard: View {
    let person: PlexPersonReference
    let plexService: PlexService
    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        #if os(tvOS)
        let avatarSize: CGFloat = 144
        let cardWidth: CGFloat = 156
        let avatarTextSpacing: CGFloat = 28
        let artworkShape = RoundedRectangle(cornerRadius: PosterArtwork.cornerRadius, style: .continuous)

        VStack(alignment: .leading, spacing: avatarTextSpacing) {
            NavigationLink(value: AppNavigationRoute.person(person)) {
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
        NavigationLink(value: AppNavigationRoute.person(person)) {
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
                DuskAsyncImage(url: plexService.imageURL(for: thumbPath, width: imageSize, height: imageSize)) { phase in
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
                .font(.caption)
                .foregroundStyle(Color.primary)
                .lineLimit(1)

            if let roleName = person.roleName, !roleName.isEmpty {
                Text(roleName)
                    .font(.caption2)
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
    let plexService: PlexService
    var title = "Cast"
    var horizontalPadding: CGFloat = DuskPosterMetrics.detailHorizontalPadding
    var maxVisibleRoles = 20

    var body: some View {
        #if os(tvOS)
        let castSpacing: CGFloat = 28
        let castVerticalPadding: CGFloat = 12
        #else
        let castSpacing: CGFloat = 12
        let castVerticalPadding: CGFloat = 0
        #endif

        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.primary)
                .padding(.horizontal, horizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: castSpacing) {
                    ForEach(Array(roles.prefix(maxVisibleRoles).enumerated()), id: \.offset) { _, role in
                        ActorCreditCard(person: PlexPersonReference(role: role), plexService: plexService)
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

struct ExpandableSummaryText: View {
    let text: String
    var collapsedLineLimit = 9
    var foregroundStyle = Color.primary.opacity(0.76)
    var allowsExpansion = true

    @State private var isExpanded = false
    @State private var collapsedHeight: CGFloat = 0
    @State private var expandedHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.body)
                .foregroundStyle(foregroundStyle)
                .lineSpacing(4)
                .lineLimit(isExpanded ? nil : collapsedLineLimit)
                .truncationMode(.tail)
                .overlay(alignment: .topLeading) {
                    ZStack {
                        measurementText(lineLimit: collapsedLineLimit) { height in
                            collapsedHeight = height
                        }

                        measurementText(lineLimit: nil) { height in
                            expandedHeight = height
                        }
                    }
                    .hidden()
                    .allowsHitTesting(false)
                }

            if allowsExpansion, isExpandable {
                Button(isExpanded ? "Show Less" : "Show More") {
                    isExpanded.toggle()
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.duskAccent)
                .buttonStyle(.plain)
                .duskSuppressTVOSButtonChrome()
            }
        }
    }

    private var isExpandable: Bool {
        expandedHeight > collapsedHeight + 1
    }

    private func measurementText(
        lineLimit: Int?,
        onHeightChange: @escaping (CGFloat) -> Void
    ) -> some View {
        Text(text)
            .font(.body)
            .lineSpacing(4)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            onHeightChange(proxy.size.height)
                        }
                        .onChange(of: proxy.size.height) { _, newHeight in
                            onHeightChange(newHeight)
                        }
                }
            }
    }
}
