import SwiftUI

struct SignInView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(\.openURL) private var openURL
    @State private var linkPinCode: String?
    @State private var isSigningIn = false
    @State private var error: String?
    @State private var pollingTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Branding
                VStack(spacing: 16) {
                    Image("LaunchLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)

                    VStack(spacing: 6) {
                        Text("Dusk")
                            .font(.largeTitle.bold())
                            .foregroundStyle(Color.duskTextPrimary)
                        Text("The Plex App we Deserve.")
                            .font(.subheadline)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }

                Spacer()

                // Sign-in content
                VStack(spacing: 24) {
                    if let error {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }

                    if isSigningIn {
                        VStack(spacing: 12) {
                            Text("Approve in the browser that opened, or go to")
                                .foregroundStyle(Color.duskTextSecondary)
                                .font(.callout)

                            if let linkPinCode {
                                Text("plex.tv/link")
                                    .font(.headline)
                                    .foregroundStyle(Color.duskTextPrimary)
                                Text("and enter this code:")
                                    .foregroundStyle(Color.duskTextSecondary)
                                    .font(.callout)
                                Text(linkPinCode)
                                    .font(.system(.title, design: .monospaced, weight: .bold))
                                    .tracking(4)
                                    .foregroundStyle(Color.duskTextPrimary)
                            }
                        }
                    }

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
                    .padding(.horizontal, 40)

                    if isSigningIn {
                        Button("Cancel") {
                            cancelSignIn()
                        }
                        .foregroundStyle(Color.duskTextSecondary)
                        .duskSuppressTVOSButtonChrome()
                    }
                }

                Spacer()
                    .frame(height: 60)
            }
        }
        .onDisappear {
            pollingTask?.cancel()
        }
    }

    private func signIn() async {
        isSigningIn = true
        error = nil
        linkPinCode = nil

        do {
            // Plex uses a longer-lived "strong" PIN for browser approval, but
            // plex.tv/link expects the short code flow, so we keep both active.
            let browserPin = try await plexService.generatePin(strong: true)
            let linkPin = try? await plexService.generatePin()
            linkPinCode = linkPin?.code

            // Open the Plex auth page in Safari
            if let url = plexService.authURL(for: browserPin) {
                openURL(url)
            }

            startPolling(pinIDs: [browserPin.id, linkPin?.id].compactMap { $0 })
        } catch {
            self.error = error.localizedDescription
            isSigningIn = false
        }
    }

    private func startPolling(pinIDs: [Int]) {
        pollingTask?.cancel()
        pollingTask = Task {
            for _ in 0..<120 {
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }

                for pinID in pinIDs {
                    if let token = try? await plexService.checkPin(pinID) {
                        plexService.setAuthToken(token)
                        isSigningIn = false
                        linkPinCode = nil
                        return
                    }
                }
            }

            isSigningIn = false
            linkPinCode = nil
            error = "Sign-in timed out. Please try again."
        }
    }

    private func cancelSignIn() {
        pollingTask?.cancel()
        isSigningIn = false
        linkPinCode = nil
    }
}
