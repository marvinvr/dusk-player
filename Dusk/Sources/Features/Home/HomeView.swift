import SwiftUI
#if os(iOS)
import UIKit
#endif

struct HomeView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Binding var path: NavigationPath
    @State private var viewModel: HomeViewModel?
    @State private var currentHeroIndex = 0
    @State private var heroRotationRevision = 0
    @State private var heroRotationProgress = 0.0
    @State private var heroMenuItem: PlexItem?

    private let heroRotationInterval: UInt64 = 5_000_000_000

    var body: some View {
        applyNavigationChrome(
            to: NavigationStack(path: $path) {
                ZStack {
                    Color.duskBackground.ignoresSafeArea()

                    if let viewModel {
                        let hasHomeContent = !viewModel.hubs.isEmpty || !viewModel.continueWatching.isEmpty

                        if viewModel.isLoading, !hasHomeContent {
                            FeatureLoadingView()
                        } else if let error = viewModel.error, !hasHomeContent {
                            FeatureErrorView(message: error) {
                                Task { await viewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
                            }
                        } else {
                            contentView(viewModel)
                        }
                    }
                }
                .task(id: plexService.connectedServer?.clientIdentifier) {
                    if viewModel == nil {
                        viewModel = HomeViewModel(plexService: plexService)
                    }
                    await viewModel?.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit)
                }
                .onAppear {
                    guard viewModel != nil else { return }
                    Task { await viewModel?.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
                }
                .onChange(of: playback.showPlayer) { _, isShowing in
                    if !isShowing {
                        Task { await viewModel?.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
                    }
                }
                .refreshable {
                    await viewModel?.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit)
                }
                .duskAppNavigationDestinations()
            },
            showsHero: showsCinematicHero
        )
        .onChange(of: heroItemIDs) { _, ids in
            guard !ids.isEmpty else {
                currentHeroIndex = 0
                return
            }

            if currentHeroIndex >= ids.count {
                currentHeroIndex = 0
            }
        }
        .onChange(of: isHeroMenuPresented) { _, isPresented in
            if isPresented {
                pauseHeroRotation()
            } else {
                restartHeroRotation()
            }
        }
        .task(id: heroRotationSeed) {
            await rotateHeroIfNeeded()
        }
        .confirmationDialog(
            "",
            isPresented: heroMenuPresentedBinding,
            titleVisibility: .hidden,
            presenting: heroMenuItem
        ) { item in
            heroActionDialog(for: item)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func contentView(_ vm: HomeViewModel) -> some View {
        let heroItems = vm.heroItems()

        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !heroItems.isEmpty {
                        cinematicHeroSection(
                            vm,
                            items: heroItems,
                            containerSize: geometry.size,
                            topInset: geometry.safeAreaInsets.top
                        )
                    } else if showsHomeServerSubtitle, let serverName = plexService.connectedServer?.name {
                        homeSubtitle(serverName)
                            .padding(.bottom, 12)
                    }

                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(vm.hubs) { hub in
                            let items = vm.inlineItems(
                                in: hub,
                                maxRecentlyAddedItems: recentlyAddedInlineItemLimit
                            )
                            if !items.isEmpty {
                                hubSection(hub, items: items, vm: vm)
                            }
                        }
                    }
                    .padding(.top, heroItems.isEmpty ? 0 : 24)
                }
                .padding(.top, heroItems.isEmpty ? (showsHomeServerSubtitle ? -10 : 16) : -geometry.safeAreaInsets.top)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: 88)
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private func cinematicHeroSection(
        _ vm: HomeViewModel,
        items: [PlexItem],
        containerSize: CGSize,
        topInset: CGFloat
    ) -> some View {
        let index = resolvedHeroIndex(for: items)
        let item = items[index]
        let heroWidth = containerSize.width
        let heroHeight = min(max(containerSize.height * 0.72, 520), 760) + topInset
        let backdropWidth = Int(heroWidth.rounded(.up))
        let backdropHeight = Int(heroHeight.rounded(.up))
        let contentWidth = min(max(heroWidth - 40, 0), 620)
        let metadata = vm.heroMetadata(for: item)

        ZStack(alignment: .bottomLeading) {
            DetailHeroBackdrop(
                imageURL: vm.heroBackgroundURL(
                    for: item,
                    width: backdropWidth,
                    height: backdropHeight
                ),
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
                VStack(alignment: .leading, spacing: 8) {
                    Text(vm.displayTitle(for: item))
                        .font(.system(size: 42, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color.white)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                        .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
                        .frame(maxWidth: contentWidth, alignment: .leading)

                    if let episodeTitle = vm.heroEpisodeTitle(for: item) {
                        Text(episodeTitle)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.88))
                            .lineLimit(2)
                            .frame(maxWidth: contentWidth, alignment: .leading)
                    }

                    if !metadata.isEmpty {
                        Text(metadata.joined(separator: " · "))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.76))
                            .lineLimit(2)
                            .frame(maxWidth: contentWidth, alignment: .leading)
                    }
                }

                if let summary = vm.heroSummary(for: item) {
                    Text(summary)
                        .font(.body)
                        .foregroundStyle(Color.white.opacity(0.84))
                        .lineLimit(3)
                        .lineSpacing(4)
                        .frame(maxWidth: contentWidth, alignment: .leading)
                }

                heroActionRow(vm, item: item)

                if items.count > 1 {
                    heroPager(items: items, currentIndex: index)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 28)
            .padding(.top, topInset + 64)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    handleHeroDrag(value.translation)
                }
        )
    }

    @ViewBuilder
    private func heroActionRow(_ vm: HomeViewModel, item: PlexItem) -> some View {
        heroActionButton(vm, item: item)
    }

    @ViewBuilder
    private func heroActionButton(_ vm: HomeViewModel, item: PlexItem) -> some View {
        #if os(tvOS)
        Button {
            restartHeroRotation()
            play(item)
        } label: {
            HomeHeroActionButtonLabel(
                title: vm.heroPrimaryActionTitle(for: item),
                systemImage: "play.fill"
            )
        }
        .buttonStyle(.plain)
        .duskSuppressTVOSButtonChrome()
        .contextMenu {
            PlexItemContextMenuContent(
                item: item,
                onMarkWatched: {
                    Task { await vm.setWatched(true, for: item) }
                },
                onMarkUnwatched: {
                    Task { await vm.setWatched(false, for: item) }
                },
                detailsRoute: AppNavigationRoute.destination(for: item),
                detailsLabel: heroDetailsLabel(for: item)
            )
        }
        #else
        HomeHeroActionButtonLabel(
            title: vm.heroPrimaryActionTitle(for: item),
            systemImage: "play.fill"
        )
        .contentShape(Capsule())
        .onTapGesture {
            restartHeroRotation()
            play(item)
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            heroMenuItem = item
        }
        .accessibilityAddTraits(.isButton)
        #endif
    }

    @ViewBuilder
    private func heroPager(items: [PlexItem], currentIndex: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button {
                    selectHero(at: index)
                } label: {
                    HomeHeroPagerPill(
                        isActive: index == currentIndex,
                        progress: index == currentIndex ? heroRotationProgress : 0
                    )
                    .accessibilityLabel(Text(vmDisplayLabel(for: item)))
                }
                .buttonStyle(.plain)
                .duskSuppressTVOSButtonChrome()
            }
        }
    }

    // MARK: - Hub Section

    @ViewBuilder
    private func hubSection(_ hub: PlexHub, items: [PlexItem], vm: HomeViewModel) -> some View {
        let imageWidth = 130
        let imageHeight = 195
        let showsShowAll = vm.shouldShowAll(
            for: hub,
            maxRecentlyAddedItems: recentlyAddedInlineItemLimit
        )

        MediaCarousel(
            title: hub.title,
            headerAccessory: {
                if showsShowAll {
                    NavigationLink(value: AppNavigationRoute.hub(hub)) {
                        Text("Show all")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.duskAccent)
                    }
                    .buttonStyle(.plain)
                    .duskSuppressTVOSButtonChrome()
                }
            }
        ) {
            ForEach(items) { item in
                #if os(tvOS)
                VStack(alignment: .leading, spacing: 6) {
                    NavigationLink(value: AppNavigationRoute.destination(for: item)) {
                        PosterArtwork(
                            imageURL: vm.posterURL(for: item, width: imageWidth, height: imageHeight),
                            width: 130,
                            imageAspectRatio: 2.0 / 3.0
                        )
                    }
                    .buttonStyle(.plain)
                    .duskSuppressTVOSButtonChrome()

                    PosterCardText(
                        title: item.title,
                        subtitle: item.year.map(String.init),
                        width: 130
                    )
                }
                .frame(width: 130, alignment: .topLeading)
                .contextMenu {
                    PlexItemContextMenuContent(
                        item: item,
                        onMarkWatched: {
                            Task { await vm.setWatched(true, for: item) }
                        },
                        onMarkUnwatched: {
                            Task { await vm.setWatched(false, for: item) }
                        }
                    )
                }
                #else
                NavigationLink(value: AppNavigationRoute.destination(for: item)) {
                    PosterCard(
                        imageURL: vm.posterURL(for: item, width: imageWidth, height: imageHeight),
                        title: item.title,
                        subtitle: item.year.map(String.init)
                    )
                }
                .buttonStyle(.plain)
                .duskSuppressTVOSButtonChrome()
                .contextMenu {
                    PlexItemContextMenuContent(
                        item: item,
                        onMarkWatched: {
                            Task { await vm.setWatched(true, for: item) }
                        },
                        onMarkUnwatched: {
                            Task { await vm.setWatched(false, for: item) }
                        }
                    )
                }
                #endif
            }
        }
    }

    // MARK: - Navigation

    @ViewBuilder
    private func applyNavigationChrome<Content: View>(to content: Content, showsHero: Bool) -> some View {
        if showsHero {
            content
                .duskNavigationTitle("")
                .duskNavigationBarTitleDisplayModeInline()
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbarBackground(.hidden, for: .navigationBar)
        } else {
            content
                .duskNavigationTitle("Home")
                .duskNavigationBarTitleDisplayModeLarge()
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    // MARK: - Rotation

    private func rotateHeroIfNeeded() async {
        guard heroItemIDs.count > 1,
              !accessibilityReduceMotion,
              scenePhase == .active,
              !isHeroMenuPresented else {
            await MainActor.run {
                setHeroRotationProgress(0)
            }
            return
        }

        while !Task.isCancelled {
            await MainActor.run {
                setHeroRotationProgress(0)
                withAnimation(.linear(duration: Double(heroRotationInterval) / 1_000_000_000)) {
                    heroRotationProgress = 1
                }
            }

            do {
                try await Task.sleep(nanoseconds: heroRotationInterval)
            } catch {
                await MainActor.run {
                    setHeroRotationProgress(0)
                }
                return
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                let heroCount = heroItemIDs.count
                guard heroCount > 1 else { return }

                withAnimation(.easeInOut(duration: 0.7)) {
                    currentHeroIndex = (currentHeroIndex + 1) % heroCount
                }
            }
        }
    }

    @ViewBuilder
    private func heroActionDialog(for item: PlexItem) -> some View {
        if item.canMarkWatchedFromContextMenu, let viewModel {
            Button("Mark Watched") {
                Task { await viewModel.setWatched(true, for: item) }
            }
        }

        if item.canMarkUnwatchedFromContextMenu, let viewModel {
            Button("Mark Unwatched") {
                Task { await viewModel.setWatched(false, for: item) }
            }
        }

        Button(heroDetailsLabel(for: item)) {
            path.append(AppNavigationRoute.destination(for: item))
        }

        if let seasonRoute = item.contextMenuSeasonRoute {
            Button("Go to Season") {
                path.append(seasonRoute)
            }
        }

        if let showRoute = item.contextMenuShowRoute {
            Button("Go to Show") {
                path.append(showRoute)
            }
        }
    }

    private func selectHero(at index: Int) {
        guard index != currentHeroIndex else {
            restartHeroRotation()
            return
        }

        restartHeroRotation()
        withAnimation(.easeInOut(duration: 0.5)) {
            currentHeroIndex = index
        }
    }

    private func restartHeroRotation() {
        setHeroRotationProgress(0)
        heroRotationRevision += 1
    }

    private func pauseHeroRotation() {
        setHeroRotationProgress(0)
        heroRotationRevision += 1
    }

    private func handleHeroDrag(_ translation: CGSize) {
        guard heroItemIDs.count > 1 else { return }
        guard abs(translation.width) > abs(translation.height),
              abs(translation.width) > 44 else {
            return
        }

        restartHeroRotation()

        let heroCount = heroItemIDs.count
        let nextIndex: Int
        if translation.width < 0 {
            nextIndex = (currentHeroIndex + 1) % heroCount
        } else {
            nextIndex = (currentHeroIndex - 1 + heroCount) % heroCount
        }

        withAnimation(.easeInOut(duration: 0.45)) {
            currentHeroIndex = nextIndex
        }
    }

    private func resolvedHeroIndex(for items: [PlexItem]) -> Int {
        guard !items.isEmpty else { return 0 }
        return min(currentHeroIndex, items.count - 1)
    }

    // MARK: - Error

    private func homeSubtitle(_ serverName: String) -> some View {
        Text(serverName)
            .font(.subheadline)
            .foregroundStyle(Color.duskTextSecondary)
            .lineLimit(1)
            .padding(.horizontal, 20)
    }

    private var showsHomeServerSubtitle: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var showsCinematicHero: Bool {
        !(viewModel?.heroItems().isEmpty ?? true)
    }

    private var isHeroMenuPresented: Bool {
        heroMenuItem != nil
    }

    private var heroItemIDs: [String] {
        viewModel?.heroItems().map(\.ratingKey) ?? []
    }

    private var heroRotationSeed: String {
        [
            heroItemIDs.joined(separator: "|"),
            String(heroRotationRevision),
            String(accessibilityReduceMotion),
            String(scenePhase == .active),
            String(isHeroMenuPresented)
        ].joined(separator: "::")
    }

    private var heroMenuPresentedBinding: Binding<Bool> {
        Binding(
            get: { heroMenuItem != nil },
            set: { isPresented in
                if !isPresented {
                    heroMenuItem = nil
                }
            }
        )
    }

    private var recentlyAddedInlineItemLimit: Int {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? 15 : 10
        #else
        10
        #endif
    }

    private func play(_ item: PlexItem) {
        Task {
            await playback.play(ratingKey: item.ratingKey)
        }
    }

    private func vmDisplayLabel(for item: PlexItem) -> String {
        guard let viewModel else { return item.title }
        return viewModel.displayTitle(for: item)
    }

    private func heroDetailsLabel(for item: PlexItem) -> String {
        switch item.type {
        case .episode:
            return "Go to Episode"
        case .season:
            return "Go to Season"
        case .show:
            return "Go to Show"
        case .movie:
            return "Go to Movie"
        default:
            return "View Details"
        }
    }

    private func setHeroRotationProgress(_ progress: Double) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            heroRotationProgress = progress
        }
    }

}

private struct HomeHeroActionButtonLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))

            Text(title)
                .font(.headline.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.duskAccent, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }
}

private struct HomeHeroPagerPill: View {
    let isActive: Bool
    let progress: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(isActive ? Color.white.opacity(0.24) : Color.white.opacity(0.28))
                .frame(width: isActive ? 28 : 10, height: 10)

            if isActive {
                Capsule()
                    .fill(Color.duskAccent)
                    .frame(width: 28 * min(max(progress, 0), 1), height: 10)
            }
        }
        .overlay {
            if isActive {
                Capsule()
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            }
        }
    }
}
