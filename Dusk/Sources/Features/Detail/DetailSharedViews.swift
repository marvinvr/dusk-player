import SwiftUI

// MARK: - Detail Hero Section

struct DetailHeroSection<Supertitle: View, Subtitle: View, Actions: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    let backdropURL: URL?
    let posterURL: URL?
    let title: String
    let topInset: CGFloat
    let containerWidth: CGFloat
    var heroBaseHeight: CGFloat = 380
    var posterWidth: CGFloat = 120
    @ViewBuilder var supertitle: Supertitle
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var actions: Actions

    private var heroHeight: CGFloat { heroBaseHeight + topInset }
    private var usesTextColumnActions: Bool {
        sizeClass == .regular && posterURL != nil
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            DetailHeroBackdrop(
                imageURL: backdropURL,
                height: heroHeight
            )

            ZStack {
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
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .bottom, spacing: 16) {
                    if let posterURL {
                        posterView(url: posterURL)
                    }

                    VStack(alignment: .leading, spacing: usesTextColumnActions ? 16 : 10) {
                        supertitle

                        Text(title)
                            .font(.title2.bold())
                            .foregroundStyle(Color.white)
                            .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .layoutPriority(1)

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
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
            .padding(.top, topInset + 64)
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
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
        title: String,
        topInset: CGFloat,
        containerWidth: CGFloat,
        heroBaseHeight: CGFloat = 380,
        posterWidth: CGFloat = 120,
        @ViewBuilder subtitle: () -> Subtitle,
        @ViewBuilder actions: () -> Actions
    ) {
        self.backdropURL = backdropURL
        self.posterURL = posterURL
        self.title = title
        self.topInset = topInset
        self.containerWidth = containerWidth
        self.heroBaseHeight = heroBaseHeight
        self.posterWidth = posterWidth
        self.supertitle = EmptyView()
        self.subtitle = subtitle()
        self.actions = actions()
    }
}

// MARK: - Actor Credit Card

struct ActorCreditCard: View {
    let person: PlexPersonReference
    let plexService: PlexService

    var body: some View {
        NavigationLink(value: AppNavigationRoute.person(person)) {
            VStack(spacing: 8) {
                if let thumbPath = person.thumb {
                    DuskAsyncImage(url: plexService.imageURL(for: thumbPath, width: 72, height: 72)) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        default:
                            placeholder
                        }
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(Circle())
                } else {
                    placeholder
                        .frame(width: 72, height: 72)
                        .clipShape(Circle())
                }

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
            }
            .frame(width: 80)
        }
        .buttonStyle(.plain)
        .duskSuppressTVOSButtonChrome()
    }

    private var placeholder: some View {
        Image(systemName: "person.fill")
            .font(.title2)
            .foregroundStyle(Color.duskTextSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.duskSurface)
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
