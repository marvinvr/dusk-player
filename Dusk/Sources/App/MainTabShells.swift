import SwiftUI
import UIKit

enum MainTabItem: Hashable, Identifiable {
    case home
    case library(PlexLibraryType)
    case liveTV
    case playlists
    case downloads
    case search
    case settings
    case more

    var id: Self { self }

    var title: String {
        switch self {
        case .home:
            "Home"
        case .library(let libraryType):
            libraryType.tabTitle
        case .liveTV:
            "Live TV"
        case .playlists:
            "Playlists"
        case .downloads:
            "Downloads"
        case .search:
            "Search"
        case .settings:
            "Settings"
        case .more:
            "More"
        }
    }

    var systemImage: String {
        switch self {
        case .home:
            "house"
        case .library(let libraryType):
            libraryType.systemImage
        case .liveTV:
            "dot.radiowaves.left.and.right"
        case .playlists:
            PlexLibraryType.playlists.systemImage
        case .downloads:
            "arrow.down.circle"
        case .search:
            "magnifyingglass"
        case .settings:
            "gearshape"
        case .more:
            "ellipsis"
        }
    }
}

struct MainTabIOSShell<Content: View>: View {
    let tabs: [MainTabItem]
    let selection: Binding<MainTabItem>
    let content: (MainTabItem) -> Content

    var body: some View {
        TabView(selection: selection) {
            ForEach(tabs) { tab in
                Tab(
                    tab.title,
                    systemImage: tab.systemImage,
                    value: tab
                ) {
                    content(tab)
                }
            }
        }
        #if os(iOS)
        .background(DuskDuoTabBarLabelRefresher())
        #endif
    }
}

#if os(iOS)

/// iPhone Duo: after a live unfold the tab bar could keep the labels it had
/// truncated for the narrow cover display ("Ho…", "M…") until a relaunch.
/// Setting each item's title again makes UIKit measure it anew. Runs only
/// when the size class changes on a Duo display; never on other devices.
private struct DuskDuoTabBarLabelRefresher: UIViewRepresentable {
    func makeUIView(context: Context) -> DuskDuoTabBarLabelRefreshView {
        DuskDuoTabBarLabelRefreshView()
    }

    func updateUIView(_ uiView: DuskDuoTabBarLabelRefreshView, context: Context) {}
}

private final class DuskDuoTabBarLabelRefreshView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (view: DuskDuoTabBarLabelRefreshView, _) in
            view.refreshTabBarLabels()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func refreshTabBarLabels() {
        guard DuskDuoDisplay.isActive else { return }
        // After the unfold's layout pass, which is what truncated them.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let window = self?.window, let tabBar = Self.firstTabBar(in: window) else { return }
            for item in tabBar.items ?? [] {
                let title = item.title
                item.title = nil
                item.title = title
            }
        }
    }

    private static func firstTabBar(in view: UIView) -> UITabBar? {
        if let tabBar = view as? UITabBar {
            return tabBar
        }
        for subview in view.subviews {
            if let tabBar = firstTabBar(in: subview) {
                return tabBar
            }
        }
        return nil
    }
}
#endif

struct MainTabTVShell<Content: View>: View {
    let tabs: [MainTabItem]
    let selection: Binding<MainTabItem>
    /// Runs on a Siri Remote Back press at the root of the selected tab; `nil`
    /// leaves the press to the system. See `MainTabView.rootBackAction`.
    let rootBackAction: (() -> Void)?
    let content: (MainTabItem) -> Content

    var body: some View {
        TabView(selection: selection) {
            ForEach(tabs) { tab in
                content(tab)
                    // The bar's tint below would otherwise reach every tab's
                    // content, and an explicit tint makes system glass buttons
                    // go white-on-white on focus. Content gets no tint at all.
                    .tint(nil)
                    .background {
                        DuskTVTabBarTintPin()
                            .frame(width: 0, height: 0)
                    }
                    .tag(tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                            .symbolRenderingMode(.monochrome)
                    }
            }
        }
        .tint(Color.duskTVTabBarTint)
        .background(Color.duskBackground.ignoresSafeArea())
        #if os(tvOS)
        .background {
            DuskTVRootBackInterceptor(action: rootBackAction)
                .frame(width: 0, height: 0)
        }
        #endif
    }
}

#if os(tvOS)
/// Zero-size helper that takes the Siri Remote's Back press away from the
/// system at the root of a tab, where tvOS would otherwise leave the app.
///
/// SwiftUI's `onExitCommand` cannot do this: it only fires while focus is in
/// the tab's content, and Back with focus on the tab bar goes straight to the
/// system. A Back-only tap recognizer on the tab bar controller's view sees
/// the press wherever focus is in the shell, tab bar included. Anything
/// presented on top (the player, sheets, menus) lives outside that view, so
/// it never sees their presses.
///
/// The recognizer refuses the press, leaving the system's behaviour intact,
/// whenever there is no action or the selected tab has a pushed screen: the
/// navigation stack's own pop must win there. It also refuses while focus is
/// in search results, where Back returns to the search keyboard instead.
///
/// One exception on a pushed screen: with focus on the tab bar, outside the
/// stack, the stack never sees Back and tvOS would leave the app (#62). The
/// recognizer takes that press and pops the stack itself.
private struct DuskTVRootBackInterceptor: UIViewControllerRepresentable {
    let action: (() -> Void)?

    func makeUIViewController(context: Context) -> DuskTVRootBackController {
        DuskTVRootBackController()
    }

    func updateUIViewController(_ uiViewController: DuskTVRootBackController, context: Context) {
        uiViewController.action = action
        uiViewController.installIfNeeded()
    }
}

private final class DuskTVRootBackController: UIViewController, UIGestureRecognizerDelegate {
    var action: (() -> Void)?

    private weak var shellTabBarController: UITabBarController?

    private lazy var recognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleBack))
        recognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        // Presses only: a tap on the remote's touch surface is not Back.
        recognizer.allowedTouchTypes = []
        recognizer.delegate = self
        return recognizer
    }()

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        installIfNeeded()
    }

    /// Attaches the recognizer to the shell's tab bar controller, moving it if
    /// SwiftUI has rebuilt that controller since the last look.
    func installIfNeeded() {
        guard let tabBarController = resolvedTabBarController() else { return }
        guard recognizer.view !== tabBarController.view else { return }
        recognizer.view?.removeGestureRecognizer(recognizer)
        tabBarController.view.addGestureRecognizer(recognizer)
        shellTabBarController = tabBarController
    }

    @objc private func handleBack() {
        // `shouldReceive` only lets a press through on a pushed screen when
        // focus is outside it (on the tab bar); pop that stack.
        if let tabBarController = shellTabBarController,
           let navigationController = Self.pushedNavigationController(
               in: tabBarController.selectedViewController ?? tabBarController
           ) {
            navigationController.popViewController(animated: true)
            return
        }
        action?()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive press: UIPress) -> Bool {
        guard let tabBarController = shellTabBarController else { return false }
        guard tabBarController.presentedViewController == nil else { return false }
        let selected = tabBarController.selectedViewController ?? tabBarController
        let focusedItem = tabBarController.view.window?.windowScene?.focusSystem?.focusedItem
        if Self.hasPushedScreen(in: selected) {
            // Focus inside the tab's content: the stack's own pop wins. Focus
            // on the tab bar: the stack never sees the press, so take it.
            guard let focusedItem, selected !== tabBarController else { return false }
            return !Self.isFocusItem(focusedItem, inside: selected)
        }
        guard action != nil else { return false }
        return !Self.isInSearchResults(focusedItem)
    }

    /// Whether `item`'s focus chain passes through `controller`.
    private static func isFocusItem(_ item: UIFocusItem, inside controller: UIViewController) -> Bool {
        var environment: UIFocusEnvironment? = item
        while let current = environment {
            if current === controller { return true }
            environment = current.parentFocusEnvironment
        }
        return false
    }

    /// Whether `item` sits in a search controller's results rather than on
    /// its keyboard. Back from the results goes to the search screen itself,
    /// which moves focus up to the keyboard to edit the query.
    private static func isInSearchResults(_ item: UIFocusItem?) -> Bool {
        var lastController: UIViewController?
        var environment: UIFocusEnvironment? = item
        while let current = environment {
            if let searchController = current as? UISearchController {
                return lastController != nil && lastController === searchController.searchResultsController
            }
            if let controller = current as? UIViewController {
                lastController = controller
            }
            environment = current.parentFocusEnvironment
        }
        return false
    }

    /// Whether any navigation stack inside `controller` shows more than its
    /// root. SwiftUI's `NavigationStack` is a `UINavigationController` under
    /// the hood, which also covers `NavigationLink(destination:)` pushes that
    /// never appear in the tab's `NavigationPath`.
    private static func hasPushedScreen(in controller: UIViewController) -> Bool {
        pushedNavigationController(in: controller) != nil
    }

    /// The innermost navigation stack inside `controller` that shows more
    /// than its root: the one a Back press pops.
    private static func pushedNavigationController(in controller: UIViewController) -> UINavigationController? {
        for child in controller.children {
            if let nested = pushedNavigationController(in: child) {
                return nested
            }
        }
        if let navigationController = controller as? UINavigationController,
           navigationController.viewControllers.count > 1 {
            return navigationController
        }
        return nil
    }

    private func resolvedTabBarController() -> UITabBarController? {
        // The helper sits beside the `TabView`, not inside it, so the tab bar
        // controller is not in its parent chain. Search from the window root.
        guard let root = view.window?.rootViewController else { return nil }
        return Self.firstTabBarController(in: root)
    }

    private static func firstTabBarController(in controller: UIViewController) -> UITabBarController? {
        if let tabBarController = controller as? UITabBarController {
            return tabBarController
        }
        for child in controller.children {
            if let tabBarController = firstTabBarController(in: child) {
                return tabBarController
            }
        }
        return nil
    }
}
#endif

/// Zero-size helper that keeps the tvOS tab bar tinted with
/// `Color.duskTVTabBarTint`.
///
/// SwiftUI's `.tint` on the tvOS `TabView` is not sticky: returning from a
/// pushed detail screen or from the full-screen player can leave the real
/// `UITabBar` back on the inherited window tint. When the global accent was
/// still Sunset Coral that painted the selected tab item coral. Pinning the
/// bar's own `tintColor` makes it explicit, so it no longer inherits, and
/// re-pinning on every shell update repairs it if SwiftUI overwrites it again.
/// A zero-size sentinel view inside the bar catches every later tint change
/// UIKit reports and re-pins, so the repair does not depend on SwiftUI
/// scheduling another shell update. The window tint itself is now the same
/// label color (`AccentColor` in the asset catalog), so even a bar that does
/// inherit has no coral to inherit.
private struct DuskTVTabBarTintPin: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> DuskTVTabBarTintController {
        DuskTVTabBarTintController()
    }

    func updateUIViewController(_ uiViewController: DuskTVTabBarTintController, context: Context) {
        uiViewController.pinTabBarTint()
    }
}

private final class DuskTVTabBarTintController: UIViewController {
    private var hasPendingPin = false

    private lazy var sentinel: DuskTVTabBarTintSentinel = {
        let sentinel = DuskTVTabBarTintSentinel(frame: .zero)
        sentinel.isUserInteractionEnabled = false
        sentinel.backgroundColor = .clear
        sentinel.onTintColorChange = { [weak self] in
            self?.scheduleTabBarTintRepair()
        }
        return sentinel
    }()

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        pinTabBarTint()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        pinTabBarTint()
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        pinTabBarTint()
    }

    func pinTabBarTint() {
        applyTabBarTint()

        // A navigation pop or player dismissal can re-tint the bar later in the
        // same update pass, so take a second look once the run loop settles.
        scheduleTabBarTintRepair()
    }

    /// Re-applies the tint on the next run loop turn. Used both after a shell
    /// update and when the sentinel reports that the bar's tint changed, which
    /// keeps the repair out of UIKit's own tint-change notification pass.
    private func scheduleTabBarTintRepair() {
        guard !hasPendingPin else { return }
        hasPendingPin = true
        DispatchQueue.main.async { [weak self] in
            self?.hasPendingPin = false
            self?.applyTabBarTint()
        }
    }

    private func applyTabBarTint() {
        guard let tabBar = resolvedTabBar() else { return }
        installSentinel(in: tabBar)
        guard tabBar.tintColor != UIColor.duskTVTabBarTint else { return }
        tabBar.tintColor = .duskTVTabBarTint
    }

    private func installSentinel(in tabBar: UITabBar) {
        guard sentinel.superview !== tabBar else { return }
        sentinel.removeFromSuperview()
        tabBar.addSubview(sentinel)
    }

    private func resolvedTabBar() -> UITabBar? {
        if let tabBar = tabBarController?.tabBar {
            return tabBar
        }
        // The shell is always hosted in a tab bar controller today; the view
        // search only covers a host that keeps the bar outside the parent chain.
        guard let window = view.window else { return nil }
        return Self.firstTabBar(in: window)
    }

    private static func firstTabBar(in view: UIView) -> UITabBar? {
        if let tabBar = view as? UITabBar {
            return tabBar
        }

        for subview in view.subviews {
            if let tabBar = firstTabBar(in: subview) {
                return tabBar
            }
        }

        return nil
    }
}

/// Invisible subview of the tab bar. UIKit calls `tintColorDidChange()` on
/// every subview whenever the bar's effective tint changes, explicit or
/// inherited, which is the one hook that fires no matter who re-tinted the bar.
private final class DuskTVTabBarTintSentinel: UIView {
    var onTintColorChange: (() -> Void)?

    override func tintColorDidChange() {
        super.tintColorDidChange()
        onTintColorChange?()
    }
}
