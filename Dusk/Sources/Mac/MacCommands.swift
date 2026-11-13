#if os(macOS)
import SwiftUI

/// The menu bar of the Mac app, apart from the Playback menu
/// (`MacPlayerCommands`).
///
/// - App menu: Switch User… (Plex Home accounts) and Sign Out… under Settings.
/// - Edit: Search ⌘F in place of the text Find/Spelling group.
/// - View: Refresh ⌘R, plus the standard sidebar toggle (`SidebarCommands`).
/// - Go: Back ⌘[, Forward ⌘] and one item per sidebar destination, ⌘1
///   through ⌘9.
///
/// Every item acts on the main window through `MacShellRouter`, so the menus
/// work whichever window is key, and stand down while the player is up or the
/// main window shows sign-in or the profile picker.
struct MacCommands: Commands {
    let router: MacShellRouter
    let connections: ServerConnectionCoordinator
    let plexService: PlexService
    let playback: PlaybackCoordinator

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        SidebarCommands()

        // About Dusk: the standard panel, with the project links as credits.
        CommandGroup(replacing: .appInfo) {
            Button("About Dusk") {
                MacAboutPanel.show()
            }
        }

        CommandGroup(after: .appSettings) {
            if plexService.hasPlexHome {
                Button("Switch User…") {
                    showMainWindow()
                    router.isHomeUserPickerPresented = true
                }
                .disabled(!canNavigate)
            }

            Button("Sign Out…") {
                showMainWindow()
                router.isSignOutConfirmationPresented = true
            }
            .disabled(!router.isShellActive || playback.showPlayer)
        }

        CommandGroup(replacing: .textEditing) {
            Button("Search") {
                showMainWindow()
                router.focusSearch()
            }
            .keyboardShortcut("f")
            .disabled(!canNavigate)
        }

        CommandGroup(before: .sidebar) {
            Button("Refresh") {
                router.reloadSelection()
                Task { await connections.refresh(trigger: "Menu") }
            }
            .keyboardShortcut("r")
            .disabled(!canNavigate)

            Divider()
        }

        CommandMenu("Go") {
            Button("Back") {
                router.goBack()
            }
            .keyboardShortcut("[")
            .disabled(!canNavigate || !router.canGoBack)

            Button("Forward") {
                router.goForward()
            }
            .keyboardShortcut("]")
            .disabled(!canNavigate || !router.canGoForward)

            Divider()

            ForEach(Array(router.destinations.enumerated()), id: \.element) { index, destination in
                destinationButton(destination, index: index)
            }
        }
    }

    @ViewBuilder
    private func destinationButton(_ destination: MainTabItem, index: Int) -> some View {
        let button = Button(destination.title) {
            showMainWindow()
            router.activate(destination)
        }
        .disabled(!canNavigate)

        if index < 9 {
            button.keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
        } else {
            button
        }
    }

    private var canNavigate: Bool {
        router.isShellActive && !playback.showPlayer
    }

    /// Commands can fire from the Settings window; bring the main window
    /// forward so the result is visible.
    private func showMainWindow() {
        openWindow(id: MacWindow.mainID)
    }
}
#endif
