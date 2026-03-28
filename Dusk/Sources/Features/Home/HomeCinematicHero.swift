import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct HomeCinematicHeroLayout {
    var heroHeightFactor: CGFloat = 0.72
    var heroHeightRange: ClosedRange<CGFloat> = 520 ... 760
    var maxContentWidth: CGFloat = 620
    var contentHorizontalPadding: CGFloat = 20
    var contentTopPadding: CGFloat = 64
    var contentBottomPaddingWithPager: CGFloat = 52
    var contentBottomPaddingWithoutPager: CGFloat = 28
    var pagerHorizontalPadding: CGFloat = 20
    var pagerBottomPadding: CGFloat = 28
    var titleFontSize: CGFloat = 42
    var titleLogoMaxWidth: CGFloat = 420
    var titleLogoMaxHeight: CGFloat = 108
    var episodeTitleFont: Font = .title3.weight(.semibold)
    var metadataFont: Font = .subheadline.weight(.medium)
    var summaryFont: Font = .body
    var summaryLineSpacing: CGFloat = 4

    static let ios = HomeCinematicHeroLayout()
    static let tv = HomeCinematicHeroLayout(
        heroHeightFactor: 0.70,
        heroHeightRange: 520 ... 760,
        maxContentWidth: 920,
        contentHorizontalPadding: 48,
        contentTopPadding: 56,
        contentBottomPaddingWithPager: 60,
        contentBottomPaddingWithoutPager: 32,
        pagerHorizontalPadding: 48,
        pagerBottomPadding: 32,
        titleFontSize: 46,
        titleLogoMaxWidth: 560,
        titleLogoMaxHeight: 128,
        episodeTitleFont: .title2.weight(.semibold),
        metadataFont: .headline.weight(.medium),
        summaryFont: .body,
        summaryLineSpacing: 4
    )
}

struct HomeCinematicHeroCallbacks {
    let pauseRotation: () -> Void
    let restartRotation: () -> Void
    let showPrevious: () -> Void
    let showNext: () -> Void
}

struct HomeCinematicHero: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PlexService.self) private var plexService

    let items: [PlexItem]
    let viewModel: HomeViewModel
    let containerSize: CGSize
    let topInset: CGFloat
    var contentLeadingInset: CGFloat = 0
    var contentTrailingInset: CGFloat = 0
    var layout: HomeCinematicHeroLayout = .ios
    var autoRotates = true
    var supportsDragNavigation = false
    let primaryAction: (PlexItem, HomeCinematicHeroCallbacks) -> AnyView
    var secondaryAction: ((PlexItem, HomeCinematicHeroCallbacks) -> AnyView)? = nil
    var detailsAction: ((PlexItem) -> Void)? = nil

    @State private var currentHeroIndex = 0
    @State private var heroRotationRevision = 0
    @State private var isHeroRotationPaused = false
    @State private var heroRotationStartedAt = Date()
    @State private var pausedHeroRotationProgress: Double?
    @State private var transitioningHeroIndex: Int?
    @State private var heroSlideProgress: CGFloat = 1
    @State private var heroSlideRevision = 0
    @State private var heroTransitionDirection: HeroTransitionDirection = .forward
    #if canImport(UIKit)
    @State private var preloadedHeroBackdropImages: [String: UIImage] = [:]
    @State private var preloadedHeroTitleImages: [String: UIImage] = [:]
    @State private var failedHeroTitleImageKeys: Set<String> = []
    #endif

    private let heroRotationInterval: UInt64 = 6_000_000_000

    var body: some View {
        let resolvedIndex = resolvedHeroIndex
        let heroWidth = containerSize.width
        let heroHeight = min(
            max(containerSize.height * layout.heroHeightFactor, layout.heroHeightRange.lowerBound),
            layout.heroHeightRange.upperBound
        ) + topInset
        let backdropWidth = Int(heroWidth.rounded(.up))
        let backdropHeight = Int(heroHeight.rounded(.up))
        let safeContentWidth = max(heroWidth - contentLeadingInset - contentTrailingInset, 0)
        let contentWidth = min(
            max(safeContentWidth - (layout.contentHorizontalPadding * 2), 0),
            layout.maxContentWidth
        )
        let titleLogoWidth = Int(min(contentWidth, layout.titleLogoMaxWidth).rounded(.up))
        let titleLogoHeight = Int(layout.titleLogoMaxHeight.rounded(.up))

        let baseHero = ZStack(alignment: .bottomLeading) {
            ZStack(alignment: .bottomLeading) {
                if let transitioningHeroIndex,
                   items.indices.contains(transitioningHeroIndex) {
                    heroSlide(
                        item: items[transitioningHeroIndex],
                        heroHeight: heroHeight,
                        backdropWidth: backdropWidth,
                        backdropHeight: backdropHeight,
                        contentWidth: contentWidth,
                        reservesPagerSpace: items.count > 1
                    )
                    .offset(x: heroSlideOffset(for: .outgoing, width: heroWidth))
                    .id("outgoing-\(items[transitioningHeroIndex].ratingKey)")
                    .zIndex(0)
                }

                if items.indices.contains(resolvedIndex) {
                    heroSlide(
                        item: items[resolvedIndex],
                        heroHeight: heroHeight,
                        backdropWidth: backdropWidth,
                        backdropHeight: backdropHeight,
                        contentWidth: contentWidth,
                        reservesPagerSpace: items.count > 1
                    )
                    .offset(x: heroSlideOffset(for: .incoming, width: heroWidth))
                    .id("incoming-\(items[resolvedIndex].ratingKey)")
                    .zIndex(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            if items.count > 1 {
                heroPager(currentIndex: resolvedIndex)
                    .padding(.leading, contentLeadingInset + layout.pagerHorizontalPadding)
                    .padding(.trailing, contentTrailingInset + layout.pagerHorizontalPadding)
                    .padding(.bottom, layout.pagerBottomPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .onChange(of: heroItemIDs) { _, ids in
            guard !ids.isEmpty else {
                resetHeroSlideState()
                currentHeroIndex = 0
                return
            }

            if currentHeroIndex >= ids.count {
                currentHeroIndex = 0
            }

            resetHeroSlideState()
            restartHeroRotation()
        }
        .task(id: heroRotationSeed) {
            await rotateHeroIfNeeded()
        }
        .task(id: heroBackdropPrefetchSeed(width: backdropWidth, height: backdropHeight)) {
            await preloadHeroBackdropImages(width: backdropWidth, height: backdropHeight)
        }
        .task(id: heroTitlePrefetchSeed(width: titleLogoWidth, height: titleLogoHeight)) {
            await preloadHeroTitleImages(width: titleLogoWidth, height: titleLogoHeight)
        }

        #if os(tvOS)
        return baseHero
            .onMoveCommand(perform: handleHeroMoveCommand)
        #else
        if supportsDragNavigation {
            return AnyView(
                baseHero.simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            handleHeroDrag(value.translation)
                        }
                )
            )
        } else {
            return AnyView(baseHero)
        }
        #endif
    }

    private var actionCallbacks: HomeCinematicHeroCallbacks {
        HomeCinematicHeroCallbacks(
            pauseRotation: pauseHeroRotation,
            restartRotation: restartHeroRotation,
            showPrevious: showPreviousHero,
            showNext: showNextHero
        )
    }

    private var resolvedHeroIndex: Int {
        guard !items.isEmpty else { return 0 }
        return min(currentHeroIndex, items.count - 1)
    }

    private var heroItemIDs: [String] {
        items.map(\.ratingKey)
    }

    private var heroRotationDuration: TimeInterval {
        Double(heroRotationInterval) / 1_000_000_000
    }

    private var heroRotationSeed: String {
        [
            heroItemIDs.joined(separator: "|"),
            String(heroRotationRevision),
            String(accessibilityReduceMotion),
            String(scenePhase == .active),
            String(isHeroRotationPaused),
            String(autoRotates),
        ].joined(separator: "::")
    }

    private func heroSlide(
        item: PlexItem,
        heroHeight: CGFloat,
        backdropWidth: Int,
        backdropHeight: Int,
        contentWidth: CGFloat,
        reservesPagerSpace: Bool
    ) -> some View {
        let metadata = viewModel.heroMetadata(for: item)

        return ZStack(alignment: .bottomLeading) {
            heroBackdrop(
                for: item,
                width: backdropWidth,
                height: backdropHeight,
                heroHeight: heroHeight
            )

            ZStack {
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.18),
                        Color.black.opacity(0.86),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.86),
                        Color.black.opacity(0.48),
                        .clear,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )

                LinearGradient(
                    colors: [
                        .clear,
                        Color.duskBackground.opacity(0.26),
                        Color.duskBackground,
                    ],
                    startPoint: .center,
                    endPoint: .bottom
                )
            }
            .allowsHitTesting(false)

            #if os(iOS)
            if let detailsAction {
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onTapGesture {
                        restartHeroRotation()
                        detailsAction(item)
                    }
                    .accessibilityHidden(true)
            }
            #endif

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: heroTitleBlockSpacing(for: item)) {
                    heroTitle(for: item, contentWidth: contentWidth)

                    if let episodeTitle = viewModel.heroEpisodeTitle(for: item) {
                        Text(episodeTitle)
                            .font(layout.episodeTitleFont)
                            .foregroundStyle(Color.white.opacity(0.88))
                            .lineLimit(2)
                            .frame(maxWidth: contentWidth, alignment: .leading)
                    }

                    if !metadata.isEmpty {
                        Text(metadata.joined(separator: " · "))
                            .font(layout.metadataFont)
                            .foregroundStyle(Color.white.opacity(0.76))
                            .lineLimit(2)
                            .frame(maxWidth: contentWidth, alignment: .leading)
                    }
                }

                if let summary = viewModel.heroSummary(for: item) {
                    Text(summary)
                        .font(layout.summaryFont)
                        .foregroundStyle(Color.white.opacity(0.84))
                        .lineLimit(3)
                        .lineSpacing(layout.summaryLineSpacing)
                        .frame(maxWidth: contentWidth, alignment: .leading)
                }

                heroActions(for: item)
            }
            .padding(.leading, contentLeadingInset + layout.contentHorizontalPadding)
            .padding(.trailing, contentTrailingInset + layout.contentHorizontalPadding)
            .padding(.bottom, reservesPagerSpace ? layout.contentBottomPaddingWithPager : layout.contentBottomPaddingWithoutPager)
            .padding(.top, topInset + layout.contentTopPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func heroTitleBlockSpacing(for item: PlexItem) -> CGFloat {
        item.type == .movie ? 12 : 8
    }

    @ViewBuilder
    private func heroTitle(for item: PlexItem, contentWidth: CGFloat) -> some View {
        let logoWidth = min(contentWidth, layout.titleLogoMaxWidth)
        let logoHeight = layout.titleLogoMaxHeight
        if item.clearLogo != nil {
            heroTitleArtwork(for: item, width: logoWidth, height: logoHeight)
        } else {
            heroTitleFallback(for: item)
        }
    }

    @ViewBuilder
    private func heroTitleArtwork(for item: PlexItem, width: CGFloat, height: CGFloat) -> some View {
        #if canImport(UIKit)
        if let image = preloadedHeroTitleImages[item.ratingKey] {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
                .frame(width: width, height: height, alignment: .bottomLeading)
        } else if failedHeroTitleImageKeys.contains(item.ratingKey) {
            heroTitleFallback(for: item)
        } else {
            Color.clear
                .frame(width: width, height: height, alignment: .bottomLeading)
        }
        #else
        heroTitleFallback(for: item)
        #endif
    }

    private func heroTitleFallback(for item: PlexItem) -> some View {
        Text(viewModel.displayTitle(for: item))
            .font(.system(size: layout.titleFontSize, weight: .heavy, design: .rounded))
            .foregroundStyle(Color.white)
            .lineLimit(3)
            .minimumScaleFactor(0.7)
            .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func heroActions(for item: PlexItem) -> some View {
        let primary = primaryAction(item, actionCallbacks)
        let secondary = secondaryAction?(item, actionCallbacks)

        if let secondary {
            HStack(spacing: 16) {
                primary
                secondary
            }
        } else {
            primary
        }
    }

    @ViewBuilder
    private func heroPager(currentIndex: Int) -> some View {
        if autoRotates {
            TimelineView(.periodic(from: .now, by: 0.05)) { timeline in
                pagerContent(currentIndex: currentIndex, date: timeline.date)
            }
        } else {
            pagerContent(currentIndex: currentIndex, date: nil)
        }
    }

    @ViewBuilder
    private func pagerContent(currentIndex: Int, date: Date?) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                #if os(tvOS)
                HomeHeroPagerPill(
                    isActive: index == currentIndex,
                    progress: pagerProgress(for: index, currentIndex: currentIndex, date: date)
                )
                .accessibilityHidden(true)
                #else
                Button {
                    selectHero(at: index)
                } label: {
                    HomeHeroPagerPill(
                        isActive: index == currentIndex,
                        progress: pagerProgress(for: index, currentIndex: currentIndex, date: date)
                    )
                    .accessibilityLabel(Text(viewModel.displayTitle(for: item)))
                }
                .buttonStyle(.plain)
                .duskSuppressTVOSButtonChrome()
                .duskTVOSFocusEffectShape(Capsule())
                #endif
            }
        }
    }

    private func pagerProgress(for index: Int, currentIndex: Int, date: Date?) -> Double {
        guard index == currentIndex else { return 0 }
        guard autoRotates, let date else { return 1 }
        return heroRotationProgress(at: date)
    }

    private func rotateHeroIfNeeded() async {
        guard autoRotates,
              heroItemIDs.count > 1,
              !accessibilityReduceMotion,
              scenePhase == .active,
              !isHeroRotationPaused else {
            return
        }

        do {
            try await Task.sleep(nanoseconds: remainingHeroRotationNanoseconds(at: Date()))
        } catch {
            return
        }

        guard !Task.isCancelled else { return }

        await MainActor.run {
            guard autoRotates,
                  heroItemIDs.count > 1,
                  !isHeroRotationPaused else { return }

            moveHero(
                to: (currentHeroIndex + 1) % heroItemIDs.count,
                direction: .forward,
                duration: 0.6
            )
            restartHeroRotation()
        }
    }

    private func selectHero(at index: Int) {
        guard index != currentHeroIndex else {
            restartHeroRotation()
            return
        }

        restartHeroRotation()
        moveHero(
            to: index,
            direction: resolvedHeroTransitionDirection(
                from: currentHeroIndex,
                to: index,
                itemCount: heroItemIDs.count
            ),
            duration: 0.5
        )
    }

    private func restartHeroRotation() {
        guard autoRotates else { return }
        isHeroRotationPaused = false
        pausedHeroRotationProgress = nil
        heroRotationStartedAt = Date()
        heroRotationRevision += 1
    }

    private func pauseHeroRotation() {
        guard autoRotates, !isHeroRotationPaused else { return }
        isHeroRotationPaused = true
        pausedHeroRotationProgress = heroRotationProgress(at: Date())
        heroRotationRevision += 1
    }

    private func handleHeroDrag(_ translation: CGSize) {
        guard supportsDragNavigation,
              heroItemIDs.count > 1,
              abs(translation.width) > abs(translation.height),
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

        moveHero(
            to: nextIndex,
            direction: translation.width < 0 ? .forward : .backward,
            duration: 0.5
        )
    }

    #if os(tvOS)
    private func handleHeroMoveCommand(_ direction: MoveCommandDirection) {
        guard heroItemIDs.count > 1 else { return }

        switch direction {
        case .left:
            showPreviousHero()
        case .right:
            showNextHero()
        default:
            break
        }
    }
    #endif

    private func showPreviousHero() {
        guard heroItemIDs.count > 1 else { return }

        let heroCount = heroItemIDs.count
        restartHeroRotation()
        moveHero(
            to: (currentHeroIndex - 1 + heroCount) % heroCount,
            direction: .backward,
            duration: 0.5
        )
    }

    private func showNextHero() {
        guard heroItemIDs.count > 1 else { return }

        let heroCount = heroItemIDs.count
        restartHeroRotation()
        moveHero(
            to: (currentHeroIndex + 1) % heroCount,
            direction: .forward,
            duration: 0.5
        )
    }

    private func heroRotationProgress(at date: Date) -> Double {
        if let pausedHeroRotationProgress {
            return max(0, min(pausedHeroRotationProgress, 1))
        }

        let elapsed = date.timeIntervalSince(heroRotationStartedAt)
        guard heroRotationDuration > 0 else { return 0 }
        return max(0, min(elapsed / heroRotationDuration, 1))
    }

    private func remainingHeroRotationNanoseconds(at date: Date) -> UInt64 {
        let progress = heroRotationProgress(at: date)
        let remaining = max(0, 1 - progress) * heroRotationDuration
        return UInt64((remaining * 1_000_000_000).rounded())
    }

    private func resetHeroSlideState() {
        heroSlideRevision += 1
        transitioningHeroIndex = nil
        heroSlideProgress = 1
    }

    private func heroBackdropPrefetchSeed(width: Int, height: Int) -> String {
        [
            items.map(\.ratingKey).joined(separator: "|"),
            "\(width)x\(height)"
        ].joined(separator: "::")
    }

    private func heroTitlePrefetchSeed(width: Int, height: Int) -> String {
        [
            items.map { "\($0.ratingKey):\($0.clearLogo ?? "")" }.joined(separator: "|"),
            "\(width)x\(height)"
        ].joined(separator: "::")
    }

    private func preloadHeroBackdropImages(width: Int, height: Int) async {
        #if canImport(UIKit)
        let backdropRequests = items.compactMap { item -> (String, URL)? in
            guard let url = viewModel.heroBackgroundURL(for: item, width: width, height: height) else {
                return nil
            }

            return (item.ratingKey, url)
        }

        let validKeys = Set(items.map(\.ratingKey))
        await MainActor.run {
            preloadedHeroBackdropImages = preloadedHeroBackdropImages.filter { validKeys.contains($0.key) }
        }

        guard !backdropRequests.isEmpty else { return }

        var loadedImages: [String: UIImage] = [:]

        await withTaskGroup(of: (String, UIImage?).self) { group in
            for (ratingKey, url) in backdropRequests {
                group.addTask {
                    do {
                        let image = try await DuskImageLoader.shared.image(for: url)
                        return (ratingKey, image)
                    } catch {
                        return (ratingKey, nil)
                    }
                }
            }

            for await (ratingKey, image) in group {
                if let image {
                    loadedImages[ratingKey] = image
                }
            }
        }

        guard !loadedImages.isEmpty else { return }

        await MainActor.run {
            for (ratingKey, image) in loadedImages {
                guard validKeys.contains(ratingKey) else { continue }
                preloadedHeroBackdropImages[ratingKey] = image
            }
        }
        #endif
    }

    private func preloadHeroTitleImages(width: Int, height: Int) async {
        #if canImport(UIKit)
        let titleRequests = items.compactMap { item -> (String, URL)? in
            guard let url = viewModel.heroTitleLogoURL(for: item, width: width, height: height) else {
                return nil
            }

            return (item.ratingKey, url)
        }

        let validKeys = Set(items.map(\.ratingKey))
        let requestedKeys = Set(titleRequests.map(\.0))

        await MainActor.run {
            preloadedHeroTitleImages = preloadedHeroTitleImages.filter { validKeys.contains($0.key) }
            failedHeroTitleImageKeys = failedHeroTitleImageKeys
                .filter { validKeys.contains($0) && requestedKeys.contains($0) }
        }

        guard !titleRequests.isEmpty else { return }

        var loadedImages: [String: UIImage] = [:]
        var failedKeys: Set<String> = []

        await withTaskGroup(of: (String, UIImage?, Bool).self) { group in
            for (ratingKey, url) in titleRequests {
                group.addTask {
                    do {
                        let image = try await DuskImageLoader.shared.image(for: url, using: plexService)
                        return (ratingKey, image, false)
                    } catch {
                        return (ratingKey, nil, true)
                    }
                }
            }

            for await (ratingKey, image, didFail) in group {
                if let image {
                    loadedImages[ratingKey] = image
                } else if didFail {
                    failedKeys.insert(ratingKey)
                }
            }
        }

        await MainActor.run {
            for (ratingKey, image) in loadedImages {
                guard validKeys.contains(ratingKey) else { continue }
                preloadedHeroTitleImages[ratingKey] = image
                failedHeroTitleImageKeys.remove(ratingKey)
            }

            for ratingKey in failedKeys where validKeys.contains(ratingKey) {
                failedHeroTitleImageKeys.insert(ratingKey)
            }
        }
        #endif
    }

    @ViewBuilder
    private func heroBackdrop(
        for item: PlexItem,
        width: Int,
        height: Int,
        heroHeight: CGFloat
    ) -> some View {
        #if canImport(UIKit)
        if let image = preloadedHeroBackdropImages[item.ratingKey] {
            GeometryReader { geometry in
                ZStack {
                    Color.duskSurface

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height,
                            alignment: .center
                        )
                        .clipped()
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
                .clipped()
            }
            .frame(height: heroHeight)
            .frame(maxWidth: .infinity)
        } else {
            DetailHeroBackdrop(
                imageURL: viewModel.heroBackgroundURL(
                    for: item,
                    width: width,
                    height: height
                ),
                height: heroHeight
            )
        }
        #else
        DetailHeroBackdrop(
            imageURL: viewModel.heroBackgroundURL(
                for: item,
                width: width,
                height: height
            ),
            height: heroHeight
        )
        #endif
    }

    private func moveHero(to index: Int, direction: HeroTransitionDirection, duration: TimeInterval) {
        let previousIndex = currentHeroIndex
        let slideRevision = heroSlideRevision + 1

        heroSlideRevision = slideRevision
        heroTransitionDirection = direction
        transitioningHeroIndex = previousIndex
        currentHeroIndex = index
        heroSlideProgress = 0

        withAnimation(.easeInOut(duration: duration)) {
            heroSlideProgress = 1
        }

        Task {
            try? await Task.sleep(
                nanoseconds: UInt64((duration * 1_000_000_000).rounded())
            )

            await MainActor.run {
                guard heroSlideRevision == slideRevision else { return }
                transitioningHeroIndex = nil
                heroSlideProgress = 1
            }
        }
    }

    private func heroSlideOffset(for role: HeroSlideRole, width: CGFloat) -> CGFloat {
        guard transitioningHeroIndex != nil else { return 0 }

        switch (heroTransitionDirection, role) {
        case (.forward, .outgoing):
            return -width * heroSlideProgress
        case (.forward, .incoming):
            return width * (1 - heroSlideProgress)
        case (.backward, .outgoing):
            return width * heroSlideProgress
        case (.backward, .incoming):
            return -width * (1 - heroSlideProgress)
        }
    }

    private func resolvedHeroTransitionDirection(
        from currentIndex: Int,
        to nextIndex: Int,
        itemCount: Int
    ) -> HeroTransitionDirection {
        guard itemCount > 1, currentIndex != nextIndex else { return .forward }

        let forwardDistance = nextIndex >= currentIndex
            ? nextIndex - currentIndex
            : itemCount - currentIndex + nextIndex
        let backwardDistance = currentIndex >= nextIndex
            ? currentIndex - nextIndex
            : currentIndex + itemCount - nextIndex

        return forwardDistance <= backwardDistance ? .forward : .backward
    }
}

private enum HeroTransitionDirection {
    case forward
    case backward
}

private enum HeroSlideRole {
    case outgoing
    case incoming
}
