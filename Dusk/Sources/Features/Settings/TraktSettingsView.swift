import SwiftUI

/// Settings › Trakt: link or unlink the current Plex profile's Trakt account.
/// iOS uses Trakt's PKCE sign-in sheet; tvOS uses QR + device-code tiles.
struct TraktSettingsView: View {
    @Environment(TraktService.self) private var trakt

    static let footerText = "Movies and episodes you finish are added to your Trakt history. Dusk uses Trakt but is not endorsed or certified by Trakt."

    var body: some View {
        Group {
            #if os(tvOS)
            tvContent
            #else
            iosContent
            #endif
        }
        .background(Color.duskBackground.ignoresSafeArea())
        .duskNavigationTitle("Trakt")
        #if DEBUG
        .task {
            if ScreenshotMode.startsTraktSignIn, !trakt.isConnected, trakt.signInState == .idle {
                trakt.startSignIn()
            }
        }
        #endif
    }

    private var deviceCode: TraktDeviceCode? {
        if case .awaitingApproval(let code) = trakt.signInState { return code }
        return nil
    }

    private var isSigningIn: Bool {
        switch trakt.signInState {
        case .authorizing, .requestingCode, .awaitingApproval: true
        case .idle, .failed: false
        }
    }

    private var errorMessage: String? {
        if case .failed(let message) = trakt.signInState { return message }
        return nil
    }

    /// trakt.tv/activate, shown without the scheme.
    private func displayHost(_ code: TraktDeviceCode) -> String {
        code.verificationURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    // MARK: - iOS

    #if !os(tvOS)
    private var iosContent: some View {
        SettingsList {
            Section {
                statusRow
            } footer: {
                Text(Self.footerText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Color.duskTextSecondary)
                }
                .listRowBackground(Color.duskSurface)
            }

            Section {
                if trakt.isConnected {
                    Button("Disconnect", role: .destructive) {
                        trakt.disconnect()
                    }
                } else if trakt.signInState == .authorizing {
                    // Trakt's sheet has its own Cancel; this only covers the code exchange.
                    HStack {
                        Text("Connect Trakt")
                            .foregroundStyle(Color.duskTextSecondary)
                        Spacer()
                        ProgressView()
                    }
                } else if isSigningIn {
                    Button("Cancel") {
                        trakt.cancelSignIn()
                    }
                } else {
                    Button("Connect Trakt") {
                        trakt.startSignIn()
                    }
                }
            }
            .listRowBackground(Color.duskSurface)
        }
        .scrollContentBackground(.hidden)
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    @ViewBuilder
    private var tvContent: some View {
        if isSigningIn {
            tvLinkContent
                .onDisappear { trakt.cancelSignIn() }
        } else {
            tvSettingsContent
        }
    }

    private var tvSettingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                TVSettingsSection(title: "Account", footer: Self.footerText) {
                    statusRow
                    tvRowDivider
                    if trakt.isConnected {
                        TVSettingsActionRow(title: "Disconnect", tint: .red, role: .destructive) {
                            trakt.disconnect()
                        }
                    } else {
                        TVSettingsActionRow(title: "Connect Trakt") {
                            trakt.startSignIn()
                        }
                    }
                }

                if let errorMessage {
                    TVSettingsSection(title: "Connection") {
                        Text(errorMessage)
                            .font(DuskFont.TV.rowValue)
                            .foregroundStyle(Color.duskTextSecondary)
                            .frame(maxWidth: .infinity, minHeight: TVSettingsMetrics.rowMinHeight, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.top, 48)
            .padding(.bottom, 88)
        }
    }

    /// Same layout as the Plex sign-in: QR code left, code and actions right.
    private var tvLinkContent: some View {
        HStack(alignment: .center, spacing: 96) {
            tvQRCodePanel

            VStack(alignment: .leading, spacing: 0) {
                Text("Connect Trakt")
                    .font(DuskFont.TV.pageTitle)
                    .foregroundStyle(Color.duskTextPrimary)

                Text("Scan the QR code with your phone,\nor go to \(Text(deviceCode.map(displayHost) ?? "trakt.tv/activate").foregroundStyle(Color.duskTextPrimary)) and enter this code.")
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
                    Text(deviceCode == nil ? "Getting a code…" : "Waiting for approval…")
                        .font(DuskFont.TV.caption)
                        .foregroundStyle(Color.duskTextSecondary)
                }
                .padding(.top, 28)

                HStack(spacing: 24) {
                    Button {
                        trakt.startSignIn()
                    } label: {
                        Text("New Code")
                            .font(DuskFont.TV.buttonLabel)
                            .frame(minWidth: 220)
                    }
                    .detailHeroNativePrimaryButtonStyle()

                    Button {
                        trakt.cancelSignIn()
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

    private var tvQRCodePanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(.white)

            if let code = deviceCode, let qrImage = SignInQRCode.image(for: code.verificationURL) {
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

    /// Trakt codes are eight characters, so the tiles are narrower than the
    /// Plex sign-in's four.
    private var tvCodeTiles: some View {
        let characters = deviceCode.map { $0.userCode.map(String.init) } ?? Array(repeating: " ", count: 8)
        return HStack(spacing: 12) {
            ForEach(Array(characters.enumerated()), id: \.offset) { _, character in
                Text(character)
                    .font(.system(size: 60, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.duskTextPrimary)
                    .frame(width: 84, height: 112)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    private var tvRowDivider: some View {
        Rectangle()
            .fill(Color.duskTextSecondary.opacity(0.16))
            .frame(height: 1)
    }
    #endif

    // MARK: - Shared

    private var statusRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Status")
                    .duskFont(tvOnly: DuskFont.TV.rowTitle)
                    .foregroundStyle(Color.duskTextPrimary)
                Text(trakt.connectionSubtitle)
                    .font(DuskFont.caption(ios: .caption))
                    .foregroundStyle(Color.duskTextSecondary)
            }
            Spacer()
            ConnectionStatusDot(tone: trakt.isConnected ? .good : .neutral)
        }
        .frame(minHeight: 52)
    }
}
