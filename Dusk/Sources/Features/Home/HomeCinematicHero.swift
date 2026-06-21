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
    var actionsTopPadding: CGFloat = 0
    var actionsBottomPadding: CGFloat = 0
    var pagerHorizontalPadding: CGFloat = 20
    var pagerBottomPadding: CGFloat = 28
    var titleFontSize: CGFloat = 42
    var titleLogoMaxWidth: CGFloat = 420
    var titleLogoMaxHeight: CGFloat = 108
    var backdropImageAlignment: Alignment = .center
    var episodeTitleFont: Font = .title3.weight(.semibold)
    var metadataFont: Font = .subheadline.weight(.medium)
    var summaryFont: Font = .body
    var summaryLineLimit: Int = 3
    var summaryLineSpacing: CGFloat = 4

    static let ios = HomeCinematicHeroLayout(summaryLineLimit: 2)
    static let tv = HomeCinematicHeroLayout(
        heroHeightFactor: 0.75,
        heroHeightRange: 560 ... 820,
        maxContentWidth: 820,
        contentHorizontalPadding: 56,
        contentTopPadding: 64,
        contentBottomPaddingWithPager: 64,
        contentBottomPaddingWithoutPager: 32,
        actionsTopPadding: 10,
        actionsBottomPadding: 8,
        pagerHorizontalPadding: 56,
        pagerBottomPadding: 34,
        titleFontSize: 40,
        titleLogoMaxWidth: 560,
        titleLogoMaxHeight: 124,
        backdropImageAlignment: .top,
        episodeTitleFont: .title3.weight(.semibold),
        metadataFont: .subheadline.weight(.medium),
        summaryFont: .callout,
        summaryLineLimit: 2,
        summaryLineSpacing: 3
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
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback

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
    @State private var heroDragOffset: CGFloat = 0
    @State private var heroDragTargetIndex: Int?
    @State private var heroDragRevision = 0
    @State private var isHeroDragging = false
    #if canImport(UIKit)
    @State private var preloadedHeroBackdropImages: [String: UIImage] = [:]
    @State private var preloadedHeroTitleImages: [String: UIImage] = [:]
    @State private var failedHeroTitleImageKeys: Set<String> = []
    #endif

    private let heroRotationInterval: UInt64 = 7_000_000_000

    var body: some View {
        let resolvedIndex = resolvedHeroIndex
        let heroWidth = pixelAlignedLength(containerSize.width)
        let rawHeroHeight = min(
            max(containerSize.height * layout.heroHeightFactor, layout.heroHeightRange.lowerBound),
            layout.heroHeightRange.upperBound
        ) + topInset
        let heroHeight = pixelAlignedLength(rawHeroHeight)
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
                if let backgroundHeroIndex,
                   items.indices.contains(backgroundHeroIndex) {
                    heroSlide(
                        item: items[backgroundHeroIndex],
                        heroHeight: heroHeight,
                        backdropWidth: backdropWidth,
                        backdropHeight: backdropHeight,
                        contentWidth: contentWidth,
                        reservesPagerSpace: items.count > 1
                    )
                    .offset(x: backgroundHeroOffset(width: heroWidth))
                    .id("background-\(items[backgroundHeroIndex].ratingKey)")
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
                    .offset(x: foregroundHeroOffset(width: heroWidth))
                    .id("foreground-\(items[resolvedIndex].ratingKey)")
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
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: heroContentBlockAlignment)
            }
        }
        .frame(height: heroHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .onChange(of: heroItemIDs) { previousIDs, ids in
            guard !ids.isEmpty else {
                resetHeroSlideState()
                resetHeroDragState()
                currentHeroIndex = 0
                return
            }

            if previousIDs.indices.contains(currentHeroIndex),
               let updatedIndex = ids.firstIndex(of: previousIDs[currentHeroIndex]) {
                currentHeroIndex = updatedIndex
            } else if currentHeroIndex >= ids.count {
                currentHeroIndex = max(ids.count - 1, 0)
            }

            resetHeroSlideState()
            resetHeroDragState()
            restartHeroRotation()
        }
        .onChange(of: playback.showPlayer) { _, isShowing in
            // The player presents as a full-screen cover, which does not change
            // scenePhase, so the rotation timer would otherwise keep advancing the
            // hero behind it. Pause while playing and restart fresh on return so we
            // come back to the hero the user launched from.
            if isShowing {
                pauseHeroRotation()
            } else {
                restartHeroRotation()
            }
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
            .duskTVOSStandardImageDynamicRange()
            .onMoveCommand(perform: handleHeroMoveCommand)
        #else
        if supportsDragNavigation {
            return AnyView(
                baseHero
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 20)
                            .onChanged { value in
                                handleHeroDragChanged(value)
                            }
                            .onEnded { value in
                                handleHeroDragEnded(value, heroWidth: heroWidth)
                            }
                    )
                    #if os(iOS)
                    .background(
                        HeroIndirectScrollNavigation(
                            isEnabled: supportsDragNavigation && heroItemIDs.count > 1,
                            onChanged: { horizontalOffset in
                                handleHeroIndirectScrollChanged(
                                    horizontalOffset: horizontalOffset
                                )
                            },
                            onEnded: { horizontalOffset, predictedHorizontalOffset in
                                handleHeroIndirectScrollEnded(
                                    horizontalOffset: horizontalOffset,
                                    predictedHorizontalOffset: predictedHorizontalOffset,
                                    heroWidth: heroWidth
                                )
                            }
                        )
                    )
                    #endif
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

    private func pixelAlignedLength(_ length: CGFloat) -> CGFloat {
        let scale = displayScale
        guard scale > 0, length.isFinite else { return length }
        return (length * scale).rounded(.up) / scale
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
            String(isHeroDragging),
        ].joined(separator: "::")
    }

    private var backgroundHeroIndex: Int? {
        if isHeroDragActive {
            return heroDragTargetIndex
        }

        return transitioningHeroIndex
    }

    private var isHeroDragActive: Bool {
        isHeroDragging || heroDragTargetIndex != nil || heroDragOffset != 0
    }

    private var isHeroDragSettling: Bool {
        heroDragTargetIndex != nil && !isHeroDragging
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
            ZStack {
                heroBackdrop(
                    for: item,
                    width: backdropWidth,
                    height: backdropHeight,
                    heroHeight: heroHeight
                )

                DuskHeroBackdropOverlay()
            }
            .duskHeroBackdropBottomFade(.compact)

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

            VStack(alignment: heroContentHorizontalAlignment, spacing: 16) {
                VStack(alignment: heroContentHorizontalAlignment, spacing: heroTitleBlockSpacing(for: item)) {
                    heroTitle(for: item, contentWidth: contentWidth)

                    if let episodeTitle = viewModel.heroEpisodeTitle(for: item) {
                        Text(episodeTitle)
                            .font(layout.episodeTitleFont)
                            .foregroundStyle(Color.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(heroTextAlignment)
                            .frame(maxWidth: contentWidth, alignment: heroContentFrameAlignment)
                    }

                    if !metadata.isEmpty {
                        Text(metadata.joined(separator: " · "))
                            .font(layout.metadataFont)
                            .foregroundStyle(Color.primary.opacity(0.78))
                            .lineLimit(2)
                            .multilineTextAlignment(heroTextAlignment)
                            .frame(maxWidth: contentWidth, alignment: heroContentFrameAlignment)
                    }
                }

                if showsHeroSummary, let summary = viewModel.heroSummary(for: item) {
                    Text(summary)
                        .font(layout.summaryFont)
                        .foregroundStyle(Color.primary.opacity(0.76))
                        .lineLimit(layout.summaryLineLimit)
                        .lineSpacing(layout.summaryLineSpacing)
                        .multilineTextAlignment(heroTextAlignment)
                        .frame(maxWidth: contentWidth, alignment: heroContentFrameAlignment)
                }

                heroActions(for: item)
                    .padding(.top, layout.actionsTopPadding)
                    .padding(.bottom, layout.actionsBottomPadding)
            }
            .padding(.leading, contentLeadingInset + layout.contentHorizontalPadding)
            .padding(.trailing, contentTrailingInset + layout.contentHorizontalPadding)
            .padding(.bottom, reservesPagerSpace ? layout.contentBottomPaddingWithPager : layout.contentBottomPaddingWithoutPager)
            .padding(.top, topInset + layout.contentTopPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: heroContentBlockAlignment)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func heroTitleBlockSpacing(for item: PlexItem) -> CGFloat {
        item.type == .movie ? 18 : 14
    }

    private var showsHeroSummary: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom != .phone
        #else
        true
        #endif
    }

    // iPhone centers the entire hero block — title logo, text, action button, and
    // pager — while iPad and tvOS keep the leading-aligned cinematic layout.
    private var centersHeroContent: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var heroContentHorizontalAlignment: HorizontalAlignment {
        centersHeroContent ? .center : .leading
    }

    private var heroContentFrameAlignment: Alignment {
        centersHeroContent ? .center : .leading
    }

    private var heroContentBlockAlignment: Alignment {
        centersHeroContent ? .bottom : .bottomLeading
    }

    private var heroTextAlignment: TextAlignment {
        centersHeroContent ? .center : .leading
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
                .frame(width: width, height: height, alignment: heroContentBlockAlignment)
        } else if failedHeroTitleImageKeys.contains(item.ratingKey) {
            heroTitleFallback(for: item)
        } else {
            Color.clear
                .frame(width: width, height: height, alignment: heroContentBlockAlignment)
        }
        #else
        heroTitleFallback(for: item)
        #endif
    }

    private func heroTitleFallback(for item: PlexItem) -> some View {
        // When a show/movie has no title-logo artwork, the title renders as text.
        // Force it white (rather than `Color.primary`) so it always reads against
        // the dark hero backdrop, even in Light mode. Only this fallback title is
        // affected — episode title, metadata, and summary keep `Color.primary`.
        Text(viewModel.displayTitle(for: item))
            .font(.system(size: layout.titleFontSize, weight: .heavy, design: .rounded))
            .foregroundStyle(Color.white)
            .lineLimit(3)
            .minimumScaleFactor(0.7)
            .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
            .multilineTextAlignment(heroTextAlignment)
            .frame(maxWidth: .infinity, alignment: heroContentFrameAlignment)
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
                duration: 0.42
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

    #if !os(tvOS)
    private func handleHeroDragChanged(_ value: DragGesture.Value) {
        handleHeroHorizontalNavigationChanged(
            horizontalOffset: value.translation.width,
            verticalOffset: value.translation.height
        )
    }

    private func handleHeroDragEnded(_ value: DragGesture.Value, heroWidth: CGFloat) {
        handleHeroHorizontalNavigationEnded(
            horizontalOffset: value.translation.width,
            verticalOffset: value.translation.height,
            predictedHorizontalOffset: value.predictedEndTranslation.width,
            heroWidth: heroWidth
        )
    }

    private func handleHeroHorizontalNavigationChanged(
        horizontalOffset: CGFloat,
        verticalOffset: CGFloat = 0
    ) {
        guard supportsDragNavigation,
              heroItemIDs.count > 1,
              transitioningHeroIndex == nil,
              !isHeroDragSettling else {
            return
        }

        guard abs(horizontalOffset) > abs(verticalOffset),
              abs(horizontalOffset) > 8 else {
            return
        }

        if !isHeroDragging {
            pauseHeroRotation()
            isHeroDragging = true
        }

        heroDragTargetIndex = adjacentHeroIndex(forDragOffset: horizontalOffset)
        heroDragOffset = resolvedHeroDragOffset(for: horizontalOffset)
    }

    private func handleHeroIndirectScrollChanged(horizontalOffset: CGFloat) {
        handleHeroHorizontalNavigationChanged(horizontalOffset: horizontalOffset)
    }

    private func handleHeroIndirectScrollEnded(
        horizontalOffset: CGFloat,
        predictedHorizontalOffset: CGFloat,
        heroWidth: CGFloat
    ) {
        let commitThreshold = max(min(heroWidth * 0.08, 96), 32)

        handleHeroHorizontalNavigationEnded(
            horizontalOffset: horizontalOffset,
            predictedHorizontalOffset: predictedHorizontalOffset,
            heroWidth: heroWidth,
            commitThreshold: commitThreshold
        )
    }

    private func handleHeroHorizontalNavigationEnded(
        horizontalOffset: CGFloat,
        verticalOffset: CGFloat = 0,
        predictedHorizontalOffset: CGFloat,
        heroWidth: CGFloat,
        commitThreshold: CGFloat? = nil
    ) {
        guard supportsDragNavigation, isHeroDragActive else { return }

        let horizontalDrag = abs(horizontalOffset) > abs(verticalOffset)
        let projectedOffset = resolvedHeroDragOffset(for: predictedHorizontalOffset)
        let commitThreshold = commitThreshold ?? max(heroWidth * 0.18, 56)
        let targetIndex = heroDragTargetIndex

        if horizontalDrag,
           let targetIndex,
           abs(projectedOffset) >= commitThreshold {
            completeHeroDragTransition(to: targetIndex, heroWidth: heroWidth)
        } else {
            cancelHeroDragTransition()
        }
    }
    #endif

    #if os(tvOS)
    private func handleHeroMoveCommand(_ direction: MoveCommandDirection) {
        switch direction {
        case .left:
            guard heroItemIDs.count > 1 else { return }
            showPreviousHero()
        case .right:
            guard heroItemIDs.count > 1 else { return }
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

    private func resetHeroDragState() {
        heroDragRevision += 1
        heroDragOffset = 0
        heroDragTargetIndex = nil
        isHeroDragging = false
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
        let imageAlignment = heroBackdropImageAlignment

        #if canImport(UIKit)
        if let image = preloadedHeroBackdropImages[item.ratingKey] {
            GeometryReader { geometry in
                ZStack {
                    Color.duskSurface

                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: imageAlignment)
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height,
                            alignment: imageAlignment
                        )
                        .clipped()
                }
                .frame(
                    width: geometry.size.width,
                    height: geometry.size.height,
                    alignment: imageAlignment
                )
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
                height: heroHeight,
                imageAlignment: imageAlignment
            )
        }
        #else
        DetailHeroBackdrop(
            imageURL: viewModel.heroBackgroundURL(
                for: item,
                width: width,
                height: height
            ),
            height: heroHeight,
            imageAlignment: imageAlignment
        )
        #endif
    }

    private var heroBackdropImageAlignment: Alignment {
        layout.backdropImageAlignment
    }

    private func moveHero(to index: Int, direction: HeroTransitionDirection, duration: TimeInterval) {
        resetHeroDragState()

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

    private func foregroundHeroOffset(width: CGFloat) -> CGFloat {
        if isHeroDragActive {
            return heroDragOffset
        }

        return heroSlideOffset(for: .incoming, width: width)
    }

    private func backgroundHeroOffset(width: CGFloat) -> CGFloat {
        if isHeroDragActive {
            guard let heroDragTargetIndex,
                  items.indices.contains(heroDragTargetIndex) else {
                return 0
            }

            if heroDragOffset < 0 {
                return width + heroDragOffset
            } else {
                return -width + heroDragOffset
            }
        }

        return heroSlideOffset(for: .outgoing, width: width)
    }

    private func adjacentHeroIndex(forDragOffset offset: CGFloat) -> Int? {
        guard heroItemIDs.count > 1 else { return nil }

        let heroCount = heroItemIDs.count

        if offset < 0 {
            return (currentHeroIndex + 1) % heroCount
        }

        if offset > 0 {
            return (currentHeroIndex - 1 + heroCount) % heroCount
        }

        return nil
    }

    private func resolvedHeroDragOffset(for rawOffset: CGFloat) -> CGFloat {
        guard rawOffset != 0 else { return 0 }

        guard adjacentHeroIndex(forDragOffset: rawOffset) != nil else {
            return rawOffset * 0.18
        }

        return rawOffset
    }

    private func completeHeroDragTransition(to index: Int, heroWidth: CGFloat) {
        guard heroWidth > 0 else {
            currentHeroIndex = index
            resetHeroDragState()
            restartHeroRotation()
            return
        }

        let dragRevision = heroDragRevision + 1
        let finalOffset = heroDragOffset < 0 ? -heroWidth : heroWidth
        let settleDuration = 0.24

        heroDragRevision = dragRevision
        isHeroDragging = false

        withAnimation(.easeOut(duration: settleDuration)) {
            heroDragOffset = finalOffset
        }

        Task {
            try? await Task.sleep(nanoseconds: UInt64((settleDuration * 1_000_000_000).rounded()))

            await MainActor.run {
                guard heroDragRevision == dragRevision else { return }
                currentHeroIndex = index
                resetHeroDragState()
                restartHeroRotation()
            }
        }
    }

    private func cancelHeroDragTransition() {
        let dragRevision = heroDragRevision + 1
        let settleDuration = 0.24

        heroDragRevision = dragRevision
        isHeroDragging = false

        withAnimation(.easeOut(duration: settleDuration)) {
            heroDragOffset = 0
        }

        Task {
            try? await Task.sleep(nanoseconds: UInt64((settleDuration * 1_000_000_000).rounded()))

            await MainActor.run {
                guard heroDragRevision == dragRevision else { return }
                resetHeroDragState()
                restartHeroRotation()
            }
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

#if os(iOS)
private struct HeroIndirectScrollNavigation: UIViewRepresentable {
    var isEnabled: Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isEnabled: isEnabled,
            onChanged: onChanged,
            onEnded: onEnded
        )
    }

    func makeUIView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: CaptureView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        uiView.coordinator = context.coordinator
        context.coordinator.installIfPossible(from: uiView)
    }

    static func dismantleUIView(_ uiView: CaptureView, coordinator: Coordinator) {
        coordinator.uninstall()
        uiView.coordinator = nil
    }

    final class CaptureView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            coordinator?.installIfPossible(from: self)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled: Bool
        var onChanged: (CGFloat) -> Void
        var onEnded: (CGFloat, CGFloat) -> Void

        private weak var hostView: UIView?
        private var panGesture: UIPanGestureRecognizer?
        private let projectedVelocityDuration: CGFloat = 0.18

        init(
            isEnabled: Bool,
            onChanged: @escaping (CGFloat) -> Void,
            onEnded: @escaping (CGFloat, CGFloat) -> Void
        ) {
            self.isEnabled = isEnabled
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func installIfPossible(from view: UIView) {
            guard let superview = view.superview else { return }
            install(on: superview)
        }

        func uninstall() {
            if let panGesture {
                hostView?.removeGestureRecognizer(panGesture)
            }

            hostView = nil
            panGesture = nil
        }

        private func install(on view: UIView) {
            guard hostView !== view else { return }

            uninstall()

            let panGesture = UIPanGestureRecognizer(
                target: self,
                action: #selector(handlePanGesture(_:))
            )
            panGesture.allowedScrollTypesMask = .all
            panGesture.cancelsTouchesInView = false
            panGesture.delaysTouchesBegan = false
            panGesture.delaysTouchesEnded = false
            panGesture.requiresExclusiveTouchType = false
            panGesture.delegate = self

            view.addGestureRecognizer(panGesture)
            hostView = view
            self.panGesture = panGesture
        }

        @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
            guard isEnabled, let hostView else { return }

            let translation = gesture.translation(in: hostView)
            let velocity = gesture.velocity(in: hostView)
            let predictedHorizontalOffset = translation.x + (velocity.x * projectedVelocityDuration)

            switch gesture.state {
            case .began, .changed:
                onChanged(translation.x)
            case .ended:
                onEnded(translation.x, predictedHorizontalOffset)
            case .cancelled, .failed:
                onEnded(translation.x, translation.x)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            isEnabled
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
#endif
