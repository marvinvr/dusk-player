import SwiftUI

/// A playlist: the detail hero (no clear-logo, the first item's art behind
/// it) with Play/Resume, Shuffle and More, over the items in playlist order.
/// Selecting an item plays the playlist from there; playback then continues
/// through the following items (`PlaybackQueue`), watched ones included.
///
/// iOS builds the page as one `List` so rows get the native swipe-to-delete
/// and Edit-mode drag reorder; tvOS uses a focusable row stack and edits
/// through each row's context menu (no reorder on a remote).
struct PlaylistDetailView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: PlaylistDetailViewModel
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isConfirmingDelete = false
    // The Mac has no edit mode: rows drag to reorder, and Remove is in the
    // context menu.
    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    init(id: PlexItemID, plexService: PlexService) {
        _viewModel = State(initialValue: PlaylistDetailViewModel(id: id, plexService: plexService))
    }

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if let error = viewModel.error, viewModel.playlist == nil || !viewModel.hasLoadedEntries {
                FeatureErrorView(message: error) {
                    Task { await viewModel.load() }
                }
            } else if viewModel.playlist == nil {
                FeatureLoadingView()
            } else {
                content
            }
        }
        .duskNavigationBarTitleDisplayModeInline()
        #if !os(macOS)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        #if os(iOS)
        .toolbar {
            if editMode.isEditing {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        withAnimation { editMode = .inactive }
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        #endif
        .task {
            await viewModel.load()
        }
        .onChange(of: playback.showPlayer) { _, isShowing in
            if !isShowing {
                Task { await viewModel.refresh() }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await viewModel.refresh() }
        }
        .alert("Rename Playlist", isPresented: $isRenaming) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let title = renameText
                Task { await viewModel.rename(to: title) }
            }
        }
        .confirmationDialog(
            "Delete “\(viewModel.title)”?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Playlist", role: .destructive) {
                Task {
                    if await viewModel.delete() {
                        dismiss()
                    }
                }
            }
        } message: {
            Text("This removes the playlist from Plex on every device. The movies and episodes in it stay in your library.")
        }
        .alert("Something went wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.actionError ?? "")
        }
    }

    // MARK: - Layout

    @ViewBuilder
    private var content: some View {
        GeometryReader { geometry in
            #if os(tvOS)
            let backgroundWidth = geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero(
                        topInset: geometry.safeAreaInsets.top,
                        containerWidth: backgroundWidth,
                        containerHeight: geometry.size.height,
                        backgroundLeadingInset: geometry.safeAreaInsets.leading
                    )
                    .focusSection()

                    tvRows
                        .padding(.horizontal, DuskPosterMetrics.detailHorizontalPadding)
                        .padding(.top, 24)
                        .padding(.bottom, 64)
                        .focusSection()
                }
                .padding(.top, -geometry.safeAreaInsets.top)
                // The hero's backdrop is wider than the page; the rows are not.
                .frame(width: geometry.size.width, alignment: .topLeading)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .duskTVOSPageBackground()
            #else
            List {
                hero(
                    topInset: geometry.safeAreaInsets.top,
                    containerWidth: geometry.size.width,
                    containerHeight: geometry.size.height,
                    backgroundLeadingInset: 0
                )
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .moveDisabled(true)
                .deleteDisabled(true)

                if detailShowsSynopsisBelowHero(for: sizeClass), let summary = viewModel.summary {
                    ExpandableSummaryText(text: summary, collapsedLineLimit: 4)
                        .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 8, trailing: 20))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .moveDisabled(true)
                        .deleteDisabled(true)
                }

                iosRows
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 0, for: .scrollContent)
            .ignoresSafeArea(edges: .top)
            .scrollIndicators(.hidden)
            #endif
        }
    }

    private func hero(
        topInset: CGFloat,
        containerWidth: CGFloat,
        containerHeight: CGFloat,
        backgroundLeadingInset: CGFloat
    ) -> some View {
        // Shorter than a movie's hero: the items below are the content.
        let heroBase = min(max(containerHeight * 0.55, 400), 600)
        let heroHeight = heroBase + topInset

        return DetailHeroSection(
            backdropURL: viewModel.backdropURL(
                width: Int(containerWidth.rounded(.up)),
                height: Int(heroHeight.rounded(.up))
            ),
            title: viewModel.title,
            descriptionText: viewModel.summary,
            topInset: topInset,
            containerWidth: containerWidth,
            backgroundLeadingInset: backgroundLeadingInset,
            heroBaseHeight: heroBase,
            leadsWithTextTitle: true
        ) {
            if let metadata = viewModel.metadataLine {
                Text(metadata)
                    .font(DuskFont.metadata(ios: .subheadline.weight(.medium)))
                    .foregroundStyle(Color.primary.opacity(0.78))
                    .multilineTextAlignment(detailHeroTextAlignment(for: sizeClass))
            }
        } actions: {
            if viewModel.hasLoadedEntries {
                actionButtons
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        #if os(tvOS)
        HStack(spacing: detailHeroActionSpacing) {
            playButton
            shuffleButton
            moreMenu
        }
        #else
        VStack(alignment: .center, spacing: detailHeroActionSpacing) {
            playButton

            HStack(spacing: detailHeroActionSpacing) {
                shuffleButton
                moreMenu
            }
        }
        .detailHeroActionStackFrame(isCompactPhone: usesFullWidthDetailActionButtons(for: sizeClass))
        #endif
    }

    private var playButton: some View {
        Button {
            play(viewModel.resumeQueue())
        } label: {
            DetailHeroPrimaryActionButtonLabel(
                title: viewModel.playButtonTitle,
                systemImage: "play.fill",
                fillsWidth: fillsActionWidth
            )
        }
        .detailHeroNativePrimaryButtonStyle()
        .disabled(!viewModel.canPlay)
        #if !os(tvOS)
        .contextMenu {
            Button {
                play(viewModel.queueFromBeginning(), fromStart: true)
            } label: {
                Label("Play from Beginning", systemImage: "arrow.counterclockwise")
            }
            .duskMenuItemIcons()
        }
        #endif
    }

    private var shuffleButton: some View {
        Button {
            play(viewModel.shuffledQueue(), fromStart: true)
        } label: {
            DetailHeroSecondaryIconLabel(systemImage: "shuffle", title: "Shuffle")
        }
        .detailHeroNativeSecondaryButtonStyle()
        .disabled(!viewModel.canPlay)
        .accessibilityLabel("Shuffle")
    }

    private var moreMenu: some View {
        Menu {
            Button {
                play(viewModel.queueFromBeginning(), fromStart: true)
            } label: {
                Label("Play from Beginning", systemImage: "arrow.counterclockwise")
            }
            .disabled(!viewModel.canPlay)

            if let playlist = viewModel.playlist {
                PinPlaylistToHomeButton(playlist: playlist)
            }

            if viewModel.canEdit {
                #if os(iOS)
                Button {
                    withAnimation { editMode = .active }
                } label: {
                    Label("Edit", systemImage: "list.bullet")
                }
                .disabled(viewModel.entries.isEmpty)
                #endif

                Button {
                    renameText = viewModel.title
                    isRenaming = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }

            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("Delete Playlist", systemImage: "trash")
            }

            if viewModel.isSmart {
                Section {
                    Text("Edit this smart playlist’s filters in Plex Web.")
                }
            }
        } label: {
            DetailHeroSecondaryIconLabel(systemImage: "ellipsis", title: "More")
        }
        .detailHeroNativeSecondaryButtonStyle()
        .accessibilityLabel("More")
    }

    private var fillsActionWidth: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    // MARK: - Rows

    #if !os(tvOS)
    @ViewBuilder
    private var iosRows: some View {
        if viewModel.entries.isEmpty {
            FeatureEmptyStateView(
                systemImage: PlexLibraryType.playlists.systemImage,
                title: "This playlist is empty"
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .moveDisabled(true)
            .deleteDisabled(true)
        } else {
            ForEach(viewModel.entries) { entry in
                Button {
                    play(viewModel.queue(startingAt: entry))
                } label: {
                    PlaylistEntryRow(
                        item: entry.item,
                        thumbnailURL: viewModel.thumbnailURL(for: entry.item, width: 320, height: 180)
                    )
                }
                .buttonStyle(.plain)
                #if os(iOS)
                // Not `.disabled`: that greys the rows out while reordering.
                .allowsHitTesting(!editMode.isEditing)
                #endif
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Color.duskTextSecondary.opacity(0.2))
                .contextMenu {
                    entryContextMenu(entry)
                        .duskMenuItemIcons()
                }
                .deleteDisabled(!viewModel.canEdit)
                .moveDisabled(!viewModel.canEdit)
            }
            .onDelete { offsets in
                viewModel.remove(atOffsets: offsets)
            }
            .onMove { source, destination in
                viewModel.move(fromOffsets: source, toOffset: destination)
            }
        }
    }
    #endif

    #if os(tvOS)
    @ViewBuilder
    private var tvRows: some View {
        if viewModel.entries.isEmpty {
            FeatureEmptyStateView(
                systemImage: PlexLibraryType.playlists.systemImage,
                title: "This playlist is empty"
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(viewModel.entries) { entry in
                    PlaylistTVEntryButton(
                        item: entry.item,
                        thumbnailURL: viewModel.thumbnailURL(for: entry.item, width: 400, height: 225)
                    ) {
                        play(viewModel.queue(startingAt: entry))
                    }
                    .contextMenu {
                        entryContextMenu(entry)
                    }
                }
            }
        }
    }
    #endif

    @ViewBuilder
    private func entryContextMenu(_ entry: PlexPlaylistEntry) -> some View {
        Button {
            play(viewModel.queue(startingAt: entry))
        } label: {
            Label("Play from Here", systemImage: "play.fill")
        }

        PlexItemContextMenuContent(
            item: entry.item,
            onMarkWatched: {
                Task { await viewModel.setWatched(true, for: entry) }
            },
            onMarkUnwatched: {
                Task { await viewModel.setWatched(false, for: entry) }
            },
            detailsRoute: AppNavigationRoute.destination(for: entry.item),
            detailsLabel: "Go to Details",
            showsAddToPlaylist: false
        )

        if viewModel.canEdit, entry.playlistItemID != nil {
            Button(role: .destructive) {
                Task { await viewModel.remove(entry) }
            } label: {
                Label("Remove from Playlist", systemImage: "minus.circle")
            }
        }
    }

    // MARK: - Actions

    private func play(_ queue: PlaybackQueue?, fromStart: Bool = false) {
        guard let queue else { return }
        Task {
            await playback.playQueue(queue, fromStart: fromStart)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.actionError != nil },
            set: { if !$0 { viewModel.actionError = nil } }
        )
    }
}

// MARK: - Pin to Home

/// "Pin to Home" / "Unpin from Home" for a playlist's menus: a pinned
/// playlist gets its own row near the top of Home (`HomePinnedPlaylistShelf`).
struct PinPlaylistToHomeButton: View {
    @Environment(PlexService.self) private var plexService
    let playlist: PlexPlaylist

    var body: some View {
        let isPinned = plexService.isPlaylistPinned(playlist.id)
        Button {
            plexService.setPlaylistPinned(!isPinned, id: playlist.id, title: playlist.title)
        } label: {
            Label(isPinned ? "Unpin from Home" : "Pin to Home", systemImage: isPinned ? "pin.slash" : "pin")
        }
    }
}

// MARK: - Rows

/// One playlist entry: 16:9 still (progress bar over it), title, the show and
/// episode or the year, and the runtime. Watched items get the quiet
/// checkmark.
struct PlaylistEntryRow: View {
    let item: PlexItem
    let thumbnailURL: URL?

    private var artworkWidth: CGFloat {
        #if os(tvOS)
        300
        #else
        132
        #endif
    }

    var body: some View {
        HStack(alignment: .center, spacing: rowSpacing) {
            PosterArtwork(
                imageURL: thumbnailURL,
                progress: item.posterProgress,
                width: artworkWidth,
                imageAspectRatio: 16.0 / 9.0,
                cornerRadius: thumbnailCornerRadius,
                isUnwatchedEpisodeImage: item.landscapeImageIsUnwatchedEpisodeStill
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(DuskFont.rowTitle(ios: .subheadline.weight(.semibold)))
                    .foregroundStyle(Color.duskTextPrimary)
                    .lineLimit(2)

                if let secondary = PlaylistDetailViewModel.secondaryLine(for: item) {
                    Text(secondary)
                        .font(DuskFont.cardSubtitle(ios: .caption))
                        .foregroundStyle(Color.duskTextSecondary)
                        .lineLimit(1)
                }

                if let duration = MediaTextFormatter.compactDuration(milliseconds: item.duration) {
                    Text(duration)
                        .font(DuskFont.cardSubtitle(ios: .caption))
                        .foregroundStyle(Color.duskTextSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.isWatched {
                Image(systemName: "checkmark")
                    .font(DuskFont.cardSubtitle(ios: .caption.weight(.semibold)))
                    .foregroundStyle(Color.duskTextSecondary)
                    .accessibilityLabel("Watched")
            }
        }
        .contentShape(Rectangle())
    }

    private var rowSpacing: CGFloat {
        #if os(tvOS)
        28
        #else
        14
        #endif
    }

    private var thumbnailCornerRadius: CGFloat {
        #if os(tvOS)
        14
        #else
        10
        #endif
    }
}

#if os(tvOS)
/// A focusable playlist row: lifts with a `TextPrimary` low-opacity band
/// (STYLE §4) instead of the system button platter.
private struct PlaylistTVEntryButton: View {
    let item: PlexItem
    let thumbnailURL: URL?
    let action: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            PlaylistEntryRow(item: item, thumbnailURL: thumbnailURL)
                .padding(.vertical, 14)
                .padding(.horizontal, 20)
        }
        .duskSuppressTVOSButtonChrome()
        .focused($isFocused)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.duskTextPrimary.opacity(isFocused ? 0.14 : 0))
        }
        .scaleEffect(isFocused ? 1.01 : 1)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}
#endif
