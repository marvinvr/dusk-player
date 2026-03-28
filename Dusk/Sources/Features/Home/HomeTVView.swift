import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct HomeTVView: View {
    @FocusState private var isHeroPlayButtonFocused: Bool

    @Binding var path: NavigationPath

    let viewModel: HomeViewModel
    let serverName: String?
    let recentlyAddedInlineItemLimit: Int
    let play: (PlexItem) -> Void

    var body: some View {
        GeometryReader { geometry in
            let heroItems = viewModel.heroItems()
            let globalFrame = geometry.frame(in: .global)
            let screenWidth = max(fullDisplayWidth(fallback: geometry.size.width), geometry.size.width)
            let leadingContentInset = max(globalFrame.minX, 0)
            let trailingContentInset = max(screenWidth - globalFrame.maxX, 0)
            let heroContainerSize = CGSize(
                width: screenWidth,
                height: geometry.size.height
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !heroItems.isEmpty {
                        HomeCinematicHero(
                            items: heroItems,
                            viewModel: viewModel,
                            containerSize: heroContainerSize,
                            topInset: geometry.safeAreaInsets.top,
                            contentLeadingInset: leadingContentInset,
                            contentTrailingInset: trailingContentInset,
                            layout: .tv,
                            autoRotates: true,
                            supportsDragNavigation: false,
                            primaryAction: { item, callbacks in
                                AnyView(
                                    Button {
                                        callbacks.restartRotation()
                                        play(item)
                                    } label: {
                                        HomeHeroActionButtonLabel(
                                            title: viewModel.heroPrimaryActionTitle(for: item),
                                            systemImage: "play.fill"
                                        )
                                    }
                                    #if os(tvOS)
                                    .buttonStyle(.glassProminent)
                                    .tint(Color.duskAccent)
                                    .focused($isHeroPlayButtonFocused)
                                    .background(
                                        TVRemoteSwipeCapture(
                                            isEnabled: isHeroPlayButtonFocused,
                                            onSwipeLeft: callbacks.showPrevious,
                                            onSwipeRight: callbacks.showNext
                                        )
                                    )
                                    #endif
                                    .contextMenu {
                                        HomeItemContextMenu(
                                            item: item,
                                            detailsLabel: heroDetailsLabel(for: item),
                                            onMarkWatched: {
                                                Task { await viewModel.setWatched(true, for: item) }
                                            },
                                            onMarkUnwatched: {
                                                Task { await viewModel.setWatched(false, for: item) }
                                            },
                                            onSelectRoute: { route in
                                                path.append(route)
                                            }
                                        )
                                        .onAppear {
                                            callbacks.pauseRotation()
                                        }
                                        .onDisappear {
                                            callbacks.restartRotation()
                                        }
                                    }
                                    .accessibilityAddTraits(.isButton)
                                )
                            }
                        )
                        .frame(width: heroContainerSize.width)
                        .offset(x: -leadingContentInset)
                        .ignoresSafeArea(edges: .top)
                    } else if let serverName {
                        homeHeader(serverName: serverName)
                            .padding(.horizontal, DuskPosterMetrics.carouselHorizontalPadding)
                            .padding(.top, DuskPosterMetrics.pageSectionSpacing)
                    }

                    LazyVStack(alignment: .leading, spacing: DuskPosterMetrics.pageSectionSpacing) {
                        ForEach(viewModel.hubs) { hub in
                            let items = viewModel.inlineItems(
                                in: hub,
                                maxRecentlyAddedItems: recentlyAddedInlineItemLimit
                            )

                            if !items.isEmpty {
                                HomeHubCarouselSection(
                                    hub: hub,
                                    items: items,
                                    posterWidth: DuskPosterMetrics.carouselPosterWidth,
                                    showsShowAll: viewModel.shouldShowAll(
                                        for: hub,
                                        maxRecentlyAddedItems: recentlyAddedInlineItemLimit
                                    ),
                                    subtitle: { $0.year.map(String.init) },
                                    posterURL: { item, width, height in
                                        viewModel.posterURL(for: item, width: width, height: height)
                                    },
                                    onMarkWatched: { item in
                                        Task { await viewModel.setWatched(true, for: item) }
                                    },
                                    onMarkUnwatched: { item in
                                        Task { await viewModel.setWatched(false, for: item) }
                                    }
                                )
                            }
                        }

                        ForEach(viewModel.personalizedShelves) { shelf in
                            if !shelf.items.isEmpty {
                                HomePersonalizedCarouselSection(
                                    shelf: shelf,
                                    posterWidth: DuskPosterMetrics.carouselPosterWidth,
                                    showAllRoute: viewModel.showAllRoute(for: shelf),
                                    subtitle: { item in
                                        viewModel.subtitle(for: item)
                                    },
                                    posterURL: { item, width, height in
                                        viewModel.posterURL(for: item, width: width, height: height)
                                    },
                                    onMarkWatched: { item in
                                        Task { await viewModel.setWatched(true, for: item) }
                                    },
                                    onMarkUnwatched: { item in
                                        Task { await viewModel.setWatched(false, for: item) }
                                    }
                                )
                            }
                        }
                    }
                    .padding(.top, heroItems.isEmpty ? 56 : 44)
                    .padding(.bottom, DuskPosterMetrics.pageBottomPadding)
                }
                .frame(width: geometry.size.width, alignment: .leading)
                .padding(.top, heroItems.isEmpty ? 24 : -geometry.safeAreaInsets.top)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentMargins(.zero, for: .scrollContent)
            .contentMargins(.zero, for: .scrollIndicators)
            .scrollIndicators(.hidden)
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
        }
    }

    private func fullDisplayWidth(fallback: CGFloat) -> CGFloat {
        #if canImport(UIKit)
        if let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }) {
            return windowScene.screen.bounds.width
        }

        return fallback
        #else
        fallback
        #endif
    }

    private func homeHeader(serverName: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Home")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(Color.duskTextPrimary)

            Text(serverName)
                .font(.title3)
                .foregroundStyle(Color.duskTextSecondary)
        }
    }

    private func heroDetailsLabel(for item: PlexItem) -> String {
        switch item.type {
        case .episode:
            return "Episode Details"
        case .season:
            return "Season Details"
        case .show:
            return "Show Details"
        case .movie:
            return "Movie Details"
        default:
            return "View Details"
        }
    }
}

#if os(tvOS)
private struct TVRemoteSwipeCapture: UIViewRepresentable {
    let isEnabled: Bool
    let onSwipeLeft: () -> Void
    let onSwipeRight: () -> Void

    func makeUIView(context: Context) -> SwipeCaptureView {
        let view = SwipeCaptureView()
        view.backgroundColor = .clear
        view.update(
            isEnabled: isEnabled,
            onSwipeLeft: onSwipeLeft,
            onSwipeRight: onSwipeRight
        )
        return view
    }

    func updateUIView(_ uiView: SwipeCaptureView, context: Context) {
        uiView.update(
            isEnabled: isEnabled,
            onSwipeLeft: onSwipeLeft,
            onSwipeRight: onSwipeRight
        )
    }
}

private final class SwipeCaptureView: UIView, UIGestureRecognizerDelegate {
    private weak var attachedView: UIView?
    private lazy var swipeLeftRecognizer: UISwipeGestureRecognizer = {
        let recognizer = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        recognizer.direction = .left
        recognizer.delegate = self
        return recognizer
    }()
    private lazy var swipeRightRecognizer: UISwipeGestureRecognizer = {
        let recognizer = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        recognizer.direction = .right
        recognizer.delegate = self
        return recognizer
    }()

    private var isSwipeCaptureEnabled = false
    private var onSwipeLeft: () -> Void = {}
    private var onSwipeRight: () -> Void = {}

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        attachRecognizersIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachRecognizersIfNeeded()
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview == nil {
            detachRecognizers()
        }

        super.willMove(toSuperview: newSuperview)
    }

    func update(
        isEnabled: Bool,
        onSwipeLeft: @escaping () -> Void,
        onSwipeRight: @escaping () -> Void
    ) {
        isSwipeCaptureEnabled = isEnabled
        self.onSwipeLeft = onSwipeLeft
        self.onSwipeRight = onSwipeRight
        attachRecognizersIfNeeded()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    @objc
    private func handleSwipe(_ recognizer: UISwipeGestureRecognizer) {
        guard isSwipeCaptureEnabled else { return }

        switch recognizer.direction {
        case .left:
            onSwipeLeft()
        case .right:
            onSwipeRight()
        default:
            break
        }
    }

    private func attachRecognizersIfNeeded() {
        guard let targetView = superview else { return }
        guard attachedView !== targetView else { return }

        detachRecognizers()
        targetView.addGestureRecognizer(swipeLeftRecognizer)
        targetView.addGestureRecognizer(swipeRightRecognizer)
        attachedView = targetView
    }

    private func detachRecognizers() {
        attachedView?.removeGestureRecognizer(swipeLeftRecognizer)
        attachedView?.removeGestureRecognizer(swipeRightRecognizer)
        attachedView = nil
    }
}
#endif
