import SwiftUI

struct SignInView: View {
    @Environment(PlexService.self) private var plexService
    @State private var linkPinCode: String?
    @State private var isSigningIn = false
    @State private var error: String?
    @State private var pollingTask: Task<Void, Never>?
    @State private var authURL: URL?

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            signInContent
        }
        #if !os(tvOS)
        .sheet(isPresented: authSheetPresented, onDismiss: handleAuthSheetDismissal) {
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
        #else
        iosSignInContent
        #endif
    }

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

    private var tvSignInContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 24) {
                branding(iconSize: 112, titleFont: .system(size: 44, weight: .bold, design: .rounded))

                VStack(spacing: 12) {
                    Text("Sign in with Plex")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.duskTextPrimary)

                    Text("On another device, open plex.tv/link and enter the code shown below.")
                        .font(.title3)
                        .foregroundStyle(Color.duskTextSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 720)
                }

                signInError

                if let linkPinCode {
                    VStack(spacing: 14) {
                        Text("plex.tv/link")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.duskTextSecondary)

                        Text(linkPinCode)
                            .font(.system(size: 54, weight: .bold, design: .monospaced))
                            .tracking(8)
                            .foregroundStyle(Color.duskTextPrimary)
                    }
                    .padding(.horizontal, 54)
                    .padding(.vertical, 28)
                    .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                }

                signInButton
                    .frame(maxWidth: 520)

                if isSigningIn {
                    cancelButton
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
        .padding(.vertical, 60)
    }

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
                    .font(.subheadline)
                    .foregroundStyle(Color.duskTextSecondary)
            }
        }
    }

    @ViewBuilder
    private var signInError: some View {
        if let error {
            Text(error)
                .foregroundStyle(.red)
                .font(.callout)
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
                        .tint(.white)
                }
                Text(isSigningIn ? "Waiting for approval…" : "Sign in with Plex")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background {
                RoundedRectangle(cornerRadius: 100)
                    .fill(Color.duskAccent)
            }
        }
        .disabled(isSigningIn)
        .duskSuppressTVOSButtonChrome()
        .duskTVOSFocusEffectShape(RoundedRectangle(cornerRadius: 100, style: .continuous))
    }

    private var cancelButton: some View {
        Button("Cancel") {
            cancelSignIn()
        }
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

    private func signIn() async {
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
            authURL = url

            startPolling(primaryPinID: browserPin.id, fallbackPinID: linkPin?.id)
            #endif
        } catch {
            self.error = error.localizedDescription
            isSigningIn = false
        }
    }

    private func startPolling(primaryPinID: Int, fallbackPinID: Int? = nil) {
        pollingTask?.cancel()
        pollingTask = Task {
            let fallbackActivationAttempt = 15

            for attempt in 0..<120 {
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }

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

            isSigningIn = false
            linkPinCode = nil
            authURL = nil
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

    private func handleAuthSheetDismissal() {
        guard isSigningIn else { return }
        cancelSignIn()
    }
    #endif
}
