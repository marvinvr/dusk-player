import SwiftUI
#if os(tvOS)
import CoreImage.CIFilterBuiltins
#endif

struct SignInView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(\.openURL) private var openURL
    @State private var linkPinCode: String?
    @State private var isSigningIn = false
    @State private var error: String?
    @State private var pollingTask: Task<Void, Never>?
    @State private var authURL: URL?
    #if os(macOS)
    /// The user chose "Use a code" instead of the browser approval page.
    @State private var macUsesLinkCodeOnly = false
    @State private var macIsHoveringCodeLink = false
    #endif

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            signInContent
        }
        #if os(iOS)
        .sheet(isPresented: authSheetPresented) {
            if let authURL {
                DuskSafariView(url: authURL)
            }
        }
        #endif
        .onDisappear {
            pollingTask?.cancel()
        }
    }

    @ViewBuilder
    private var signInContent: some View {
        #if os(tvOS)
        tvSignInContent
        #elseif os(macOS)
        macSignInContent
        #else
        iosSignInContent
        #endif
    }

    #if os(macOS)
    /// The Mac's welcome screen: one centred group (logo, name, tagline, a
    /// normal-width prominent button and the link-code alternative) under a
    /// transparent title bar, nothing pinned to the window edges.
    private var macSignInContent: some View {
        VStack(spacing: 0) {
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)

            Text("Dusk")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Color.duskTextPrimary)
                .padding(.top, 18)

            Text("The Plex App we Deserve.")
                .font(.title3)
                .foregroundStyle(Color.duskTextSecondary)
                .padding(.top, 4)

            Group {
                if isSigningIn {
                    macSigningInContent
                } else {
                    macWelcomeActions
                }
            }
            .padding(.top, 32)
            .frame(minHeight: 150, alignment: .top)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        .padding(MacUILayout.contentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The window's title bar disappears behind the content here; the
        // traffic lights float over the page like an onboarding window.
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .animation(.default, value: isSigningIn)
    }

    private var macWelcomeActions: some View {
        VStack(spacing: 14) {
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Task { await signIn() }
            } label: {
                Text("Sign in with Plex")
                    .frame(minWidth: 180)
            }
            // Bordered, not glass: its label stays legible while the window
            // is inactive.
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            // A quiet link, not a blue one (no tint): link cursor, and
            // underlined under the pointer so it reads as clickable.
            Button {
                Task { await signIn(opensBrowser: false) }
            } label: {
                Text("Use a code on plex.tv/link instead")
                    .underline(macIsHoveringCodeLink)
            }
            .buttonStyle(.plain)
            .foregroundStyle(macIsHoveringCodeLink ? .primary : .secondary)
            .font(.callout)
            .pointerStyle(.link)
            .onHover { macIsHoveringCodeLink = $0 }
            .help("Sign in from any browser or device with a four-character code")
        }
    }

    private var macLinkInstructions: Text {
        let link = Text("plex.tv/link").foregroundStyle(Color.duskTextPrimary)
        if macUsesLinkCodeOnly {
            return Text("Go to \(link) on any device and enter")
        }
        return Text("Approve Dusk in the browser that opened, or go to \(link) and enter")
    }

    private var macSigningInContent: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for approval…")
                    .font(.callout)
                    .foregroundStyle(Color.duskTextSecondary)
            }

            if let linkPinCode {
                VStack(spacing: 4) {
                    macLinkInstructions
                        .font(.callout)
                        .foregroundStyle(Color.duskTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(linkPinCode)
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .tracking(6)
                        .foregroundStyle(Color.duskTextPrimary)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 10) {
                Button("Cancel") {
                    cancelSignIn()
                }
                .keyboardShortcut(.cancelAction)

                if let url = URL(string: "https://plex.tv/link") {
                    Button("Open plex.tv/link") {
                        openURL(url)
                    }
                }
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
    }
    #endif

    private var iosSignInContent: some View {
        VStack(spacing: 0) {
            Spacer()

            branding(iconSize: 80, titleFont: .largeTitle)

            Spacer()

            VStack(spacing: 24) {
                signInError

                if isSigningIn {
                    VStack(spacing: 12) {
                        Text("Complete sign-in in the Plex page that opened, or go to")
                            .foregroundStyle(Color.duskTextSecondary)
                            .font(.callout)

                        if let linkPinCode {
                            linkCodeContent(
                                code: linkPinCode,
                                titleFont: .headline,
                                codeFont: .system(.title, design: .monospaced, weight: .bold)
                            )
                        }
                    }
                }

                signInButton
                    .padding(.horizontal, 40)

                if isSigningIn {
                    cancelButton
                }
            }

            Spacer()
                .frame(height: 60)
        }
    }

    #if os(tvOS)
    /// Apple TV sign-in: a calm start screen, then the plex.tv/link code next
    /// to a QR code that opens the link page on a phone with the code filled in.
    @ViewBuilder
    private var tvSignInContent: some View {
        if isSigningIn {
            tvLinkContent
                .transition(.opacity)
        } else {
            tvWelcomeContent
                .transition(.opacity)
        }
    }

    private var tvWelcomeContent: some View {
        VStack(spacing: 0) {
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 150, height: 150)

            Text("Dusk")
                .font(DuskFont.TV.pageTitleRounded)
                .foregroundStyle(Color.duskTextPrimary)
                .padding(.top, 28)

            Text("Sign in with your Plex account to get started.")
                .font(DuskFont.TV.pageSubtitle)
                .foregroundStyle(Color.duskTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, 12)

            if let error {
                Text(error)
                    .font(DuskFont.TV.body)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top, 24)
            }

            Button {
                Task { await signIn() }
            } label: {
                Text("Sign in with Plex")
                    .font(DuskFont.TV.buttonLabel)
                    .frame(minWidth: 380)
            }
            .detailHeroNativePrimaryButtonStyle()
            .padding(.top, 56)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tvLinkContent: some View {
        HStack(alignment: .center, spacing: 96) {
            tvQRCodePanel

            VStack(alignment: .leading, spacing: 0) {
                Text("Sign in with Plex")
                    .font(DuskFont.TV.pageTitle)
                    .foregroundStyle(Color.duskTextPrimary)

                Text("Scan the QR code with your phone,\nor go to \(Text("plex.tv/link").foregroundStyle(Color.duskTextPrimary)) and enter this code.")
                    .font(DuskFont.TV.pageSubtitle)
                    .foregroundStyle(Color.duskTextSecondary)
                    .lineSpacing(4)
                    .fixedSize()
                    .padding(.top, 14)

                tvCodeTiles
                    .padding(.top, 44)

                HStack(spacing: 14) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 28, height: 28)
                    Text(linkPinCode == nil ? "Getting a code…" : "Waiting for approval…")
                        .font(DuskFont.TV.caption)
                        .foregroundStyle(Color.duskTextSecondary)
                }
                .padding(.top, 28)

                HStack(spacing: 24) {
                    Button {
                        Task { await signIn() }
                    } label: {
                        Text("New Code")
                            .font(DuskFont.TV.buttonLabel)
                            .frame(minWidth: 220)
                    }
                    .detailHeroNativePrimaryButtonStyle()

                    Button {
                        cancelSignIn()
                    } label: {
                        Text("Cancel")
                            .font(DuskFont.TV.buttonLabel)
                            .frame(minWidth: 220)
                    }
                    .detailHeroNativePrimaryButtonStyle()
                }
                .padding(.top, 48)
            }
            .fixedSize()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The QR code on a white card (its quiet zone), so phones read it on the
    /// dark background.
    private var tvQRCodePanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(.white)

            if let linkPinCode, let qrImage = SignInQRCode.image(for: Self.linkURL(code: linkPinCode)) {
                Image(decorative: qrImage, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(36)
            } else {
                ProgressView()
                    .tint(.black)
            }
        }
        .frame(width: 480, height: 480)
    }

    /// The four-character code as separate glass tiles, so it reads from the
    /// couch and can't be mistaken for a word.
    private var tvCodeTiles: some View {
        let characters = linkPinCode.map { $0.map(String.init) } ?? Array(repeating: " ", count: 4)
        return HStack(spacing: 18) {
            ForEach(Array(characters.enumerated()), id: \.offset) { _, character in
                Text(character)
                    .font(.system(size: 76, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.duskTextPrimary)
                    .frame(width: 112, height: 136)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
        }
    }

    /// plex.tv/link reads a `token` query parameter into its code field
    /// (`PlexLinkClaim` → `PlexUtils.getParam("token")`); `plex.tv` 301s to
    /// `www.plex.tv` with the query intact.
    private static func linkURL(code: String) -> String {
        "https://plex.tv/link?token=\(code)"
    }
    #else
    private var tvSignInContent: some View { EmptyView() }
    #endif

    private func branding(iconSize: CGFloat, titleFont: Font) -> some View {
        VStack(spacing: 16) {
            Image("LaunchLogo")
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)

            VStack(spacing: 6) {
                Text("Dusk")
                    .font(titleFont)
                    .foregroundStyle(Color.duskTextPrimary)
                Text("The Plex App we Deserve.")
                    .font(DuskFont.caption(ios: .subheadline))
                    .foregroundStyle(Color.duskTextSecondary)
            }
        }
    }

    @ViewBuilder
    private var signInError: some View {
        if let error {
            Text(error)
                .foregroundStyle(.red)
                .font(DuskFont.body(ios: .callout))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var signInButton: some View {
        Button {
            Task { await signIn() }
        } label: {
            HStack(spacing: 8) {
                if isSigningIn {
                    ProgressView()
                        #if !os(tvOS)
                        .tint(Color.duskPrimaryActionLabel)
                        #endif
                }
                Text(isSigningIn ? "Waiting for approval…" : "Sign in with Plex")
            }
            .font(DuskFont.buttonLabel(ios: .headline))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            #if !os(tvOS)
            .foregroundStyle(Color.duskPrimaryActionLabel)
            #endif
        }
        .disabled(isSigningIn)
        .detailHeroNativePrimaryButtonStyle()
    }

    private var cancelButton: some View {
        Button("Cancel") {
            cancelSignIn()
        }
        .duskFont(tvOnly: DuskFont.TV.buttonLabel)
        .foregroundStyle(Color.duskTextSecondary)
        .duskSuppressTVOSButtonChrome()
        .duskTVOSFocusEffectShape(Capsule())
    }

    private func linkCodeContent(code: String, titleFont: Font, codeFont: Font) -> some View {
        VStack(spacing: 12) {
            Text("plex.tv/link")
                .font(titleFont)
                .foregroundStyle(Color.duskTextPrimary)
            Text("and enter this code:")
                .foregroundStyle(Color.duskTextSecondary)
                .font(.callout)
            Text(code)
                .font(codeFont)
                .tracking(4)
                .foregroundStyle(Color.duskTextPrimary)
        }
    }

    /// `opensBrowser`: Mac only; false signs in with the plex.tv/link code
    /// alone (the "use a code" option) and never opens the approval page.
    private func signIn(opensBrowser: Bool = true) async {
        isSigningIn = true
        error = nil
        linkPinCode = nil

        do {
            #if os(tvOS)
            let linkPin = try await plexService.generatePin()
            linkPinCode = linkPin.code
            startPolling(primaryPinID: linkPin.id)
            #else
            // Plex uses a longer-lived "strong" PIN for browser approval, but
            // plex.tv/link expects the short code flow, so we keep both active.
            let browserPin = try await plexService.generatePin(strong: true)
            let linkPin = try? await plexService.generatePin()
            linkPinCode = linkPin?.code

            guard let url = plexService.authURL(for: browserPin) else {
                throw PlexServiceError.invalidURL
            }

            #if os(macOS)
            macUsesLinkCodeOnly = !opensBrowser
            if opensBrowser {
                startPolling(primaryPinID: browserPin.id, fallbackPinID: linkPin?.id)
                openAuthURL(url)
            } else if let linkPin {
                // Only the link code can be approved, so it is polled first.
                startPolling(primaryPinID: linkPin.id)
            } else {
                throw PlexServiceError.invalidURL
            }
            #else
            startPolling(primaryPinID: browserPin.id, fallbackPinID: linkPin?.id)
            openAuthURL(url)
            #endif
            #endif
        } catch {
            ErrorReporter.report(.signInFailed, reason: .pinRequest, error: error)
            self.error = error.localizedDescription
            isSigningIn = false
        }
    }

    private func startPolling(primaryPinID: Int, fallbackPinID: Int? = nil) {
        pollingTask?.cancel()
        pollingTask = Task {
            let fallbackActivationAttempt = 15

            for attempt in 0..<120 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }

                if let token = try? await plexService.checkPin(primaryPinID) {
                    plexService.setAuthToken(token)
                    isSigningIn = false
                    linkPinCode = nil
                    authURL = nil
                    return
                }

                if attempt >= fallbackActivationAttempt,
                   let fallbackPinID,
                   let token = try? await plexService.checkPin(fallbackPinID) {
                        plexService.setAuthToken(token)
                        isSigningIn = false
                        linkPinCode = nil
                        authURL = nil
                        return
                }
            }

            // Ran the full window without approval — a genuine timeout.
            // Cancellation (Cancel button, closing the view, restarting sign-in)
            // returns early above, so aborting never surfaces this message.
            isSigningIn = false
            linkPinCode = nil
            authURL = nil
            ErrorReporter.report(.signInFailed, reason: .timeout)
            error = "Sign-in timed out. Please try again."
        }
    }

    private func cancelSignIn() {
        pollingTask?.cancel()
        isSigningIn = false
        linkPinCode = nil
        authURL = nil
    }

    #if !os(tvOS)
    private var authSheetPresented: Binding<Bool> {
        Binding(
            get: { authURL != nil },
            set: {
                guard !$0 else { return }
                authURL = nil
            }
        )
    }

    /// Opens the Plex approval page for the browser PIN.
    ///
    /// On iPhone/iPad this presents the in-app `SFSafariViewController` sheet.
    /// For an iOS app running on macOS ("Designed for iPad") that sheet is
    /// unreliable — the system hands the URL to the default browser and
    /// dismisses the sheet immediately — so we open the external browser
    /// directly there instead. Either path leaves polling running and the
    /// `plex.tv/link` code on screen as the fallback.
    private func openAuthURL(_ url: URL) {
        #if os(macOS)
        // A native Mac app approves in the default browser.
        openURL(url)
        #else
        if ProcessInfo.processInfo.isiOSAppOnMac || ProcessInfo.processInfo.isMacCatalystApp {
            openURL(url)
        } else {
            authURL = url
        }
        #endif
    }
    #endif
}

#if os(tvOS)
/// Renders a QR code at one pixel per module. The view scales it up with
/// `.interpolation(.none)`, so the modules stay sharp at any size.
enum SignInQRCode {
    private static let context = CIContext()

    static func image(for string: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }
}
#endif
