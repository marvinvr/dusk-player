import SwiftUI

struct SignInView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(\.openURL) private var openURL
    @State private var pinCode: String?
    @State private var isSigningIn = false
    @State private var error: String?
    @State private var pollingTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                VStack(spacing: 8) {
                    Text("Dusk")
                        .font(.largeTitle.bold())
                        .foregroundStyle(Color.duskTextPrimary)
                    Text("A Plex client for Apple platforms")
                        .foregroundStyle(Color.duskTextSecondary)
                }

                Spacer()

                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                if let pinCode, isSigningIn {
                    VStack(spacing: 12) {
                        Text("Approve in the browser, or go to")
                            .foregroundStyle(Color.duskTextSecondary)
                            .font(.callout)
                        Text("plex.tv/link")
                            .font(.headline)
                            .foregroundStyle(Color.duskTextPrimary)
                        Text("and enter code:")
                            .foregroundStyle(Color.duskTextSecondary)
                            .font(.callout)
                        Text(pinCode)
                            .font(.system(.title, design: .monospaced, weight: .bold))
                            .tracking(4)
                            .foregroundStyle(Color.duskTextPrimary)
                    }
                    .padding()
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
                    .padding()
                    .foregroundStyle(.white)
                    .background {
                        RoundedRectangle(cornerRadius: 12)
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

                Spacer()
            }
        }
        .onDisappear {
            pollingTask?.cancel()
        }
    }

    private func signIn() async {
        isSigningIn = true
        error = nil
        pinCode = nil

        do {
            let pin = try await plexService.generatePin()
            pinCode = pin.code

            // Open the Plex auth page in Safari
            if let url = plexService.authURL(for: pin) {
                openURL(url)
            }

            startPolling(pinId: pin.id)
        } catch {
            self.error = error.localizedDescription
            isSigningIn = false
        }
    }

    private func startPolling(pinId: Int) {
        pollingTask?.cancel()
        pollingTask = Task {
            for _ in 0..<120 {
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }

                if let token = try? await plexService.checkPin(pinId) {
                    plexService.setAuthToken(token)
                    isSigningIn = false
                    pinCode = nil
                    return
                }
            }

            isSigningIn = false
            pinCode = nil
            error = "Sign-in timed out. Please try again."
        }
    }

    private func cancelSignIn() {
        pollingTask?.cancel()
        isSigningIn = false
        pinCode = nil
    }
}
