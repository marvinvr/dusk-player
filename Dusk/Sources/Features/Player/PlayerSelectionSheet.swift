import SwiftUI

struct PlayerSelectionSheet<Item: Identifiable>: View {
    let title: String
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
                    .foregroundStyle(Color.duskAccent)
            }
        }
    }
}
