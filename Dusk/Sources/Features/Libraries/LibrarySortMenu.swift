import SwiftUI

/// The sort menu's contents, shared by the library grids and collection
/// pages: a "Sort By" section of fields and, for a field with a direction,
/// an "Order" section. A collection leads with its own order (`defaultTitle`,
/// "Collection Order"), which is what a `nil` selection means.
struct LibrarySortMenuSections: View {
    let fields: [LibrarySortField]
    let selected: LibrarySortOption?
    var defaultTitle: String?
    let select: (LibrarySortOption?) -> Void

    var body: some View {
        Section("Sort By") {
            if let defaultTitle {
                checkButton(defaultTitle, isOn: selected == nil) {
                    guard selected != nil else { return }
                    select(nil)
                }
            }
            ForEach(fields) { field in
                checkButton(field.title, isOn: selected?.field == field) {
                    guard field != selected?.field else { return }
                    select(LibrarySortOption(field))
                }
            }
        }
        if let selected, selected.field.hasDirection {
            Section("Order") {
                directionButton(selected.field, descending: false)
                directionButton(selected.field, descending: true)
            }
        }
    }

    private func directionButton(_ field: LibrarySortField, descending: Bool) -> some View {
        let title = descending ? field.directionTitles.descending : field.directionTitles.ascending
        return checkButton(title, isOn: selected?.isDescending == descending) {
            select(LibrarySortOption(field, descending: descending))
        }
    }

    private func checkButton(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isOn {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

#if os(macOS)
/// The Mac toolbar's sort menu contents: inline pickers, so the menu shows
/// the system's own checkmarks. A `nil` field is the collection's order.
struct LibrarySortMenuPickers: View {
    let fields: [LibrarySortField]
    let selected: LibrarySortOption?
    var defaultTitle: String?
    let select: (LibrarySortOption?) -> Void

    var body: some View {
        Picker("Sort By", selection: Binding<LibrarySortField?>(
            get: { selected?.field },
            set: { field in
                guard field != selected?.field else { return }
                select(field.map { LibrarySortOption($0) })
            }
        )) {
            if let defaultTitle {
                Text(defaultTitle).tag(LibrarySortField?.none)
            }
            ForEach(fields) { field in
                Text(field.title).tag(LibrarySortField?.some(field))
            }
        }
        .pickerStyle(.inline)

        if let selected, selected.field.hasDirection {
            let field = selected.field
            Picker("Order", selection: Binding(
                get: { selected.isDescending },
                set: { select(LibrarySortOption(field, descending: $0)) }
            )) {
                Text(field.directionTitles.ascending).tag(false)
                Text(field.directionTitles.descending).tag(true)
            }
            .pickerStyle(.inline)
        }
    }
}
#endif

/// A browse-row menu chip: icon, current value and a chevron.
struct BrowseChipMenuLabel: View {
    let value: String
    let systemImage: String
    let isActive: Bool
    let accessibilityTitle: String
    var cornerRadius: CGFloat = 18

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(DuskFont.glyphMedium(ios: .headline))
                .browseChipForeground(isActive ? Color.duskTextPrimary : Color.duskTextSecondary, tv: isActive ? .primary : .secondary)

            Text(value)
                .font(DuskFont.buttonLabel(ios: .subheadline.weight(.medium)))
                .browseChipForeground(Color.duskTextPrimary)
                .lineLimit(1)

            Image(systemName: "chevron.down")
                .font(DuskFont.glyphSmall(ios: .caption.weight(.semibold)))
                .browseChipForeground(Color.duskTextSecondary, tv: .secondary)
        }
        .browseChipPill(
            cornerRadius: cornerRadius,
            stroke: isActive ? Color.duskTextPrimary.opacity(0.35) : Color.duskTextSecondary.opacity(0.18)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(value)
    }
}

/// The browse row's chips. iOS and the Mac draw a custom pill; tvOS uses
/// system glass capsules, like the hub's Browse chips, so the label carries
/// no chrome or fixed colours there (a fixed label colour went white on the
/// focused white glass).
extension View {
    func browseChipForeground(_ color: Color, tv: HierarchicalShapeStyle = .primary) -> some View {
        #if os(tvOS)
        foregroundStyle(tv)
        #else
        foregroundStyle(color)
        #endif
    }

    @ViewBuilder
    func browseChipPill(
        cornerRadius: CGFloat,
        fill: Color = Color.duskSurface,
        stroke: Color = Color.duskTextSecondary.opacity(0.18)
    ) -> some View {
        #if os(tvOS)
        self
        #else
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(shape.fill(fill))
            .overlay { shape.stroke(stroke, lineWidth: 1) }
        #endif
    }

    /// tvOS: focus is the system's solid white glass, so an active chip
    /// can't use a solid fill too. It sits on a lighter, `TextPrimary`-tinted
    /// glass platter instead, like the tab bar's selected tab.
    @ViewBuilder
    func browseChipButtonStyle(isOn: Bool) -> some View {
        #if os(tvOS)
        self
            .menuStyle(.button)
            .buttonStyle(.glass(isOn ? .regular.tint(Color.duskTextPrimary.opacity(0.3)) : .regular))
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            // nil, never a colour: an explicit tint recolours the label too.
            .tint(nil)
        #else
        self
        #endif
    }
}
