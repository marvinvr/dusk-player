#if os(macOS)
import SwiftUI

/// A library type's sidebar destination (Movies, TV Shows, Videos) on the Mac:
/// one place with a segmented control in the toolbar, Recommended | Library |
/// Collections, like the TV app's mode switch, instead of iOS's three pushed
/// screens that were all titled "Movies". Collections only shows when the
/// library has any. With several libraries of the type, Recommended merges
/// them and the window title's menu picks the library Library/Collections
/// browse.
///
/// The modes are this view's state, so a detail page pushed from any of them
/// comes back to the same mode.
struct MacLibraryBrowser: View {
    @Environment(PlexService.self) private var plexService

    let libraryType: PlexLibraryType
    let libraries: [PlexLibrary]
    let viewModel: LibrariesViewModel
    @Binding var path: NavigationPath

    enum Mode: String, Hashable {
        case recommended
        case library
        case collections
    }

    @State private var mode: Mode = Self.initialMode
    @State private var selectedLibraryID: String?
    /// Library id → whether it has collections to browse (and has them on).
    @State private var collectionsAvailable: [String: Bool] = [:]

    var body: some View {
        content
            .environment(\.macUIHostsLibraryTitle, true)
            // The library picker is the window title's own menu
            // (`toolbarTitleMenu`), so there's one title, and the toolbar
            // keeps the same layout in every mode.
            .navigationTitle(windowTitle)
            .toolbarTitleMenu {
                if libraries.count > 1 {
                    Picker("Library", selection: titleMenuBinding) {
                        ForEach(libraries) { library in
                            Text(viewModel.displayTitle(for: library)).tag(Optional(library.id))
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mode) {
                        Text("Recommended").tag(Mode.recommended)
                        Text("Library").tag(Mode.library)
                        if showsCollectionsSegment {
                            Text("Collections").tag(Mode.collections)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .task(id: selectedLibrary.id) {
                await loadCollectionsAvailability(for: selectedLibrary)
            }
            // A library found to have no collections leaves Collections.
            .onChange(of: collectionsAvailable[selectedLibrary.id]) { _, available in
                if available == false, mode == .collections, !Self.holdsQACollectionsMode {
                    mode = .library
                }
            }
    }

    /// "Movies" in Recommended (it merges every library of the type); the
    /// picked library's name in Library/Collections when there are several.
    private var windowTitle: String {
        guard libraries.count > 1, mode != .recommended else { return libraryType.tabTitle }
        return viewModel.displayTitle(for: selectedLibrary)
    }

    /// Checks the browsed library in Library/Collections. In Recommended
    /// nothing is checked, and picking a library opens it in Library.
    private var titleMenuBinding: Binding<String?> {
        Binding(
            get: { mode == .recommended ? nil : selectedLibrary.id },
            set: { id in
                guard let id else { return }
                selectedLibraryID = id
                if mode == .recommended { mode = .library }
            }
        )
    }

    /// A third segment only for a library that has collections. Also kept
    /// while Collections is the current mode, so the switch never shows no
    /// selection (the availability check still running, or QA's
    /// `-DuskMacLibraryMode collections` on a library without any).
    private var showsCollectionsSegment: Bool {
        hasCollections || mode == .collections
    }

    @ViewBuilder
    private var content: some View {
        switch mode {
        case .recommended:
            LibraryRecommendationsView(
                libraries: libraries,
                plexService: plexService,
                navigationTitle: libraryType.tabTitle,
                browseTargets: libraries.map {
                    LibraryBrowseTarget(library: $0, title: viewModel.displayTitle(for: $0))
                },
                libraryListDestination: nil,
                push: { path.append($0) }
            )
            .id(libraries.map(\.id).joined(separator: "|"))
        case .library:
            LibraryItemsView(library: selectedLibrary, plexService: plexService)
                .id(selectedLibrary.id)
        case .collections:
            LibraryCollectionsView(library: selectedLibrary, plexService: plexService)
                .id(selectedLibrary.id)
        }
    }

    private var selectedLibrary: PlexLibrary {
        libraries.first { $0.id == selectedLibraryID } ?? libraries[0]
    }

    private var hasCollections: Bool {
        collectionsAvailable[selectedLibrary.id] == true
    }

    /// Same check as the library grid's Collections chip: the section's
    /// Collections setting isn't off and it has at least one.
    private func loadCollectionsAvailability(for library: PlexLibrary) async {
        guard collectionsAvailable[library.id] == nil else { return }
        guard library.libraryType == .movie || library.libraryType == .show else {
            collectionsAvailable[library.id] = false
            return
        }
        async let mode = plexService.collectionMode(sectionId: library.key, serverID: library.serverID)
        async let firstPage = try? plexService.getCollections(
            sectionId: library.key,
            size: 1,
            serverID: library.serverID
        )
        let resolvedMode = await mode
        let page = await firstPage
        guard !Task.isCancelled else { return }
        collectionsAvailable[library.id] = resolvedMode != .disabled && page?.items.isEmpty == false
    }

    /// QA screenshots of the Collections empty state keep the forced mode.
    private static var holdsQACollectionsMode: Bool {
        #if DEBUG
        UserDefaults.standard.string(forKey: "DuskMacLibraryMode") == Mode.collections.rawValue
        #else
        false
        #endif
    }

    private static var initialMode: Mode {
        #if DEBUG
        // QA screenshots: `-DuskMacLibraryMode library|collections`.
        if let raw = UserDefaults.standard.string(forKey: "DuskMacLibraryMode"),
           let mode = Mode(rawValue: raw) {
            return mode
        }
        #endif
        return .recommended
    }
}

extension EnvironmentValues {
    /// Set by `MacLibraryBrowser`, which titles the window itself (with the
    /// library menu); the Recommended/Library/Collections pages inside it
    /// then leave the title alone.
    @Entry var macUIHostsLibraryTitle = false
}

extension View {
    /// A library page's window title, unless `MacLibraryBrowser` hosts it.
    func macUILibraryPageTitle(_ title: String) -> some View {
        modifier(MacUILibraryPageTitle(title: title))
    }
}

private struct MacUILibraryPageTitle: ViewModifier {
    let title: String
    @Environment(\.macUIHostsLibraryTitle) private var isHosted

    func body(content: Content) -> some View {
        if isHosted {
            content
        } else {
            content.navigationTitle(title)
        }
    }
}
#endif
