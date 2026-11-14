import SwiftUI

struct PlayerSelectionSheet<Item: Identifiable, Footer: View>: View {
    let title: String
    /// A quiet line above the rows, e.g. what the choice currently resolves to.
    var headerText: String?
    var allowsDeselection = false
    var deselectionTitle = "Off"
    let items: [Item]
    let selectedID: Item.ID?
    let itemTitle: KeyPath<Item, String>
    let itemSubtitle: KeyPath<Item, String?>
    let onSelect: (Item?) -> Void
    let onDismiss: () -> Void
    /// Extra sections below the rows (the Audio sheet's offset control).
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        NavigationStack {
            List {
                if let headerText {
                    Section {
                        rows
                    } header: {
                        Text(headerText)
                            .textCase(nil)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                } else {
                    rows
                }

                footer()
            }
            .duskScrollContentBackgroundHidden()
            .background(Color.duskBackground)
            .duskNavigationTitle(title)
            .duskNavigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDismiss)
                        .duskSuppressTVOSButtonChrome()
                }
            }
        }
        // iPad form sheets at .medium are too short for the Audio sheet's
        // offset row; start them full height there.
        .presentationDetents(Self.detents)
        .presentationBackground(Color.duskBackground)
        .playerSheetHorizontalSystemBars()
    }

    private static var detents: Set<PresentationDetent> {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? [.large] : [.medium, .large]
        #else
        [.medium]
        #endif
    }

    @ViewBuilder
    private var rows: some View {
        if allowsDeselection {
            Button {
                onSelect(nil)
            } label: {
                pickerRow(
                    title: deselectionTitle,
                    subtitle: nil,
                    isSelected: selectedID == nil
                )
            }
            .listRowBackground(Color.duskSurface)
            .duskSuppressTVOSButtonChrome()
        }

        ForEach(items) { item in
            Button {
                onSelect(item)
            } label: {
                pickerRow(
                    title: item[keyPath: itemTitle],
                    subtitle: item[keyPath: itemSubtitle],
                    isSelected: selectedID == item.id
                )
            }
            .listRowBackground(Color.duskSurface)
            .duskSuppressTVOSButtonChrome()
        }
    }

    private func pickerRow(title: String, subtitle: String?, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .duskFont(tvOnly: DuskFont.TV.rowTitle)
                    .foregroundStyle(Color.duskTextPrimary)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(DuskFont.caption(ios: .caption))
                        .foregroundStyle(Color.duskTextSecondary)
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(DuskFont.glyphSmall(ios: .caption.weight(.bold)))
                    .foregroundStyle(Color.duskTextPrimary)
            }
        }
    }
}

extension PlayerSelectionSheet where Footer == EmptyView {
    init(
        title: String,
        headerText: String? = nil,
        allowsDeselection: Bool = false,
        deselectionTitle: String = "Off",
        items: [Item],
        selectedID: Item.ID?,
        itemTitle: KeyPath<Item, String>,
        itemSubtitle: KeyPath<Item, String?>,
        onSelect: @escaping (Item?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.init(
            title: title,
            headerText: headerText,
            allowsDeselection: allowsDeselection,
            deselectionTitle: deselectionTitle,
            items: items,
            selectedID: selectedID,
            itemTitle: itemTitle,
            itemSubtitle: itemSubtitle,
            onSelect: onSelect,
            onDismiss: onDismiss,
            footer: { EmptyView() }
        )
    }
}

private extension View {
    /// iPhone Duo's cover display: a sheet over the player otherwise brings the
    /// vertical bar back, an empty ~80pt strip down one side of the picker
    /// (the player itself opts out, see `playerHorizontalSystemBars`). The
    /// sheet's own preference wins while it is up. No-op everywhere else.
    @ViewBuilder
    func playerSheetHorizontalSystemBars() -> some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            toolbarVerticalBehavior(.disabled)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if os(iOS)
/// Manual audio sync (#67) below the Audio sheet's tracks: a native stepper
/// in 50 ms steps, the current value, and Reset. Disabled with a short reason
/// where it cannot apply (HDR on AVPlayer, AirPlay).
struct PlayerAudioOffsetSection: View {
    @Environment(PlaybackCoordinator.self) private var playback

    var body: some View {
        let availability = playback.audioOffsetAvailability
        let offset = playback.audioOffsetMilliseconds

        Section {
            Stepper(
                value: Binding(
                    get: { playback.audioOffsetMilliseconds },
                    set: { playback.setAudioOffset(milliseconds: $0) }
                ),
                in: AudioOffsetPolicy.range,
                step: AudioOffsetPolicy.stepMilliseconds
            ) {
                HStack {
                    Text("Audio Offset")
                        .foregroundStyle(Color.duskTextPrimary)
                    Spacer()
                    Text(AudioOffsetPolicy.title(for: offset))
                        .monospacedDigit()
                        .foregroundStyle(Color.duskTextSecondary)
                }
            }
            .disabled(!availability.isAvailable)
            .accessibilityValue(AudioOffsetPolicy.title(for: offset))
            .listRowBackground(Color.duskSurface)

            if offset != 0, availability.isAvailable {
                Button("Reset") {
                    playback.setAudioOffset(milliseconds: 0)
                }
                .listRowBackground(Color.duskSurface)
            }
        } footer: {
            Text(availability.unavailableReason ?? AudioOffsetPolicy.timingDescription)
                .foregroundStyle(Color.duskTextSecondary)
        }
    }
}
#endif
