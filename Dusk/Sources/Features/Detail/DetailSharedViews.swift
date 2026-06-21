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
            28
            #endif
        }()
        let titleArtworkHeight: CGFloat = {
            #if os(tvOS)
            78
            #else
            sizeClass == .regular ? 68 : 60
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
                subtitle
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions
        }
    }
    #else
    // iPhone: one centered column over the backdrop, no poster.
    @ViewBuilder
    private func centeredHeroContent(titleArtworkHeight: CGFloat) -> some View {
        VStack(alignment: .center, spacing: 14) {
            supertitle
            titleView(height: titleArtworkHeight, alignment: .center)
            subtitle
            actions
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
    }

    // iPad: title artwork + actions on the left, marker / metadata / description
    // on the right, both reading off the shared backdrop (no poster).
    @ViewBuilder
    private func twoColumnHeroContent(titleArtworkHeight: CGFloat) -> some View {
        let leftColumnWidth = min(max(containerWidth * 0.34, 320), 440)

        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 18) {
                titleView(height: titleArtworkHeight, alignment: .leading)
                actions
            }
            .frame(width: leftColumnWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                supertitle
                subtitle

                if let descriptionText, !descriptionText.isEmpty {
                    ExpandableSummaryText(
                        text: descriptionText,
                        collapsedLineLimit: 7,
                        allowsExpansion: false
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    #endif

    @ViewBuilder
    private func titleView(height: CGFloat, alignment: Alignment) -> some View {
        if let titleArtworkURL {
            DuskAsyncImage(url: titleArtworkURL) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFit()
                        .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
                        .frame(maxWidth: .infinity, maxHeight: height, alignment: alignment)
                case .empty:
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: alignment)
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
            .foregroundStyle(Color.primary)
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
        // The primary button fills with `Color.primary` (prominent glass) on every
        // platform, so the label uses the inverse color to stay legible.
        .foregroundStyle(Color.duskPrimaryActionLabel)
        .contentShape(Capsule())
    }
}

extension View {
    @ViewBuilder
    func detailHeroNativePrimaryButtonStyle() -> some View {
        #if os(tvOS)
        // Match iOS: prominent, `Color.primary`-tinted glass for contrast, at
        // `.regular` size so the button is smaller than the old `.large` capsule.
        self
            .buttonStyle(.glassProminent)
            .controlSize(.regular)
            .buttonBorderShape(.capsule)
            .tint(Color.primary)
        #elseif os(iOS)
        // Prominent, `Color.primary`-tinted glass gives the primary action built-in
        // contrast: a dark glass capsule in Light mode, light in Dark mode. Sits at
        // `.regular` height (not `.large`) so the button reads compact, not oversized.
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glassProminent)
                .controlSize(.regular)
                .buttonBorderShape(.capsule)
                .tint(Color.primary)
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
                .frame(maxWidth: detailHeroRegularActionMaxWidth, alignment: .leading)
        }
        #else
        self
        #endif
    }
}

/// Fraction of the hero (screen) width the iPhone primary action button spans.
let detailHeroCompactActionWidthFraction: CGFloat = 0.6

/// Maximum width of the stacked iPad/regular detail action block.
let detailHeroRegularActionMaxWidth: CGFloat = 460

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
