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

    /// Set by ⌘F; the shell focuses the sidebar search field.
    var isSearchFocusRequested = false
    /// The sidebar search field's text (`.searchable(placement: .sidebar)` on
    /// the split view, like Music and TV). Typing shows the Search destination
    /// in the detail area; clearing it goes back to where the user was.
    var searchQuery = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            searchQueryDidChange()
        }
    }
    /// Where the user was when they started typing a search.
    private var destinationBeforeSearch: MainTabItem?
    /// Bumped by ⌘R per destination; the shell remounts that destination so
    /// its screens load again.
    private(set) var reloadRevisions: [MainTabItem: Int] = [:]

    var isHomeUserPickerPresented = false
    var isSignOutConfirmationPresented = false

    private var paths: [MainTabItem: NavigationPath] = [:]
    /// Per destination, the screens Back left (deepest last), so Forward
    /// (⌘]) can return to them. Snapshots of the whole path, because a
    /// `NavigationPath` can't hand its type-erased elements back.
    private var forwardPaths: [MainTabItem: [NavigationPath]] = [:]
    /// The profile the navigation state belongs to. A profile switch starts
    /// over at Home, like the iOS shell remounting per profile.
    private var sessionID: String?

    // MARK: Shell lifecycle

    func shellDidAppear(session: String?) {
        if session != sessionID {
            sessionID = session
            paths = [:]
            forwardPaths = [:]
            reloadRevisions = [:]
            searchQuery = ""
            destinationBeforeSearch = nil
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
        // Search has no sidebar row (its field is the sidebar's search field).
        if selection != .search, !newDestinations.contains(selection) {
            paths[selection] = nil
            forwardPaths[selection] = nil
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
        if destination != .search {
            // Picking a sidebar destination ends the search, as in Music.
            destinationBeforeSearch = nil
            searchQuery = ""
        }
    }

    private func searchQueryDidChange() {
        let isSearching = !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isSearching, selection != .search {
            destinationBeforeSearch = selection
            selection = .search
        } else if searchQuery.isEmpty, selection == .search, path(for: .search).isEmpty,
                  let previous = destinationBeforeSearch {
            // Cleared on the results page: back to where the search started.
            destinationBeforeSearch = nil
            selection = previous
        }
    }

    func path(for destination: MainTabItem) -> NavigationPath {
        paths[destination] ?? NavigationPath()
    }

    func pathBinding(for destination: MainTabItem) -> Binding<NavigationPath> {
        Binding(
            get: { self.path(for: destination) },
            set: { self.applyPath($0, for: destination) }
        )
    }

    func setPath(_ path: NavigationPath, for destination: MainTabItem) {
        paths[destination] = path
        forwardPaths[destination] = nil
    }

    /// A path change from the screens themselves (a link pushed, a pop):
    /// a pop remembers the screen it left for Forward, a push starts a new
    /// history, so Forward has nothing to return to.
    private func applyPath(_ newPath: NavigationPath, for destination: MainTabItem) {
        let oldPath = path(for: destination)
        if newPath.count < oldPath.count {
            forwardPaths[destination, default: []].append(oldPath)
        } else if newPath.count > oldPath.count {
            forwardPaths[destination] = nil
        }
        paths[destination] = newPath
    }

    var canGoBack: Bool {
        !path(for: selection).isEmpty
    }

    var canGoForward: Bool {
        !(forwardPaths[selection] ?? []).isEmpty
    }

    func goBack() {
        guard var path = paths[selection], !path.isEmpty else { return }
        forwardPaths[selection, default: []].append(path)
        path.removeLast()
        paths[selection] = path
    }

    func goForward() {
        guard var stack = forwardPaths[selection], let next = stack.popLast() else { return }
        forwardPaths[selection] = stack
        paths[selection] = next
    }

    func popToRoot() {
        guard canGoBack else { return }
        forwardPaths[selection, default: []].append(path(for: selection))
        withAnimation {
            paths[selection] = NavigationPath()
        }
    }

    // MARK: Commands

    /// ⌘F: focuses the sidebar search field. The results replace the detail
    /// area only once something is typed.
    func focusSearch() {
        isSearchFocusRequested = true
    }

    func reloadSelection() {
        reloadRevisions[selection, default: 0] += 1
    }

    func reloadRevision(for destination: MainTabItem) -> Int {
        reloadRevisions[destination, default: 0]
    }
}
#endif

#if os(macOS)
extension EnvironmentValues {
    /// True inside the main window's detail column, where the toolbar's
    /// back/forward pair (`MacRootView`) replaces each stack's own back button.
    /// False in the Settings window and sheets, which keep the system one.
    @Entry var macShellManagesBackNavigation = false
}

/// A pushed screen in the main window: the stack's own back button gives way
/// to the shell's back/forward pair, and the toolbar stays transparent (no
/// opaque band over a screen without a scroll view at its root). Toolbar
/// modifiers on the stack's container don't reach pushed screens, so each
/// one carries them itself.
struct MacShellBackButtonHiding: ViewModifier {
    @Environment(\.macShellManagesBackNavigation) private var shellManagesBack

    func body(content: Content) -> some View {
        if shellManagesBack {
            content
                .navigationBarBackButtonHidden(true)
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        MacShellBackForwardButtons()
                    }
                }
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}

/// Back and Forward for the main window's current destination (Go › Back
/// ⌘[ / Forward ⌘]).
struct MacShellBackForwardButtons: View {
    @Environment(MacShellRouter.self) private var router

    var body: some View {
        Button {
            router.goBack()
        } label: {
            Label("Back", systemImage: "chevron.left")
        }
        .disabled(!router.canGoBack)
        .help("Back")

        Button {
            router.goForward()
        } label: {
            Label("Forward", systemImage: "chevron.right")
        }
        .disabled(!router.canGoForward)
        .help("Forward")
    }
}
#endif
