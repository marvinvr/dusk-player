import SwiftUI

struct PlayerSelectionSheet<Item: Identifiable>: View {
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
        .presentationDetents([.medium])
        .presentationBackground(Color.duskBackground)
        .playerSheetHorizontalSystemBars()
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
