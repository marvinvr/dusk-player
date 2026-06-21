import SwiftUI

struct ServerPickerView: View {
    let servers: [PlexServer]
    let onSelect: (PlexServer) async throws -> Void
    var onSignOut: (() -> Void)? = nil
    /// Provided when the picker is presented as a dismissable sheet (e.g. from
    /// Settings) so the user can back out without choosing a server.
    var onCancel: (() -> Void)? = nil

    @State private var connectingTo: String?
    @State private var connectionError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.duskBackground.ignoresSafeArea()

                serverPickerContent
            }
        }
    }

    @ViewBuilder
    private var serverPickerContent: some View {
        #if os(tvOS)
        tvServerPickerContent
        #else
        iosServerPickerContent
        #endif
    }

    // MARK: - iOS / iPadOS

    #if !os(tvOS)
    private var iosServerPickerContent: some View {
        List {
            if let connectionError {
                Section {
                    errorBanner(connectionError, font: .callout)
                        .padding(.vertical, 4)
                        .listRowBackground(Color.duskSurface)
                }
            }

            Section {
                ForEach(servers) { server in
                    Button {
                        connect(to: server)
                    } label: {
                        ServerRow(
                            server: server,
                            isConnecting: connectingTo == server.clientIdentifier
                        )
                    }
                    .disabled(connectingTo != nil)
                    .listRowBackground(Color.duskSurface)
                }
            } header: {
                descriptionText(font: .subheadline)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 12, trailing: 0))
            }

            if let onSignOut {
                Section {
                    Button("Sign Out", role: .destructive, action: onSignOut)
                        .listRowBackground(Color.duskSurface)
                }
            }
        }
        .duskScrollContentBackgroundHidden()
        .duskNavigationTitle("Choose Server")
        .toolbar {
            if let onCancel {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .tint(Color.duskTextSecondary)
                }
            }
        }
    }
    #endif

    // MARK: - tvOS

    #if os(tvOS)
    private var tvServerPickerContent: some View {
        ScrollView {
            VStack(spacing: 44) {
                header

                if let connectionError {
                    errorBanner(connectionError, font: .body)
                        .padding(24)
                        .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .frame(maxWidth: 760)
                }

                VStack(spacing: 20) {
                    ForEach(servers) { server in
                        TVServerCard(
                            server: server,
                            isConnecting: connectingTo == server.clientIdentifier,
                            isDisabled: connectingTo != nil
                        ) {
                            connect(to: server)
                        }
                    }
                }
                .frame(maxWidth: 760)

                tvBottomAction
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 60)
            .padding(.vertical, 64)
        }
    }

    private var header: some View {
        VStack(spacing: 22) {
            ServerIcon(size: 96, cornerRadius: 28, iconFont: .system(size: 44, weight: .semibold))

            VStack(spacing: 12) {
                Text("Choose Server")
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.duskTextPrimary)

                descriptionText(font: .title3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 720)
            }
        }
    }

    @ViewBuilder
    private var tvBottomAction: some View {
        if let onSignOut {
            TVTextButton(title: "Sign Out", role: .destructive, tint: .red, action: onSignOut)
                .padding(.top, 8)
        } else if let onCancel {
            TVTextButton(title: "Cancel", role: nil, tint: Color.duskTextSecondary, action: onCancel)
                .padding(.top, 8)
        }
    }
    #endif

    // MARK: - Shared pieces

    private func descriptionText(font: Font) -> some View {
        Text("Your Plex account has access to multiple servers. Pick the one you'd like to use — you can switch anytime from Settings.")
            .font(font)
            .foregroundStyle(Color.duskTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .textCase(nil)
    }

    private func errorBanner(_ message: String, font: Font) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.duskTextSecondary)

            Text(message)
                .foregroundStyle(Color.duskTextSecondary)
                .multilineTextAlignment(.leading)

            Spacer(minLength: 0)
        }
        .font(font)
    }

    private func connect(to server: PlexServer) {
        connectionError = nil
        connectingTo = server.clientIdentifier

        Task {
            do {
                try await onSelect(server)
            } catch {
                connectionError = "Could not connect to \(server.name): \(error.localizedDescription)"
                connectingTo = nil
            }
        }
    }
}

// MARK: - Server icon

/// The accent-tinted server glyph used by the hero and every server row, mirroring
/// the icon container style of the Settings rows so the picker feels native.
private struct ServerIcon: View {
    let size: CGFloat
    let cornerRadius: CGFloat
    let iconFont: Font

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.duskAccent.opacity(0.14))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "server.rack")
                    .font(iconFont)
                    .foregroundStyle(Color.duskAccent)
            }
    }
}

private func serverOwnershipText(_ server: PlexServer) -> String {
    server.owned ? "Your server" : "Shared by \(server.sourceTitle ?? "Unknown")"
}

// MARK: - iOS row

#if !os(tvOS)
private struct ServerRow: View {
    let server: PlexServer
    let isConnecting: Bool

    var body: some View {
        HStack(spacing: 14) {
            ServerIcon(size: 36, cornerRadius: 12, iconFont: .subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.duskTextPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(serverOwnershipText(server))
                        .foregroundStyle(Color.duskTextSecondary)
                        .lineLimit(1)

                    Text("·")
                        .foregroundStyle(Color.duskTextSecondary)

                    Text(server.presence ? "Online" : "Offline")
                        .foregroundStyle(server.presence ? Color.duskAccent : Color.duskTextSecondary)
                }
                .font(.caption)
            }

            Spacer(minLength: 12)

            if isConnecting {
                ProgressView()
                    .tint(Color.duskAccent)
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.duskTextSecondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
#endif

// MARK: - tvOS card + text button

#if os(tvOS)
/// A focusable server card. Uses an explicit `@FocusState` + `duskTVOSFocusedScale`
/// because the environment-driven focus effect does not reliably scale/glow when a
/// custom (chrome-suppressed) button style is applied.
private struct TVServerCard: View {
    let server: PlexServer
    let isConnecting: Bool
    let isDisabled: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 24) {
                ServerIcon(size: 64, cornerRadius: 18, iconFont: .system(size: 28, weight: .semibold))

                VStack(alignment: .leading, spacing: 6) {
                    Text(server.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.duskTextPrimary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text(serverOwnershipText(server))
                            .foregroundStyle(Color.duskTextSecondary)
                            .lineLimit(1)

                        Text("·")
                            .foregroundStyle(Color.duskTextSecondary)

                        Text(server.presence ? "Online" : "Offline")
                            .foregroundStyle(server.presence ? Color.duskAccent : Color.duskTextSecondary)
                    }
                    .font(.body)
                }

                Spacer(minLength: 16)

                if isConnecting {
                    ProgressView()
                        .tint(Color.duskAccent)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.duskTextSecondary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .duskSuppressTVOSButtonChrome()
        .focused($isFocused)
        .disabled(isDisabled)
        .duskTVOSFocusedScale(isFocused)
    }
}

/// A compact, focusable text button for the picker's bottom action (Sign Out /
/// Cancel) with a reliable focus highlight.
private struct TVTextButton: View {
    let title: String
    let role: ButtonRole?
    let tint: Color
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(role: role, action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(tint)
                .padding(.horizontal, 30)
                .padding(.vertical, 14)
                .background(
                    Color.duskSurface.opacity(isFocused ? 1 : 0),
                    in: Capsule()
                )
        }
        .duskSuppressTVOSButtonChrome()
        .focused($isFocused)
        .duskTVOSFocusedScale(isFocused)
    }
}
#endif
