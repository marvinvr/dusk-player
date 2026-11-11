import SwiftUI

/// Something that can be added to a playlist: a movie, episode or video, or a
/// show or season (Plex adds all its episodes). It only ever goes to a
/// playlist on its own server.
struct AddToPlaylistTarget: Identifiable, Sendable, Hashable {
    let id: PlexItemID
    let type: PlexMediaType
    let title: String
    /// Episodes a show or season expands to, when the caller knows.
    var episodeCount: Int?

    var expandsToEpisodes: Bool { type == .show || type == .season }

    init(id: PlexItemID, type: PlexMediaType, title: String, episodeCount: Int? = nil) {
        self.id = id
        self.type = type
        self.title = title
        self.episodeCount = episodeCount
    }

    init?(item: PlexItem) {
        guard Self.supports(item.type) else { return nil }
        self.init(
            id: item.id,
            type: item.type,
            title: item.type == .season ? [item.parentTitle, item.title].compactMap { $0 }.joined(separator: " · ") : item.title,
            episodeCount: item.leafCount
        )
    }

    init?(details: PlexMediaDetails) {
        guard Self.supports(details.type) else { return nil }
        self.init(
            id: details.id,
            type: details.type,
            title: details.title,
            episodeCount: details.type == .show || details.type == .season ? details.leafCount : nil
        )
    }

    init(episode: PlexEpisode) {
        self.init(id: episode.id, type: .episode, title: episode.title)
    }

    init(season: PlexSeason) {
        self.init(
            id: season.id,
            type: .season,
            title: [season.parentTitle, season.title].compactMap { $0 }.joined(separator: " · "),
            episodeCount: season.leafCount
        )
    }

    static func supports(_ type: PlexMediaType) -> Bool {
        switch type {
        case .movie, .episode, .clip, .show, .season: true
        default: false
        }
    }
}

/// Presents the Add to Playlist sheet from anywhere in the tab shell. Owned
/// by `MainTabView` and published in the environment; context menus and the
/// detail hero icon call `present(_:)`.
@MainActor
@Observable
final class AddToPlaylistPresenter {
    var target: AddToPlaylistTarget?

    func present(_ target: AddToPlaylistTarget) {
        self.target = target
    }
}

/// The "Add to Playlist…" context-menu entry. Renders nothing outside the
/// tab shell (no presenter) or for content that cannot go in a playlist.
struct AddToPlaylistMenuButton: View {
    @Environment(AddToPlaylistPresenter.self) private var presenter: AddToPlaylistPresenter?
    let target: AddToPlaylistTarget?

    var body: some View {
        if let presenter, let target {
            Button {
                presenter.present(target)
            } label: {
                Label("Add to Playlist…", systemImage: "text.badge.plus")
            }
        }
    }
}

/// The icon-only hero action on movie, episode, season and show pages.
struct AddToPlaylistHeroButton: View {
    @Environment(AddToPlaylistPresenter.self) private var presenter: AddToPlaylistPresenter?
    let target: AddToPlaylistTarget?

    var body: some View {
        if let presenter, let target {
            Button {
                presenter.present(target)
            } label: {
                DetailHeroSecondaryIconLabel(systemImage: "text.badge.plus", title: "Add to Playlist")
            }
            .detailHeroNativeSecondaryButtonStyle()
            .accessibilityLabel("Add to Playlist")
        }
    }
}

// MARK: - Sheet

@MainActor
@Observable
final class AddToPlaylistViewModel {
    enum PendingAdd: Equatable {
        case existing(PlexPlaylist)
        case new(title: String)
    }

    let target: AddToPlaylistTarget
    private let plexService: PlexService

    private(set) var episodeCount: Int?
    private(set) var isWorking = false
    /// Set once the add went through; the sheet shows it, then closes.
    private(set) var confirmation: String?
    var error: String?
    /// A show/season add waiting for "Add 24 episodes?".
    var pendingConfirmation: PendingAdd?

    init(target: AddToPlaylistTarget, plexService: PlexService) {
        self.target = target
        self.plexService = plexService
        self.episodeCount = target.episodeCount
    }

    var playlists: [PlexPlaylist] {
        plexService.playlists.editablePlaylists(serverID: target.id.serverID)
    }

    var isLoading: Bool {
        plexService.playlists.state == .loading && playlists.isEmpty
    }

    var countQuestion: String {
        guard let episodeCount else { return "Add every episode?" }
        return episodeCount == 1 ? "Add 1 episode?" : "Add \(episodeCount) episodes?"
    }

    func load() async {
        await plexService.loadPlaylists()
        if target.expandsToEpisodes, episodeCount == nil {
            episodeCount = try? await plexService.getMediaDetails(
                ratingKey: target.id.ratingKey,
                serverID: target.id.serverID
            ).leafCount
        }
    }

    /// A show or season asks first; anything else goes straight in.
    func request(_ add: PendingAdd) async {
        if target.expandsToEpisodes {
            pendingConfirmation = add
        } else {
            await perform(add)
        }
    }

    /// The alert hands the add back: by the time its button runs, dismissing
    /// it has already cleared `pendingConfirmation`.
    func confirm(_ add: PendingAdd) async {
        pendingConfirmation = nil
        await perform(add)
    }

    private func perform(_ add: PendingAdd) async {
        guard let serverID = target.id.serverID, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            switch add {
            case .existing(let playlist):
                let result = try await plexService.addToPlaylist(playlist, ratingKeys: [target.id.ratingKey])
                await plexService.refreshPlaylist(playlist.id)
                confirmation = Self.confirmation(for: result, playlistTitle: playlist.title)
            case .new(let title):
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                let session = plexService.playlists.sessionGeneration
                let playlist = try await plexService.createPlaylist(
                    title: trimmed,
                    ratingKeys: [target.id.ratingKey],
                    serverID: serverID
                )
                plexService.playlists.upsert(playlist, sessionGeneration: session)
                confirmation = "Added to “\(playlist.title)”"
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Plex leaves out what the playlist already holds, so say what happened.
    static func confirmation(for result: PlexPlaylistAddResult, playlistTitle: String) -> String {
        if result.added == 0 {
            return "Already in “\(playlistTitle)”"
        }
        if result.requested > 1, result.added < result.requested {
            let skipped = result.requested - result.added
            return "Added \(result.added) to “\(playlistTitle)” (\(skipped) already there)"
        }
        return "Added to “\(playlistTitle)”"
    }
}

/// The playlists the item can join (regular playlists on its server, most
/// recently updated first), led by "New Playlist…". Plex cannot create an
/// empty playlist, so a new one starts with this item.
///
/// iOS: a native list in a detented sheet. tvOS: the Settings cards on a
/// full-screen pop-up (`duskPopUp`), where the focus band never meets an edge.
struct AddToPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: AddToPlaylistViewModel
    @State private var isNaming = false
    @State private var newTitle = ""

    init(target: AddToPlaylistTarget, plexService: PlexService) {
        _viewModel = State(initialValue: AddToPlaylistViewModel(target: target, plexService: plexService))
    }

    /// Nothing more to pick once an add is running or done.
    private var isLocked: Bool {
        viewModel.isWorking || viewModel.confirmation != nil
    }

    private func startNaming() {
        newTitle = ""
        isNaming = true
    }

    private func countText(_ playlist: PlexPlaylist) -> String? {
        playlist.leafCount.map { $0 == 1 ? "1 item" : "\($0) items" }
    }

    var body: some View {
        platformContent
            .task {
                await viewModel.load()
            }
            .onChange(of: viewModel.confirmation) { _, confirmation in
                guard confirmation != nil else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(900))
                    dismiss()
                }
            }
            .alert("New Playlist", isPresented: $isNaming) {
                TextField("Title", text: $newTitle)
                Button("Cancel", role: .cancel) {}
                Button("Create") {
                    let title = newTitle
                    Task { await viewModel.request(.new(title: title)) }
                }
            } message: {
                Text("“\(viewModel.target.title)” will be its first \(viewModel.target.expandsToEpisodes ? "episodes" : "item").")
            }
            .alert(viewModel.countQuestion, isPresented: confirmationBinding, presenting: viewModel.pendingConfirmation) { pending in
                Button("Cancel", role: .cancel) {}
                Button("Add") {
                    Task { await viewModel.confirm(pending) }
                }
            } message: { _ in
                Text("Every episode of “\(viewModel.target.title)” goes into the playlist, in order. Episodes already in it are skipped.")
            }
            .alert("Couldn’t Add to Playlist", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.error ?? "")
            }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingConfirmation != nil },
            set: { if !$0 { viewModel.pendingConfirmation = nil } }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.error != nil },
            set: { if !$0 { viewModel.error = nil } }
        )
    }
}

// MARK: - Platform layouts

extension AddToPlaylistSheet {
    @ViewBuilder
    private var platformContent: some View {
        #if os(tvOS)
        tvContent
        #else
        iosContent
        #endif
    }

    #if os(tvOS)
    private var tvContent: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                    Text("Add to Playlist")
                        .font(DuskFont.TV.pageTitle)
                        .foregroundStyle(Color.duskTextPrimary)
                        .padding(.leading, TVSettingsMetrics.contentInset)

                    TVSettingsSection {
                        TVSettingsActionRow(title: "New Playlist…", action: startNaming)
                            .disabled(isLocked)
                    }

                    if viewModel.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else if !viewModel.playlists.isEmpty {
                        TVSettingsSection(title: "Playlists") {
                            ForEach(Array(viewModel.playlists.enumerated()), id: \.element.id) { index, playlist in
                                if index > 0 {
                                    Rectangle()
                                        .fill(Color.duskTextSecondary.opacity(0.16))
                                        .frame(height: 1)
                                }
                                TVSettingsActionRow(title: playlist.title, detail: countText(playlist)) {
                                    Task { await viewModel.request(.existing(playlist)) }
                                }
                                .disabled(isLocked)
                            }
                        }
                    }

                    if let confirmation = viewModel.confirmation {
                        Label(confirmation, systemImage: "checkmark")
                            .font(DuskFont.rowTitle(ios: .headline))
                            .foregroundStyle(Color.duskTextPrimary)
                            .padding(.leading, TVSettingsMetrics.contentInset)
                    } else if viewModel.isWorking {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: 980, alignment: .leading)
                .padding(.horizontal, 60)
                .padding(.vertical, 64)
                // Centred on screen; a long list scrolls from the top.
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollIndicators(.hidden)
        }
    }
    #else
    private var iosContent: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: startNaming) {
                        Label("New Playlist…", systemImage: "plus")
                            .foregroundStyle(Color.duskTextPrimary)
                    }
                    .disabled(isLocked)
                }
                .listRowBackground(Color.duskSurface)

                if viewModel.isLoading {
                    Section {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                    .listRowBackground(Color.clear)
                } else if !viewModel.playlists.isEmpty {
                    Section {
                        ForEach(viewModel.playlists) { playlist in
                            Button {
                                Task { await viewModel.request(.existing(playlist)) }
                            } label: {
                                HStack {
                                    Text(playlist.title)
                                        .foregroundStyle(Color.duskTextPrimary)
                                    Spacer()
                                    if let count = countText(playlist) {
                                        Text(count)
                                            .foregroundStyle(Color.duskTextSecondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .disabled(isLocked)
                        }
                    } header: {
                        Text("Playlists")
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                    .listRowBackground(Color.duskSurface)
                }

                if let confirmation = viewModel.confirmation {
                    Section {
                        Label(confirmation, systemImage: "checkmark")
                            .foregroundStyle(Color.duskTextPrimary)
                    }
                    .listRowBackground(Color.clear)
                } else if viewModel.isWorking {
                    Section {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.duskBackground.ignoresSafeArea())
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
    #endif
}
