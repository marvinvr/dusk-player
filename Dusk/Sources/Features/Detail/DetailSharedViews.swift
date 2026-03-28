import SwiftUI

// MARK: - Detail Hero Section

struct DetailHeroSection<Supertitle: View, Subtitle: View, Actions: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    let backdropURL: URL?
    let posterURL: URL?
    let titleArtworkURL: URL?
    let title: String
    let topInset: CGFloat
    let containerWidth: CGFloat
    var backgroundLeadingInset: CGFloat = 0
    var heroBaseHeight: CGFloat = 380
    var posterWidth: CGFloat = 120
    @ViewBuilder var supertitle: Supertitle
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var actions: Actions

    init(
        backdropURL: URL?,
        posterURL: URL?,
        titleArtworkURL: URL? = nil,
        title: String,
        topInset: CGFloat,
        containerWidth: CGFloat,
        backgroundLeadingInset: CGFloat = 0,
        heroBaseHeight: CGFloat = 380,
        posterWidth: CGFloat = 120,
        @ViewBuilder supertitle: () -> Supertitle,
        @ViewBuilder subtitle: () -> Subtitle,
        @ViewBuilder actions: () -> Actions
    ) {
        self.backdropURL = backdropURL
        self.posterURL = posterURL
        self.titleArtworkURL = titleArtworkURL
        self.title = title
        self.topInset = topInset
        self.containerWidth = containerWidth
        self.backgroundLeadingInset = backgroundLeadingInset
        self.heroBaseHeight = heroBaseHeight
        self.posterWidth = posterWidth
        self.supertitle = supertitle()
        self.subtitle = subtitle()
        self.actions = actions()
    }

    private var heroHeight: CGFloat { heroBaseHeight + topInset }
    private var usesTextColumnActions: Bool {
        sizeClass == .regular && posterURL != nil
    }

    var body: some View {
        let horizontalPadding: CGFloat = {
            #if os(tvOS)
            DuskPosterMetrics.detailHorizontalPadding
            #else
            20
            #endif
        }()
        let posterTextSpacing: CGFloat = {
            #if os(tvOS)
            24
            #else
            16
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
                    height: heroHeight
                )

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.18),
                        Color.black.opacity(0.86)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.86),
                        Color.black.opacity(0.48),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                LinearGradient(
                    colors: [
                        .clear,
                        Color.duskBackground.opacity(0.26),
                        Color.duskBackground
                    ],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }
            .frame(width: containerWidth, height: heroHeight, alignment: .leading)
            .offset(x: -backgroundLeadingInset)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom, spacing: posterTextSpacing) {
                    if let posterURL {
                        posterView(url: posterURL)
                    }

                    VStack(alignment: .leading, spacing: usesTextColumnActions ? 16 : 10) {
                        supertitle

                        titleView(height: titleArtworkHeight)

                        subtitle

                        if usesTextColumnActions {
                            actions
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !usesTextColumnActions {
                    actions
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.horizontal, horizontalPadding)
            .padding(.bottom, contentBottomPadding)
            .padding(.top, contentTopPadding)
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func titleView(height: CGFloat) -> some View {
        if let titleArtworkURL {
            DuskAsyncImage(url: titleArtworkURL) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFit()
                        .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
                        .frame(maxWidth: .infinity, maxHeight: height, alignment: .leading)
                case .empty:
                    Color.clear
                        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
                case .failure:
                    titleFallback
                }
            }
        } else {
            titleFallback
        }
    }

    private var titleFallback: some View {
        Text(title)
            .font(.title2.bold())
            .foregroundStyle(Color.white)
            .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
            .multilineTextAlignment(.leading)
            .lineLimit(2)
            .truncationMode(.tail)
            .layoutPriority(1)
    }

    @ViewBuilder
    private func posterView(url: URL) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        DuskAsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
            default:
                shape
                    .fill(Color.duskSurface)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
            }
        }
        .frame(width: posterWidth)
        .clipShape(shape)
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
    }
}

extension DetailHeroSection where Supertitle == EmptyView {
    init(
        backdropURL: URL?,
        posterURL: URL?,
        titleArtworkURL: URL? = nil,
        title: String,
        topInset: CGFloat,
        containerWidth: CGFloat,
        backgroundLeadingInset: CGFloat = 0,
        heroBaseHeight: CGFloat = 380,
        posterWidth: CGFloat = 120,
        @ViewBuilder subtitle: () -> Subtitle,
        @ViewBuilder actions: () -> Actions
    ) {
        self.backdropURL = backdropURL
        self.posterURL = posterURL
        self.titleArtworkURL = titleArtworkURL
        self.title = title
        self.topInset = topInset
        self.containerWidth = containerWidth
        self.backgroundLeadingInset = backgroundLeadingInset
        self.heroBaseHeight = heroBaseHeight
        self.posterWidth = posterWidth
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

struct DetailHeroSecondaryActionButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))

            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(Color.duskTextPrimary)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.duskSurface)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}

struct DetailHeroPrimaryActionButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))

            Text(title)
                .font(.headline)
                .lineLimit(1)
        }
        #if !os(tvOS)
        .foregroundStyle(Color.white)
        .padding(.vertical, 14)
        .padding(.horizontal, 18)
        .background(Color.duskAccent)
        .clipShape(Capsule())
        #endif
    }
}

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

        VStack(alignment: .leading, spacing: avatarTextSpacing) {
            NavigationLink(value: AppNavigationRoute.person(person)) {
                avatarImage(size: avatarSize)
            }
            .buttonStyle(.card)
            .focused($isFocused)
            .accessibilityLabel(accessibilityLabel)
            .frame(width: avatarSize, height: avatarSize)

            personDetails(width: avatarSize)
        }
        .frame(width: cardWidth, alignment: .topLeading)
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
        #if os(tvOS)
        .clipShape(RoundedRectangle(cornerRadius: PosterArtwork.cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: PosterArtwork.cornerRadius, style: .continuous))
        #else
        .clipShape(Circle())
        .contentShape(Circle())
        #endif
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
                .foregroundStyle(Color.duskTextPrimary)
                .lineLimit(1)

            if let roleName = person.roleName, !roleName.isEmpty {
                Text(roleName)
                    .font(.caption2)
                    .foregroundStyle(Color.duskTextSecondary)
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

struct ExpandableSummaryText: View {
    let text: String

    private let collapsedLineLimit = 9

    @State private var isExpanded = false
    @State private var collapsedHeight: CGFloat = 0
    @State private var expandedHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.body)
                .foregroundStyle(Color.duskTextSecondary)
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

            if isExpandable {
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
