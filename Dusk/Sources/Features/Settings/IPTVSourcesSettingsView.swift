import SwiftUI

/// Settings › Live TV › IPTV Sources: the list, plus Add IPTV Source.
struct IPTVSourcesSettingsView: View {
    @Environment(IPTVService.self) private var iptvService

    var body: some View {
        Group {
            #if os(tvOS)
            tvContent
            #else
            iosContent
            #endif
        }
        .background(Color.duskBackground.ignoresSafeArea())
        .duskNavigationTitle("IPTV Sources")
        .task {
            iptvService.syncProfile()
            await iptvService.load()
        }
    }

    #if !os(tvOS)
    private var iosContent: some View {
        List {
            if !iptvService.sources.isEmpty {
                Section {
                    ForEach(iptvService.sources) { source in
                        NavigationLink {
                            IPTVSourceEditorView(source: source)
                        } label: {
                            sourceLabel(source)
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            iptvService.delete(iptvService.sources[index])
                        }
                    }
                    .onMove { iptvService.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Sources")
                        .foregroundStyle(Color.duskTextSecondary)
                }
                .listRowBackground(Color.duskSurface)
            }

            Section {
                NavigationLink {
                    IPTVSourceEditorView(source: nil)
                } label: {
                    Label("Add IPTV Source", systemImage: "plus")
                        .foregroundStyle(Color.duskTextPrimary)
                }
            } footer: {
                Text(Self.footerText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)
        }
        .scrollContentBackground(.hidden)
        .toolbar {
            if iptvService.sources.count > 1 {
                EditButton()
            }
        }
    }

    private func sourceLabel(_ source: IPTVSource) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(source.name)
                .foregroundStyle(Color.duskTextPrimary)
            Text(iptvService.status(for: source))
                .font(.caption)
                .foregroundStyle(Color.duskTextSecondary)
                .lineLimit(2)
        }
    }
    #endif

    #if os(tvOS)
    private var tvContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                if !iptvService.sources.isEmpty {
                    TVSettingsSection(title: "Sources") {
                        ForEach(Array(iptvService.sources.enumerated()), id: \.element.id) { index, source in
                            if index > 0 { tvRowDivider }
                            TVSettingsNavigationRow(
                                title: source.name,
                                detail: iptvService.status(for: source)
                            ) {
                                IPTVSourceEditorView(source: source)
                            }
                        }
                    }
                }

                TVSettingsSection(title: "Add", footer: Self.footerText) {
                    TVSettingsNavigationRow(title: "Add IPTV Source") {
                        IPTVSourceEditorView(source: nil)
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.top, 48)
            .padding(.bottom, 88)
        }
    }

    private var tvRowDivider: some View {
        Rectangle()
            .fill(Color.duskTextSecondary.opacity(0.16))
            .frame(height: 1)
    }
    #endif

    static let footerText = "Add a standard M3U playlist, with an optional XMLTV program guide. Its channels appear in Live TV after your Plex channels and always play with Apple’s player. Sources are kept separately for each Plex Home user."
}

/// Add or edit one source. A new source is only created on Save.
struct IPTVSourceEditorView: View {
    @Environment(IPTVService.self) private var iptvService
    @Environment(\.dismiss) private var dismiss

    let source: IPTVSource?

    @State private var name = ""
    @State private var playlistURL = ""
    @State private var guideURL = ""
    @State private var headerName = ""
    @State private var headerValue = ""
    @State private var didLoad = false
    @State private var confirmsDelete = false

    var body: some View {
        Group {
            #if os(tvOS)
            tvContent
            #else
            iosContent
            #endif
        }
        .background(Color.duskBackground.ignoresSafeArea())
        .duskNavigationTitle(source == nil ? "Add IPTV Source" : "Edit Source")
        .onAppear(perform: loadDraft)
        .confirmationDialog(
            "Delete \(source?.name ?? "this source")?",
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let source { iptvService.delete(source) }
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    #if !os(tvOS)
    private var iosContent: some View {
        Form {
            Section {
                TextField("Name", text: $name, prompt: Text("My IPTV"))
                TextField("M3U URL", text: $playlistURL, prompt: Text("https://example.com/playlist.m3u"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("XMLTV URL", text: $guideURL, prompt: Text("Optional"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } header: {
                Text("Source")
            } footer: {
                Text("Without an XMLTV URL, Dusk uses the guide the playlist names in its url-tvg header, if any.")
            }
            .listRowBackground(Color.duskSurface)

            Section {
                TextField("Header Name", text: $headerName, prompt: Text(IPTVSource.defaultHeaderName))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Value", text: $headerValue, prompt: Text("Bearer …"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Request Header")
            } footer: {
                Text(Self.headerFooter)
            }
            .listRowBackground(Color.duskSurface)

            if let validationMessage {
                Section {
                    Text(validationMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.duskTextSecondary)
                }
                .listRowBackground(Color.duskSurface)
            }

            if source != nil {
                Section {
                    Button("Delete Source", role: .destructive) { confirmsDelete = true }
                }
                .listRowBackground(Color.duskSurface)
            }
        }
        .scrollContentBackground(.hidden)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(draftSource == nil)
            }
        }
    }
    #endif

    #if os(tvOS)
    private var tvContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                TVSettingsSection(
                    title: "Source",
                    footer: "Without an XMLTV URL, Dusk uses the guide the playlist names in its url-tvg header, if any."
                ) {
                    TVSettingsURLFieldRow(
                        prompt: "Name",
                        placeholder: "My IPTV",
                        text: $name,
                        isDisabled: false,
                        alertTitle: "Name",
                        alertMessage: "How the source is titled in Live TV.",
                        isURL: false
                    )
                    tvRowDivider
                    TVSettingsURLFieldRow(
                        prompt: "M3U URL",
                        placeholder: "https://example.com/playlist.m3u",
                        text: $playlistURL,
                        isDisabled: false,
                        alertTitle: "M3U URL",
                        alertMessage: "The address of the channel playlist."
                    )
                    tvRowDivider
                    TVSettingsURLFieldRow(
                        prompt: "XMLTV URL",
                        placeholder: "Optional",
                        text: $guideURL,
                        isDisabled: false,
                        alertTitle: "XMLTV URL",
                        alertMessage: "Optional. The address of the program guide."
                    )
                }

                TVSettingsSection(title: "Request Header", footer: Self.headerFooter) {
                    TVSettingsURLFieldRow(
                        prompt: "Header Name",
                        placeholder: IPTVSource.defaultHeaderName,
                        text: $headerName,
                        isDisabled: false,
                        alertTitle: "Header Name",
                        alertMessage: "For example \(IPTVSource.defaultHeaderName).",
                        isURL: false
                    )
                    tvRowDivider
                    TVSettingsURLFieldRow(
                        prompt: "Value",
                        placeholder: "Bearer …",
                        text: $headerValue,
                        isDisabled: false,
                        alertTitle: "Header Value",
                        alertMessage: "Stored in the Keychain.",
                        isURL: false,
                        isSecure: true
                    )
                }

                TVSettingsSection(title: "Save", footer: validationMessage) {
                    TVSettingsActionRow(title: source == nil ? "Add Source" : "Save Changes", action: save)
                        .disabled(draftSource == nil)
                    if source != nil {
                        tvRowDivider
                        TVSettingsActionRow(title: "Delete Source", tint: .red, role: .destructive) {
                            confirmsDelete = true
                        }
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.top, 48)
            .padding(.bottom, 88)
        }
    }

    private var tvRowDivider: some View {
        Rectangle()
            .fill(Color.duskTextSecondary.opacity(0.16))
            .frame(height: 1)
    }
    #endif

    private static let headerFooter = "Optional. Sent with every request for this source: playlist, guide, stream and license. The value is stored in the Keychain."

    // MARK: - Draft

    private func loadDraft() {
        guard !didLoad else { return }
        didLoad = true
        guard let source else { return }
        name = source.name
        playlistURL = source.playlistURL.absoluteString
        guideURL = source.guideURL?.absoluteString ?? ""
        headerName = source.headerName ?? ""
        headerValue = iptvService.headerValue(for: source) ?? ""
    }

    private var trimmedHeaderName: String? {
        headerName.trimmingCharacters(in: .whitespaces).nilIfEmpty
    }

    /// The source Save would store, or nil while the draft is incomplete.
    private var draftSource: IPTVSource? {
        guard let name = name.trimmingCharacters(in: .whitespaces).nilIfEmpty,
              let playlist = M3UParser.httpURL(playlistURL) else { return nil }
        let guideText = guideURL.trimmingCharacters(in: .whitespaces)
        let guide = M3UParser.httpURL(guideText)
        guard guideText.isEmpty || guide != nil else { return nil }
        // A value without a name would never be sent; take the usual one.
        let header = trimmedHeaderName
            ?? (headerValue.isEmpty ? nil : IPTVSource.defaultHeaderName)
        return IPTVSource(
            id: source?.id ?? UUID(),
            name: name,
            playlistURL: playlist,
            guideURL: guide,
            headerName: header
        )
    }

    private var validationMessage: String? {
        if !playlistURL.isEmpty, M3UParser.httpURL(playlistURL) == nil {
            return "The M3U URL must be an http or https address."
        }
        let guideText = guideURL.trimmingCharacters(in: .whitespaces)
        if !guideText.isEmpty, M3UParser.httpURL(guideText) == nil {
            return "The XMLTV URL must be an http or https address."
        }
        return nil
    }

    private func save() {
        guard let draft = draftSource else { return }
        iptvService.save(draft, headerValue: headerValue)
        dismiss()
    }
}
