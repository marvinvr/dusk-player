#if os(macOS)
import Observation
import SwiftUI

/// Navigation state of the Mac's main window, shared by the sidebar shell
/// (`MacRootView`) and the menu bar (`MacCommands`).
///
/// The app owns one router for its one main window, so a menu command acts on
/// the window whatever has focus (the Settings window included). The sidebar
/// destinations reuse `MainTabItem`, and every destination keeps its own
/// `NavigationPath`, like a tab on iOS: switching away and back returns to the
/// same pushed screen.
@MainActor
@Observable
final class MacShellRouter {
    /// The sidebar selection.
    var selection: MainTabItem = .home
    /// The destinations the sidebar currently lists, in order. Published by
    /// `MacRootView` so the Go menu numbers them the same way.
    private(set) var destinations: [MainTabItem] = []
    /// True while the sidebar shell is on screen (not sign-in or the profile
    /// picker), which is when navigation commands apply.
    var isShellActive: Bool { mountedShells > 0 }
    /// A profile switch mounts the new shell before the old one disappears,
    /// so this counts rather than flips.
    private var mountedShells = 0

    /// Set by ⌘F and by choosing Search in the sidebar; the search screen
    /// focuses its field and clears it (`macSearchFocusRequests`).
    fileprivate(set) var isSearchFocusRequested = false
    /// Bumped by ⌘R per destination; the shell remounts that destination so
    /// its screens load again.
    private(set) var reloadRevisions: [MainTabItem: Int] = [:]

    var isHomeUserPickerPresented = false
    var isSignOutConfirmationPresented = false

    private var paths: [MainTabItem: NavigationPath] = [:]
    /// The profile the navigation state belongs to. A profile switch starts
    /// over at Home, like the iOS shell remounting per profile.
    private var sessionID: String?

    // MARK: Shell lifecycle

    func shellDidAppear(session: String?) {
        if session != sessionID {
            sessionID = session
            paths = [:]
            reloadRevisions = [:]
            selection = .home
        }
        mountedShells += 1
    }

    func shellDidDisappear() {
        mountedShells = max(mountedShells - 1, 0)
    }

    /// Keeps the selection on a destination that exists. A destination that
    /// disappears with server state (Live TV, Playlists, Downloads) falls back
    /// to Home and forgets its stack, as the iOS tab shell does.
    func updateDestinations(_ newDestinations: [MainTabItem]) {
        guard newDestinations != destinations else { return }
        destinations = newDestinations
        if !newDestinations.contains(selection) {
            paths[selection] = nil
            selection = .home
        }
    }

    // MARK: Navigation

    /// Selects a destination. Selecting the one already shown pops it to its
    /// root, like tapping the selected tab on iOS.
    func activate(_ destination: MainTabItem) {
        if selection == destination {
            popToRoot()
            return
        }
        selection = destination
        if destination == .search {
            isSearchFocusRequested = true
        }
    }

    func path(for destination: MainTabItem) -> NavigationPath {
        paths[destination] ?? NavigationPath()
    }

    func pathBinding(for destination: MainTabItem) -> Binding<NavigationPath> {
        Binding(
            get: { self.path(for: destination) },
            set: { self.paths[destination] = $0 }
        )
    }

    func setPath(_ path: NavigationPath, for destination: MainTabItem) {
        paths[destination] = path
    }

    var canGoBack: Bool {
        !path(for: selection).isEmpty
    }

    func goBack() {
        guard var path = paths[selection], !path.isEmpty else { return }
        path.removeLast()
        paths[selection] = path
    }

    func popToRoot() {
        guard canGoBack else { return }
        withAnimation {
            paths[selection] = NavigationPath()
        }
    }

    // MARK: Commands

    func focusSearch() {
        if selection != .search {
            selection = .search
        }
        isSearchFocusRequested = true
    }

    func reloadSelection() {
        reloadRevisions[selection, default: 0] += 1
    }

    func reloadRevision(for destination: MainTabItem) -> Int {
        reloadRevisions[destination, default: 0]
    }
}

extension View {
    /// Focuses a search field when ⌘F (Edit › Search) asks for it. Apply it on
    /// the Mac next to the screen's `.searchable(text:isPresented:)`, passing the
    /// same `isPresented` binding.
    func macSearchFocusRequests(isPresented: Binding<Bool>) -> some View {
        modifier(MacSearchFocusRequests(isPresented: isPresented))
    }
}

private struct MacSearchFocusRequests: ViewModifier {
    @Environment(MacShellRouter.self) private var router: MacShellRouter?
    let isPresented: Binding<Bool>

    func body(content: Content) -> some View {
        content
            // `initial`: the request usually arrives before the search screen
            // is mounted, since ⌘F switches to it first.
            .onChange(of: router?.isSearchFocusRequested ?? false, initial: true) { _, isRequested in
                guard isRequested, let router else { return }
                router.isSearchFocusRequested = false
                isPresented.wrappedValue = true
            }
    }
}
#endif
