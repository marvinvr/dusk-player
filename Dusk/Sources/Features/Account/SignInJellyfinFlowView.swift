import SwiftUI

/// Jellyfin's sign-in steps inside the sign-in host (`SignInView`): the
/// server address, then a user name and password, or a Quick Connect code
/// approved in Jellyfin on another device. Apple TV opens on the code when the
/// server has Quick Connect on, since typing a password with a remote is slow.
struct SignInJellyfinFlowView: View {
    @Environment(MediaService.self) private var media
    let flow: JellyfinSignInFlow
    /// Back to the host's welcome screen.
    let onCancel: () -> Void

    fileprivate enum Step: Hashable {
        case credentials(JellyfinSignInFlow.Server)
        case quickConnect(JellyfinSignInFlow.Server)
    }

    @State private var path: [Step] = []
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var quickConnectCode: String?
    @State private var quickConnectTask: Task<Void, Never>?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case address, username, password
    }

    var body: some View {
        content
            .onDisappear { quickConnectTask?.cancel() }
    }

    // MARK: - Actions

    private func submitAddress() {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                let server = try await flow.connect(to: address)
                #if os(tvOS)
                if server.quickConnectEnabled {
                    path = [.quickConnect(server)]
                    return
                }
                #endif
                path = [.credentials(server)]
            } catch {
                self.error = error.localizedDescription
                #if !os(tvOS)
                focusedField = .address
                #endif
            }
        }
    }

    private func signIn(to server: JellyfinSignInFlow.Server) {
        guard !isWorking else { return }
        isWorking = true
        error = nil
        Task {
            defer { isWorking = false }
            do {
                let result = try await flow.signIn(
                    to: server,
                    username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: password
                )
                quickConnectTask?.cancel()
                media.completeJellyfinSignIn(result)
            } catch {
                self.error = error.localizedDescription
                #if !os(tvOS)
                focusedField = .password
                #endif
            }
        }
    }

    /// Asks for a code and waits for its approval; an expired code is replaced.
    private func startQuickConnect(on server: JellyfinSignInFlow.Server) {
        quickConnectTask?.cancel()
        quickConnectCode = nil
        error = nil
        quickConnectTask = Task {
            while !Task.isCancelled {
                do {
                    let request = try await flow.startQuickConnect(on: server)
                    quickConnectCode = request.code
                    if let result = try await flow.waitForQuickConnect(secret: request.secret, on: server) {
                        media.completeJellyfinSignIn(result)
                        return
                    }
                    quickConnectCode = nil
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    self.error = error.localizedDescription
                    quickConnectCode = nil
                    return
                }
            }
        }
    }

    private func leaveQuickConnect() {
        quickConnectTask?.cancel()
        quickConnectTask = nil
        quickConnectCode = nil
    }

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Layout

    #if os(tvOS)
    @ViewBuilder
    private var content: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            switch path.last {
            case nil:
                tvAddress
            case let .credentials(server):
                tvCredentials(server)
            case let .quickConnect(server):
                tvQuickConnect(server)
            }
        }
        .onExitCommand(perform: goBack)
        .animation(.default, value: path)
    }

    private func goBack() {
        error = nil
        guard !path.isEmpty else {
            onCancel()
            return
        }
        if case .quickConnect = path.last { leaveQuickConnect() }
        path.removeLast()
    }

    private var tvAddress: some View {
        tvColumn(
            title: "Sign in with Jellyfin",
            subtitle: "Enter the address of your Jellyfin server."
        ) {
            TextField("Server Address", text: $address, prompt: Text("jellyfin.example.com"))
                .textContentType(.URL)
                .autocorrectionDisabled()
                .onSubmit(submitAddress)
                .frame(width: 760)
        } actions: {
            tvButton(isWorking ? "Connecting…" : "Continue", action: submitAddress)
                .disabled(trimmedAddress.isEmpty || isWorking)
        }
    }

    private func tvCredentials(_ server: JellyfinSignInFlow.Server) -> some View {
        tvColumn(title: server.name, subtitle: nil) {
            VStack(spacing: 20) {
                TextField("User Name", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .onSubmit { signIn(to: server) }
            }
            .frame(width: 760)
        } actions: {
            tvButton(isWorking ? "Signing In…" : "Sign In") { signIn(to: server) }
                .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            if server.quickConnectEnabled {
                tvButton("Use Quick Connect") {
                    error = nil
                    path.append(.quickConnect(server))
                }
            }
        }
    }

    private func tvQuickConnect(_ server: JellyfinSignInFlow.Server) -> some View {
        VStack(spacing: 32) {
            SignInCodeScreen(
                title: "Sign in with Jellyfin",
                instructions: Text("In Jellyfin on another device, open Quick Connect\nand enter this code."),
                code: quickConnectCode,
                codeLength: 6,
                showsQRCode: false,
                qrPayload: nil,
                status: quickConnectCode == nil ? "Getting a code…" : "Waiting for approval…"
            ) {
                SignInCodeScreenButton(title: "Use Password") {
                    leaveQuickConnect()
                    error = nil
                    path = [.credentials(server)]
                }
                SignInCodeScreenButton(title: "Cancel", action: goBack)
            }
            .fixedSize(horizontal: false, vertical: true)

            if let error {
                Text(error)
                    .font(DuskFont.TV.body)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: server) { startQuickConnect(on: server) }
    }

    private func tvColumn<Fields: View, Actions: View>(
        title: String,
        subtitle: String?,
        @ViewBuilder fields: () -> Fields,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(DuskFont.TV.pageTitle)
                .foregroundStyle(Color.duskTextPrimary)
                .multilineTextAlignment(.center)

            if let subtitle {
                Text(subtitle)
                    .font(DuskFont.TV.pageSubtitle)
                    .foregroundStyle(Color.duskTextSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
            }

            fields()
                .padding(.top, 48)

            if let error {
                Text(error)
                    .font(DuskFont.TV.body)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
                    .padding(.top, 24)
            }

            VStack(spacing: 24) {
                actions()
            }
            .padding(.top, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tvButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DuskFont.TV.buttonLabel)
                .frame(minWidth: 380)
        }
        .detailHeroNativePrimaryButtonStyle()
    }
    #else
    private var content: some View {
        NavigationStack(path: $path) {
            addressForm
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case let .credentials(server):
                        credentialsForm(server)
                    case let .quickConnect(server):
                        quickConnectPage(server)
                    }
                }
        }
        .onChange(of: path) { _, newPath in
            error = nil
            if !newPath.contains(where: { if case .quickConnect = $0 { true } else { false } }) {
                leaveQuickConnect()
            }
        }
    }

    private var addressForm: some View {
        Form {
            Section {
                TextField("Server Address", text: $address, prompt: Text("jellyfin.example.com"))
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .submitLabel(.continue)
                    #endif
                    .focused($focusedField, equals: .address)
                    .onSubmit(submitAddress)
            } footer: {
                errorFooter
            }
            .duskSettingsRowBackground()
        }
        .jellyfinSignInFormStyle()
        .navigationTitle("Jellyfin")
        .onAppear { focusedField = .address }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                workingButton("Continue", action: submitAddress)
                    .disabled(trimmedAddress.isEmpty || isWorking)
            }
        }
    }

    private func credentialsForm(_ server: JellyfinSignInFlow.Server) -> some View {
        Form {
            Section {
                TextField("User Name", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.next)
                    #endif
                    .focused($focusedField, equals: .username)
                    .onSubmit { focusedField = .password }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    #if os(iOS)
                    .submitLabel(.go)
                    #endif
                    .focused($focusedField, equals: .password)
                    .onSubmit { signIn(to: server) }
            } footer: {
                errorFooter
            }
            .duskSettingsRowBackground()

            if server.quickConnectEnabled {
                Section {
                    NavigationLink("Use Quick Connect", value: Step.quickConnect(server))
                }
                .duskSettingsRowBackground()
            }
        }
        .jellyfinSignInFormStyle()
        .navigationTitle(server.name)
        .onAppear { focusedField = username.isEmpty ? .username : .password }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                workingButton("Sign In") { signIn(to: server) }
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            }
        }
    }

    private func quickConnectPage(_ server: JellyfinSignInFlow.Server) -> some View {
        Form {
            Section {
                VStack(spacing: 14) {
                    Text(quickConnectCode ?? "······")
                        .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                        .tracking(6)
                        .foregroundStyle(quickConnectCode == nil ? Color.duskTextSecondary : Color.duskTextPrimary)
                        .textSelection(.enabled)
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(quickConnectCode == nil ? "Getting a code…" : "Waiting for approval…")
                            .font(.callout)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("In Jellyfin on another device, open Quick Connect and enter this code.")
                    if let error {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .duskSettingsRowBackground()
        }
        .jellyfinSignInFormStyle()
        .navigationTitle("Quick Connect")
        .task(id: server) { startQuickConnect(on: server) }
    }

    @ViewBuilder
    private var errorFooter: some View {
        if let error {
            Text(error)
                .foregroundStyle(.red)
        }
    }

    private func workingButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isWorking {
                ProgressView()
                    #if os(macOS)
                    .controlSize(.small)
                    #endif
            } else {
                Text(title)
            }
        }
    }
    #endif
}

#if !os(tvOS)
private extension View {
    /// The settings forms' look: grouped, on the Dusk background.
    func jellyfinSignInFormStyle() -> some View {
        self
            #if os(macOS)
            .formStyle(.grouped)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #else
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .duskSettingsFormBackgroundHidden()
            .duskSettingsPageBackground()
    }
}
#endif
