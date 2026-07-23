import SwiftUI

/// Shared Plex Home profile picker used during app startup and from Settings.
///
/// PINs are deliberately held only in this view's transient state. The service
/// receives the PIN for the switch request and persists the resulting profile
/// token only when `rememberSelection` is enabled.
struct HomeUserPickerView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(OfflinePlaybackSyncManager.self) private var offlinePlaybackSyncManager

    let users: [PlexHomeUser]
    var onComplete: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    var onSignOut: (() -> Void)? = nil

    @State private var rememberSelection: Bool
    @State private var pendingUser: PlexHomeUser?
    @State private var pin = ""
    @State private var switchingProfileID: String?
    @State private var switchError: String?

    init(
        users: [PlexHomeUser],
        rememberSelection: Bool = true,
        onComplete: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil,
        onSignOut: (() -> Void)? = nil
    ) {
        self.users = users
        self.onComplete = onComplete
        self.onCancel = onCancel
        self.onSignOut = onSignOut
        _rememberSelection = State(initialValue: rememberSelection)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.duskBackground.ignoresSafeArea()

                if let pendingUser {
                    pinEntry(for: pendingUser)
                } else {
                    profileSelection
                }
            }
            .overlay(alignment: .topLeading) {
                if pendingUser != nil {
                    HomeUserBackButton(
                        isDisabled: switchingProfileID != nil,
                        action: leavePINEntry
                    )
                    #if os(tvOS)
                    .padding(.leading, 70)
                    .padding(.top, 48)
                    #else
                    .padding(.leading, 20)
                    .padding(.top, 16)
                    #endif
                }
            }
            #if !os(tvOS)
            .toolbar {
                if pendingUser == nil, let onCancel {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                            .tint(Color.duskTextSecondary)
                            .disabled(switchingProfileID != nil)
                    }
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private var profileSelection: some View {
        #if os(tvOS)
        tvProfileSelection
        #else
        iosProfileSelection
        #endif
    }

    #if !os(tvOS)
    private var iosProfileSelection: some View {
        ScrollView {
            VStack(spacing: 30) {
                pickerHeader(titleSize: 38, iconSize: 66)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 18)],
                    spacing: 18
                ) {
                    ForEach(users, id: \.stableProfileID) { user in
                        HomeUserCard(
                            user: user,
                            avatarSize: 88,
                            isCurrent: user.stableProfileID == plexService.activeProfileID,
                            isSwitching: switchingProfileID == user.stableProfileID,
                            isDisabled: switchingProfileID != nil
                        ) {
                            select(user)
                        }
                    }
                }
                .frame(maxWidth: 680)

                selectionOptions
                    .frame(maxWidth: 680)

                bottomActions
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 36)
            .padding(.bottom, 44)
        }
        .duskNavigationTitle("")
    }
    #endif

    #if os(tvOS)
    private var tvProfileSelection: some View {
        ScrollView {
            VStack(spacing: 42) {
                pickerHeader(titleSize: 50, iconSize: 82)

                LazyVGrid(
                    columns: tvProfileColumns,
                    spacing: 34
                ) {
                    ForEach(users, id: \.stableProfileID) { user in
                        HomeUserCard(
                            user: user,
                            avatarSize: 142,
                            isCurrent: user.stableProfileID == plexService.activeProfileID,
                            isSwitching: switchingProfileID == user.stableProfileID,
                            isDisabled: switchingProfileID != nil
                        ) {
                            select(user)
                        }
                    }
                }
                .frame(width: tvProfileGridWidth)

                selectionOptions
                    .frame(width: tvProfileGridWidth)

                bottomActions
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 64)
            .padding(.top, 58)
            .padding(.bottom, 80)
        }
    }

    private var tvProfileColumns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(250), spacing: 34),
            count: min(max(users.count, 1), 4)
        )
    }

    private var tvProfileGridWidth: CGFloat {
        let columnCount = CGFloat(min(max(users.count, 1), 4))
        return (columnCount * 250) + (max(columnCount - 1, 0) * 34)
    }
    #endif

    private func pickerHeader(titleSize: CGFloat, iconSize: CGFloat) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "person.2.fill")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(Color.duskAccent)

            VStack(spacing: 9) {
                Text("Who’s Watching?")
                    .font(.system(size: titleSize, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.duskTextPrimary)

                Text("Choose a Plex Home user. Watch history and recommendations will stay with this profile.")
                    .font(.body)
                    .foregroundStyle(Color.duskTextSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 680)
            }
        }
    }

    private var selectionOptions: some View {
        Toggle(isOn: $rememberSelection) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Remember This User")
                    .font(.headline)
                    .foregroundStyle(Color.duskTextPrimary)

                Text("Open Dusk with this profile next time. You can change this anytime in Settings.")
                    .font(.subheadline)
                    .foregroundStyle(Color.duskTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Color.duskAccent)
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder
    private var bottomActions: some View {
        if let switchError {
            Label(switchError, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 680)
        }

        #if os(tvOS)
        if let onCancel {
            HomeUserTextButton(title: "Cancel", tint: Color.duskTextSecondary, action: onCancel)
                .disabled(switchingProfileID != nil)
        } else if let onSignOut {
            HomeUserTextButton(title: "Sign Out", tint: .red, role: .destructive, action: onSignOut)
                .disabled(switchingProfileID != nil)
        }
        #else
        if onCancel == nil, let onSignOut {
            Button("Sign Out", role: .destructive, action: onSignOut)
                .font(.headline)
                .disabled(switchingProfileID != nil)
        }
        #endif
    }

    private func select(_ user: PlexHomeUser) {
        switchError = nil

        if user.isProtected {
            pin = ""
            pendingUser = user
        } else {
            switchTo(user, pin: nil)
        }
    }

    @ViewBuilder
    private func pinEntry(for user: PlexHomeUser) -> some View {
        #if os(tvOS)
        TVHomeUserPINView(
            user: user,
            pin: $pin,
            isSubmitting: switchingProfileID != nil,
            error: switchError,
            onSubmit: { switchTo(user, pin: pin) }
        )
        #else
        IOSHomeUserPINView(
            user: user,
            pin: $pin,
            isSubmitting: switchingProfileID != nil,
            error: switchError,
            onSubmit: { switchTo(user, pin: pin) }
        )
        #endif
    }

    private func leavePINEntry() {
        guard switchingProfileID == nil else { return }
        pin = ""
        switchError = nil
        pendingUser = nil
    }

    private func switchTo(_ user: PlexHomeUser, pin: String?) {
        guard switchingProfileID == nil else { return }

        switchError = nil
        switchingProfileID = user.stableProfileID

        Task {
            downloadManager.prepareForProfileSwitch()
            await offlinePlaybackSyncManager.prepareForProfileSwitch()

            do {
                try await plexService.switchHomeUser(
                    user,
                    pin: pin?.nilIfEmpty,
                    remember: rememberSelection
                )
                downloadManager.activateProfile()
                offlinePlaybackSyncManager.activateProfile()
                switchingProfileID = nil
                self.pin = ""
                pendingUser = nil
                onComplete?()
            } catch {
                // The service keeps the previous identity active when switching
                // fails, so resume that profile's queues and delayed sync work.
                downloadManager.activateProfile()
                offlinePlaybackSyncManager.activateProfile()
                switchError = error.localizedDescription
                switchingProfileID = nil
                self.pin = ""
            }
        }
    }
}

private struct HomeUserBackButton: View {
    let isDisabled: Bool
    let action: () -> Void

    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(Color.duskTextPrimary)
                .frame(width: buttonSize, height: buttonSize)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.primary.opacity(borderOpacity), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .duskSuppressTVOSButtonChrome()
        #if os(tvOS)
        .focused($isFocused)
        .duskTVOSFocusedScale(isFocused)
        #endif
        .accessibilityLabel("Back")
    }

    private var buttonSize: CGFloat {
        #if os(tvOS)
        68
        #else
        46
        #endif
    }

    private var iconSize: CGFloat {
        #if os(tvOS)
        26
        #else
        17
        #endif
    }

    private var borderOpacity: Double {
        #if os(tvOS)
        isFocused ? 0.22 : 0.08
        #else
        0.08
        #endif
    }
}

// MARK: - Shared profile artwork

struct PlexHomeUserAvatar: View {
    let user: PlexHomeUser
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.duskAccent.opacity(0.14))

            DuskAsyncImage(url: user.avatarURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .empty, .failure:
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.44, weight: .medium))
                        .foregroundStyle(Color.duskAccent)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct HomeUserCard: View {
    let user: PlexHomeUser
    let avatarSize: CGFloat
    let isCurrent: Bool
    let isSwitching: Bool
    let isDisabled: Bool
    let action: () -> Void

    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                ZStack(alignment: .bottomTrailing) {
                    PlexHomeUserAvatar(user: user, size: avatarSize)

                    if user.isProtected {
                        Image(systemName: "lock.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.duskTextPrimary)
                            .padding(8)
                            .background(Color.duskSurface, in: Circle())
                    }
                }

                HStack(spacing: 6) {
                    Text(user.displayName)
                        .font(.headline)
                        .foregroundStyle(Color.duskTextPrimary)
                        .lineLimit(1)

                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Color.duskAccent)
                    }
                }

                if isSwitching {
                    ProgressView()
                        .tint(Color.duskAccent)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 20)
            .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(isCurrent ? Color.duskAccent.opacity(0.75) : Color.primary.opacity(0.05), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .disabled(isDisabled)
        .duskSuppressTVOSButtonChrome()
        #if os(tvOS)
        .focused($isFocused)
        .duskTVOSFocusedScale(isFocused)
        #endif
        .accessibilityLabel(user.displayName)
        .accessibilityHint(user.isProtected ? "PIN required" : "Switch to this user")
    }
}

#if !os(tvOS)
private struct IOSHomeUserPINView: View {
    @Environment(\.openURL) private var openURL

    let user: PlexHomeUser
    @Binding var pin: String
    let isSubmitting: Bool
    let error: String?
    let onSubmit: () -> Void

    @FocusState private var pinIsFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                PlexHomeUserAvatar(user: user, size: 104)

                VStack(spacing: 8) {
                    Text("Enter PIN")
                        .font(.largeTitle.bold())
                        .foregroundStyle(Color.duskTextPrimary)

                    Text("Enter the four-digit Plex Home PIN for \(user.displayName).")
                        .font(.body)
                        .foregroundStyle(Color.duskTextSecondary)
                        .multilineTextAlignment(.center)
                }

                SecureField("PIN", text: $pin)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(.title, design: .monospaced, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                    .frame(width: 220, height: 56)
                    .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .focused($pinIsFocused)
                    .onChange(of: pin) { _, newValue in
                        pin = String(newValue.filter(\.isNumber).prefix(4))
                    }
                    .onSubmit(onSubmit)
                    .disabled(isSubmitting)

                if let error {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button(action: onSubmit) {
                    HStack(spacing: 9) {
                        if isSubmitting {
                            ProgressView()
                                .tint(Color.duskPrimaryActionLabel)
                        }
                        Text("Continue")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                }
                .foregroundStyle(Color.duskPrimaryActionLabel)
                .background(Color.primary.opacity(0.88), in: Capsule())
                .disabled(pin.count != 4 || isSubmitting)
                .opacity(pin.count == 4 ? 1 : 0.45)
                .frame(maxWidth: 360)

                Button("Forgot PIN?") {
                    openURL(SettingsSupport.plexAccountURL)
                }
                .font(.footnote)
                .foregroundStyle(Color.duskAccent)
                .disabled(isSubmitting)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 44)
        }
        .scrollDismissesKeyboard(.interactively)
        .task {
            pinIsFocused = true
        }
    }
}
#endif

#if os(tvOS)
private struct TVHomeUserPINView: View {
    let user: PlexHomeUser
    @Binding var pin: String
    let isSubmitting: Bool
    let error: String?
    let onSubmit: () -> Void

    private let keypadRows = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        ["delete.left", "0", "checkmark"],
    ]

    var body: some View {
        HStack(spacing: 88) {
            VStack(spacing: 24) {
                PlexHomeUserAvatar(user: user, size: 148)

                VStack(spacing: 9) {
                    Text("Enter PIN")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.duskTextPrimary)

                    Text("Enter the four-digit Plex Home PIN for \(user.displayName).")
                        .font(.title3)
                        .foregroundStyle(Color.duskTextSecondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 16) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle()
                            .fill(index < pin.count ? Color.duskAccent : Color.duskSurface)
                            .frame(width: 22, height: 22)
                            .overlay {
                                Circle()
                                    .stroke(Color.duskTextSecondary.opacity(0.35), lineWidth: 1)
                            }
                    }
                }
                .padding(.vertical, 8)

                if let error {
                    Text(error)
                        .font(.body)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }

                Text("Forgot your PIN? Manage Plex Home from your Plex account on another device.")
                    .font(.footnote)
                    .foregroundStyle(Color.duskTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            .frame(maxWidth: 600)

            VStack(spacing: 18) {
                ForEach(Array(keypadRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 18) {
                        ForEach(row, id: \.self) { key in
                            TVPINKey(
                                key: key,
                                isEnabled: keyEnabled(key),
                                action: { activate(key) }
                            )
                        }
                    }
                }

                if isSubmitting {
                    ProgressView()
                        .tint(Color.duskAccent)
                        .padding(.top, 8)
                }
            }
        }
        .frame(maxWidth: 1180)
        .padding(.horizontal, 70)
        .padding(.vertical, 60)
    }

    private func keyEnabled(_ key: String) -> Bool {
        guard !isSubmitting else { return false }
        if key == "delete.left" {
            return !pin.isEmpty
        }
        if key == "checkmark" {
            return pin.count == 4
        }
        return pin.count < 4
    }

    private func activate(_ key: String) {
        switch key {
        case "delete.left":
            if !pin.isEmpty {
                pin.removeLast()
            }
        case "checkmark":
            guard pin.count == 4 else { return }
            onSubmit()
        default:
            guard pin.count < 4 else { return }
            pin.append(key)
        }
    }
}

private struct TVPINKey: View {
    let key: String
    let isEnabled: Bool
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Group {
                if key == "delete.left" || key == "checkmark" {
                    Image(systemName: key)
                } else {
                    Text(key)
                }
            }
            .font(.title2.weight(.semibold))
            .foregroundStyle(Color.duskTextPrimary)
            .frame(width: 92, height: 72)
            .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .duskSuppressTVOSButtonChrome()
        .focused($isFocused)
        .duskTVOSFocusedScale(isFocused)
    }
}

private struct HomeUserTextButton: View {
    let title: String
    let tint: Color
    var role: ButtonRole? = nil
    let action: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if let role {
                Button(role: role, action: action) {
                    Text(title)
                }
            } else {
                Button(action: action) {
                    Text(title)
                }
            }
        }
        .font(.headline)
        .foregroundStyle(tint)
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(Color.duskSurface.opacity(isFocused ? 1 : 0), in: Capsule())
        .duskSuppressTVOSButtonChrome()
        .focused($isFocused)
        .duskTVOSFocusedScale(isFocused)
    }
}
#endif
