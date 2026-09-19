import SwiftUI

/// "Download Subtitles" — Plex searches OpenSubtitles server-side and installs
/// the chosen result as a sidecar. Presented as a sheet on iOS/iPadOS and as a
/// full-screen cover on tvOS; the content below is shared apart from layout.
struct SubtitleSearchView: View {
    @State private var viewModel: SubtitleSearchViewModel
    private let onDismiss: () -> Void

    #if os(tvOS)
    @FocusState private var focusedResultID: String?
    #endif

    init(
        plexService: PlexService,
        ratingKey: String,
        serverID: String?,
        preferredLanguageCode: String?,
        onDownloaded: @escaping (PlexSubtitleSearchResult) async -> Void,
        onDismiss: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: SubtitleSearchViewModel(
            plexService: plexService,
            ratingKey: ratingKey,
            serverID: serverID,
            preferredLanguageCode: preferredLanguageCode,
            onDownloaded: onDownloaded
        ))
        self.onDismiss = onDismiss
    }

    /// For callers that build the view model themselves (detail screens route
    /// through their own view model so the view stays off `PlexService`).
    init(viewModel: SubtitleSearchViewModel, onDismiss: @escaping () -> Void) {
        _viewModel = State(initialValue: viewModel)
        self.onDismiss = onDismiss
    }

    var body: some View {
        #if os(tvOS)
        tvOSBody
        #else
        iOSBody
        #endif
    }

    // MARK: - iOS / iPadOS

    #if !os(tvOS)
    private var iOSBody: some View {
        @Bindable var vm = viewModel

        return NavigationStack {
            List {
                Section {
                    Picker("Language", selection: $vm.language) {
                        ForEach(CommonLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Color.duskAccent)

                    Toggle("Hearing Impaired", isOn: $vm.hearingImpaired)
                        .tint(Color.duskAccent)

                    Button {
                        Task { await viewModel.search() }
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .disabled(viewModel.isBusy)
                } footer: {
                    Text(Self.providerFootnote)
                }
                .listRowBackground(Color.duskSurface)

                if let errorMessage = viewModel.errorMessage, !viewModel.results.isEmpty {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                    .listRowBackground(Color.duskSurface)
                }

                Section {
                    resultsSection
                }
                .listRowBackground(Color.duskSurface)
            }
            .duskScrollContentBackgroundHidden()
            .background(Color.duskBackground)
            .duskNavigationTitle("Download Subtitles")
            .duskNavigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.duskBackground)
        .task { await searchOnFirstAppearance() }
        .onChange(of: viewModel.language) { _, _ in reloadForChangedQuery() }
        .onChange(of: viewModel.hearingImpaired) { _, _ in reloadForChangedQuery() }
        .onChange(of: viewModel.didDownload) { _, didDownload in
            guard didDownload else { return }
            dismissAfterSuccess()
        }
    }

    @ViewBuilder
    private var resultsSection: some View {
        switch viewModel.phase {
        case .searching:
            HStack(spacing: 12) {
                FeatureLoadingView()
                Text("Searching…")
                    .foregroundStyle(Color.duskTextSecondary)
            }

        case .empty:
            centeredStateRow {
                FeatureEmptyStateView(
                    systemImage: "captions.bubble",
                    title: "No Subtitles Found",
                    message: "Try another language or turn off the Hearing Impaired filter."
                )
            }

        case .downloaded:
            centeredStateRow {
                FeatureEmptyStateView(
                    systemImage: "checkmark.circle",
                    title: "Subtitle Added",
                    message: "Plex installed it next to the media file."
                )
            }

        case let .error(message) where viewModel.results.isEmpty:
            centeredStateRow {
                FeatureErrorView(message: message) {
                    Task { await viewModel.search() }
                }
            }

        default:
            if viewModel.results.isEmpty {
                centeredStateRow {
                    FeatureEmptyStateView(
                        systemImage: "magnifyingglass",
                        title: "Search for Subtitles",
                        message: nil
                    )
                }
            } else {
                ForEach(viewModel.results) { result in
                    Button {
                        Task { await viewModel.download(result) }
                    } label: {
                        resultRow(result)
                    }
                    .disabled(viewModel.isBusy)
                }
            }
        }
    }

    private func centeredStateRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private var tvOSBody: some View {
        ZStack {
            Color.duskBackground
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Download Subtitles")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Color.duskTextPrimary)

                    Text(Self.providerFootnote)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Color.duskTextSecondary)
                }

                HStack(spacing: 18) {
                    Menu {
                        ForEach(CommonLanguage.allCases) { language in
                            Button {
                                viewModel.language = language
                            } label: {
                                if viewModel.language == language {
                                    Label(language.displayName, systemImage: "checkmark")
                                } else {
                                    Text(language.displayName)
                                }
                            }
                        }
                    } label: {
                        Label(viewModel.language.displayName, systemImage: "globe")
                    }
                    .disabled(viewModel.isBusy)

                    Button {
                        viewModel.hearingImpaired.toggle()
                    } label: {
                        Label(
                            "Hearing Impaired",
                            systemImage: viewModel.hearingImpaired ? "checkmark.square" : "square"
                        )
                    }
                    .disabled(viewModel.isBusy)

                    Button {
                        Task { await viewModel.search() }
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    .disabled(viewModel.isBusy)
                }
                .focusSection()

                tvOSResults
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(60)
        }
        // A tvOS full-screen cover has no chrome of its own: without this the
        // Menu button cannot close the flow. Same wiring as the player's
        // Playback Info cover.
        .onExitCommand(perform: onDismiss)
        .task { await searchOnFirstAppearance() }
        .onChange(of: viewModel.language) { _, _ in reloadForChangedQuery() }
        .onChange(of: viewModel.hearingImpaired) { _, _ in reloadForChangedQuery() }
        .onChange(of: viewModel.didDownload) { _, didDownload in
            guard didDownload else { return }
            dismissAfterSuccess()
        }
    }

    @ViewBuilder
    private var tvOSResults: some View {
        switch viewModel.phase {
        case .searching:
            tvOSCenteredState {
                FeatureLoadingView()
            }

        case .empty:
            tvOSCenteredState {
                FeatureEmptyStateView(
                    systemImage: "captions.bubble",
                    title: "No Subtitles Found",
                    message: "Try another language or turn off the Hearing Impaired filter."
                )
            }

        case .downloaded:
            tvOSCenteredState {
                FeatureEmptyStateView(
                    systemImage: "checkmark.circle",
                    title: "Subtitle Added",
                    message: "Plex installed it next to the media file."
                )
            }

        case let .error(message) where viewModel.results.isEmpty:
            tvOSCenteredState {
                FeatureErrorView(message: message) {
                    Task { await viewModel.search() }
                }
            }

        default:
            if viewModel.results.isEmpty {
                tvOSCenteredState {
                    FeatureEmptyStateView(
                        systemImage: "magnifyingglass",
                        title: "Search for Subtitles",
                        message: nil
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if let errorMessage = viewModel.errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(Color.duskTextSecondary)
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(viewModel.results) { result in
                                Button {
                                    Task { await viewModel.download(result) }
                                } label: {
                                    resultRow(result)
                                        .padding(.horizontal, 22)
                                        .padding(.vertical, 16)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(
                                            focusedResultID == result.id
                                                ? Color.duskTextPrimary.opacity(0.12)
                                                : Color.duskSurface,
                                            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                                        )
                                }
                                .buttonStyle(.plain)
                                .focused($focusedResultID, equals: result.id)
                                .disabled(viewModel.isBusy)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.visible)
                    .focusSection()
                }
            }
        }
    }

    private func tvOSCenteredState<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    #endif

    // MARK: - Shared row

    private func resultRow(_ result: PlexSubtitleSearchResult) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(result.displayTitle)
                        .foregroundStyle(Color.duskTextPrimary)
                        .lineLimit(2)

                    if result.isHearingImpaired == true {
                        badge("HI")
                    }
                    if result.isForced == true {
                        badge("Forced")
                    }
                }

                if !result.detailText.isEmpty {
                    Text(result.detailText)
                        .font(.caption)
                        .foregroundStyle(Color.duskTextSecondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 12)

            if viewModel.downloadingResultID == result.id {
                FeatureLoadingView()
            } else {
                Image(systemName: "arrow.down.circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.duskAccent)
            }
        }
        .contentShape(Rectangle())
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(Color.duskTextSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.duskTextSecondary.opacity(0.16), in: Capsule())
    }

    // MARK: - Shared behavior

    private static let providerFootnote =
        "Plex searches OpenSubtitles and saves the file next to the media."

    private func searchOnFirstAppearance() async {
        guard viewModel.results.isEmpty, viewModel.phase == .idle else { return }
        await viewModel.search()
    }

    private func reloadForChangedQuery() {
        viewModel.queryDidChange()
        Task { await viewModel.search() }
    }

    private func dismissAfterSuccess() {
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            onDismiss()
        }
    }
}
