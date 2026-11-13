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

    private var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
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
            #if os(tvOS)
            .onExitCommand {
                if pendingUser != nil {
                    leavePINEntry()
                } else {
                    onCancel?()
                }
            }
            #else
            .overlay(alignment: .topLeading) {
                if !isMac, pendingUser != nil {
                    HomeUserBackButton(
                        isDisabled: switchingProfileID != nil,
                        action: leavePINEntry
                    )
                    .padding(.leading, 20)
                    .padding(.top, 16)
                }
            }
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
        #elseif os(macOS)
        macProfileSelection
        #else
        iosProfileSelection
        #endif
    }

    #if os(macOS)
    /// The Mac picker: a centred group of compact profile cards, a plain
    /// "Remember this user" checkbox and Sign Out as a bordered button.
    private var macProfileSelection: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 6) {
                        Text("Who’s Watching?")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(Color.duskTextPrimary)

                        Text("Choose a Plex Home user. Watch history and recommendations stay with each profile.")
                            .font(.body)
                            .foregroundStyle(Color.duskTextSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 460)
                    }

                    LazyVGrid(columns: macProfileColumns, spacing: 16) {
                        ForEach(users, id: \.stableProfileID) { user in
                            MacHomeUserCard(
                                user: user,
                                isCurrent: user.stableProfileID == plexService.activeProfileID,
                                isSwitching: switchingProfileID == user.stableProfileID,
                                isDisabled: switchingProfileID != nil
                            ) {
                                select(user)
                            }
                        }
                    }
                    .fixedSize()

                    VStack(spacing: 16) {
                        Toggle("Remember this user", isOn: $rememberSelection)
                            .toggleStyle(.checkbox)
                            .help("Open Dusk with this profile next time. You can change this anytime in Settings.")

                        if let switchError {
                            Label(switchError, systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 460)
                        }

                        if onCancel == nil, let onSignOut {
                            Button("Sign Out", action: onSignOut)
                                .buttonStyle(.bordered)
                                .disabled(switchingProfileID != nil)
                        }
                    }
                }
                .padding(MacUILayout.contentInset * 2)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .navigationTitle("Who’s Watching?")
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private var macProfileColumns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(MacHomeUserCard.size.width), spacing: 16),
            count: min(max(users.count, 1), 5)
        )
    }
    #endif

    #if os(iOS)
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
            VStack(spacing: 34) {
                pickerHeader(titleSize: DuskFont.TV.Size.pageTitle, iconSize: 72)

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
                    .frame(maxWidth: 1120)

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
                .foregroundStyle(Color.duskTextSecondary)

            VStack(spacing: 9) {
                Text("Who’s Watching?")
                    .font(.system(size: titleSize, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.duskTextPrimary)

                Text("Choose a Plex Home user. Watch history and recommendations will stay with this profile.")
                    .font(DuskFont.pageSubtitle(ios: .body))
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
                    .font(DuskFont.rowTitle(ios: .headline))
                    .foregroundStyle(Color.duskTextPrimary)

                Text("Open Dusk with this profile next time. You can change this anytime in Settings.")
                    .font(DuskFont.caption(ios: .subheadline))
                    .foregroundStyle(Color.duskTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder
    private var bottomActions: some View {
        if let switchError {
            Label(switchError, systemImage: "exclamationmark.triangle.fill")
                .font(DuskFont.body(ios: .callout))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 680)
        }

        #if os(tvOS)
        if onCancel == nil, let onSignOut {
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
            onSubmit: { switchTo(user, pin: pin) },
            onBack: leavePINEntry
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

#if !os(tvOS)
private struct HomeUserBackButton: View {
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.duskTextPrimary)
                .frame(width: 46, height: 46)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .duskSuppressTVOSButtonChrome()
        .accessibilityLabel("Back")
    }
}
#endif

// MARK: - Shared profile artwork

struct PlexHomeUserAvatar: View {
    let user: PlexHomeUser
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.duskTextSecondary.opacity(0.14))

            DuskAsyncImage(url: user.avatarURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .empty, .failure:
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.44, weight: .medium))
                        .foregroundStyle(Color.duskTextSecondary)
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
                            .font(DuskFont.badge(ios: .caption.weight(.bold)))
                            .foregroundStyle(Color.duskTextPrimary)
                            .padding(8)
                            .background(Color.duskSurface, in: Circle())
                    }
                }

                HStack(spacing: 6) {
                    Text(user.displayName)
                        .font(DuskFont.rowTitle(ios: .headline))
                        .foregroundStyle(Color.duskTextPrimary)
                        .lineLimit(1)

                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .font(DuskFont.glyphSmall(ios: .subheadline))
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }

                ZStack {
                    if isSwitching {
                        ProgressView()
                    }
                }
                .frame(height: 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.vertical, 20)
            .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(isCurrent ? Color.duskTextPrimary.opacity(0.35) : Color.primary.opacity(0.05), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        #if os(macOS)
        // The card is the button; no push-button bezel around it.
        .buttonStyle(.plain)
        #endif
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

#if os(macOS)
/// A Mac profile card: avatar and name on a quiet rounded tile that lifts
/// its fill on hover, about 140 × 170.
private struct MacHomeUserCard: View {
    static let size = CGSize(width: 140, height: 170)

    let user: PlexHomeUser
    let isCurrent: Bool
    let isSwitching: Bool
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    PlexHomeUserAvatar(user: user, size: 96)
                        .overlay {
                            if isSwitching {
                                Circle().fill(.black.opacity(0.45))
                                ProgressView()
                                    .controlSize(.small)
                                    .environment(\.colorScheme, .dark)
                            }
                        }

                    if user.isProtected {
                        Image(systemName: "lock.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .background(.regularMaterial, in: Circle())
                            .help("PIN required")
                    }
                }

                HStack(spacing: 4) {
                    Text(user.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Color.duskTextPrimary)
                        .lineLimit(1)

                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .help("Current profile")
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isHovered ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(.fill.quaternary))
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityLabel(user.displayName)
        .accessibilityHint(user.isProtected ? "PIN required" : "Switch to this user")
    }
}
#endif

#if !os(tvOS)
private struct IOSHomeUserPINView: View {
    @Environment(\.openURL) private var openURL

    let user: PlexHomeUser
    @Binding var pin: String
    let isSubmitting: Bool
    let error: String?
    let onSubmit: () -> Void
    /// Mac only: the Back button next to Continue (iOS has the overlay one).
    var onBack: (() -> Void)? = nil

    @FocusState private var pinIsFocused: Bool

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    #if os(macOS)
    private var macBody: some View {
        VStack(spacing: 18) {
            PlexHomeUserAvatar(user: user, size: 80)

            VStack(spacing: 4) {
                Text("Enter PIN")
                    .font(.title2.bold())
                    .foregroundStyle(Color.duskTextPrimary)

                Text("Enter the four-digit Plex Home PIN for \(user.displayName).")
                    .foregroundStyle(Color.duskTextSecondary)
            }

            SecureField("PIN", text: $pin)
                .textContentType(.oneTimeCode)
                .font(.system(.title2, design: .monospaced, weight: .semibold))
                .multilineTextAlignment(.center)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
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
            }

            HStack(spacing: 10) {
                if let onBack {
                    Button("Back", action: onBack)
                        .keyboardShortcut(.cancelAction)
                        .disabled(isSubmitting)
                }

                Button(action: onSubmit) {
                    HStack(spacing: 6) {
                        if isSubmitting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Continue")
                    }
                    .frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(pin.count != 4 || isSubmitting)
            }
            .controlSize(.large)

            Button("Forgot PIN?") {
                openURL(SettingsSupport.plexAccountURL)
            }
            .buttonStyle(.link)
            .font(.callout)
            .disabled(isSubmitting)
        }
        .multilineTextAlignment(.center)
        .padding(MacUILayout.contentInset * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            pinIsFocused = true
        }
    }
    #endif

    private var iosBody: some View {
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
                    #if !os(macOS)
                    .keyboardType(.numberPad)
                    #endif
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
                        .font(.footnote)
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
                #if os(macOS)
                .buttonStyle(.plain)
                #endif
                .foregroundStyle(Color.duskPrimaryActionLabel)
                .background(Color.primary.opacity(0.88), in: Capsule())
                .disabled(pin.count != 4 || isSubmitting)
                .opacity(pin.count == 4 ? 1 : 0.45)
                .frame(maxWidth: 360)

                Button("Forgot PIN?") {
                    openURL(SettingsSupport.plexAccountURL)
                }
                .font(.footnote)
                .foregroundStyle(Color.duskTextSecondary)
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
        ["", "0", "delete.left"],
    ]

    var body: some View {
        HStack(spacing: 120) {
            VStack(spacing: 28) {
                PlexHomeUserAvatar(user: user, size: 176)

                VStack(spacing: 10) {
                    Text("Enter PIN")
                        .font(DuskFont.TV.pageTitleRounded)
                        .foregroundStyle(Color.duskTextPrimary)

                    Text("Enter the four-digit Plex Home PIN for \(user.displayName).")
                        .font(DuskFont.TV.pageSubtitle)
                        .foregroundStyle(Color.duskTextSecondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 16) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle()
                            .fill(index < pin.count ? Color.duskTextPrimary : Color.duskSurface)
                            .frame(width: 25, height: 25)
                            .overlay {
                                Circle()
                                    .stroke(Color.duskTextSecondary.opacity(0.35), lineWidth: 1)
                            }
                    }
                }
                .padding(.vertical, 8)

                ZStack {
                    if let error {
                        Text(error)
                            .font(DuskFont.TV.body)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(maxWidth: 620)
                    }
                }
                .frame(height: 60)

                Text("Forgot your PIN? Manage Plex Home from your Plex account on another device.")
                    .font(DuskFont.TV.caption)
                    .foregroundStyle(Color.duskTextSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 620)
            }
            .frame(width: 650)

            VStack(spacing: 22) {
                ForEach(Array(keypadRows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 22) {
                        ForEach(row, id: \.self) { key in
                            if key.isEmpty {
                                Color.clear
                                    .frame(width: 112, height: 82)
                            } else {
                                TVPINKey(
                                    key: key,
                                    isEnabled: keyEnabled(key),
                                    action: { activate(key) }
                                )
                            }
                        }
                    }
                }

                ZStack {
                    if isSubmitting {
                        ProgressView()
                    }
                }
                .frame(height: 32)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: 1420)
        .padding(.horizontal, 80)
        .padding(.vertical, 72)
    }

    private func keyEnabled(_ key: String) -> Bool {
        guard !isSubmitting else { return false }
        if key == "delete.left" {
            return !pin.isEmpty
        }
        return pin.count < 4
    }

    private func activate(_ key: String) {
        switch key {
        case "delete.left":
            if !pin.isEmpty {
                pin.removeLast()
            }
        default:
            guard pin.count < 4 else { return }
            pin.append(key)
            if pin.count == 4 {
                onSubmit()
            }
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
                if key == "delete.left" {
                    Image(systemName: key)
                } else {
                    Text(key)
                }
            }
            // One-off: the keypad digit is sized to the key tile, not to a text
            // role, so it stays an explicit point size (see DuskFont's escape
            // hatch) rather than borrowing a semantic token.
            .font(.system(size: 40, weight: .semibold))
            .foregroundStyle(Color.duskTextPrimary)
            .frame(width: 112, height: 82)
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
        .font(DuskFont.TV.buttonLabel)
        .foregroundStyle(tint)
        .padding(.horizontal, 26)
        .padding(.vertical, 10)
        .background(Color.duskSurface.opacity(isFocused ? 1 : 0), in: Capsule())
        .duskSuppressTVOSButtonChrome()
        .focused($isFocused)
        .duskTVOSFocusedScale(isFocused)
    }
}
#endif
