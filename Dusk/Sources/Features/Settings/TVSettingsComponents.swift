import SwiftUI

/// Shared spacing tokens for the tvOS settings page. Centralized so the page
/// title, section headers, card content, and footers all share one text-column
/// inset and the vertical rhythm between groups stays consistent.
enum TVSettingsMetrics {
    /// Horizontal inset shared by section headers, card content, and footers so
    /// every text column aligns while the card background bleeds slightly wider
    /// on each side (the standard grouped-list look).
    static let contentInset: CGFloat = 30
    /// How far the focus band bleeds outward from the row's content box toward
    /// the card edge. Rows lay out inside `contentInset`, so the band lands
    /// `contentInset - rowBandOutset` (≈8pt) from the card edge: it covers the
    /// whole field while the text/control still sit inset within the band.
    static let rowBandOutset: CGFloat = 22
    /// Top/bottom padding inside each card. Kept small and tuned so the first and
    /// last row's focus band sits the same ~8pt from the card edge as the band's
    /// sides (`contentInset - rowBandOutset`), instead of leaving a larger gap at
    /// the ends than between rows. The band's rounded corners still nest inside
    /// the card's corner radius at this inset.
    static let cardVerticalPadding: CGFloat = 4
    /// Gap between sections — and between the page title and the first section.
    /// Kept clearly larger than the intra-section gaps so groups read as groups.
    static let sectionSpacing: CGFloat = 48
}

struct TVSettingsSection<Content: View>: View {
    let title: String
    let footer: String?
    let footerColor: Color
    private let content: Content

    init(
        title: String,
        footer: String? = nil,
        footerColor: Color = Color.duskTextSecondary,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.footerColor = footerColor
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Color.duskTextSecondary)
                .padding(.leading, TVSettingsMetrics.contentInset)
                .padding(.bottom, 12)

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, TVSettingsMetrics.contentInset)
            .padding(.vertical, TVSettingsMetrics.cardVerticalPadding)
            .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(footerColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 14)
                    .padding(.horizontal, TVSettingsMetrics.contentInset)
            }
        }
    }
}

struct TVSettingsMenuRow<Option: Hashable>: View {
    let title: String
    let options: [Option]
    let selectedTitle: String
    let optionTitle: (Option) -> String
    @Binding var selection: Option
    @FocusState private var isFocused: Bool

    init(
        title: String,
        options: [Option],
        selection: Binding<Option>,
        selectedTitle: String,
        optionTitle: @escaping (Option) -> String
    ) {
        self.title = title
        self.options = options
        self._selection = selection
        self.selectedTitle = selectedTitle
        self.optionTitle = optionTitle
    }

    var body: some View {
        Picker(selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(optionTitle(option)).tag(option)
            }
        } label: {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.duskTextPrimary)
                .lineLimit(1)
        }
        .pickerStyle(.navigationLink)
        .focused($isFocused)
        .accessibilityLabel(title)
        .accessibilityValue(selectedTitle)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .tvSettingsRowFocusHighlight(isFocused)
    }
}

struct TVSettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 20) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.duskTextPrimary)

            Spacer(minLength: 24)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle())
                .tint(Color.duskAccent)
                .focused($isFocused)
        }
        .frame(minHeight: 72)
        .tvSettingsRowFocusHighlight(isFocused)
    }
}

struct TVSettingsActionRow: View {
    let title: String
    let tint: Color
    let role: ButtonRole?
    let showsChevron: Bool
    let isLoading: Bool
    let detail: String?
    let action: () -> Void
    @FocusState private var isFocused: Bool

    init(
        title: String,
        tint: Color,
        role: ButtonRole? = nil,
        showsChevron: Bool = false,
        isLoading: Bool = false,
        detail: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.tint = tint
        self.role = role
        self.showsChevron = showsChevron
        self.isLoading = isLoading
        self.detail = detail
        self.action = action
    }

    var body: some View {
        Group {
            if let role {
                Button(role: role, action: action, label: label)
            } else {
                Button(action: action, label: label)
            }
        }
        .duskSuppressTVOSButtonChrome()
        .focused($isFocused)
        .tvSettingsRowFocusHighlight(isFocused)
    }

    @ViewBuilder
    private func label() -> some View {
        HStack(spacing: 20) {
            Text(title)
                .font(.headline)
                .foregroundStyle(tint)

            Spacer()

            if isLoading {
                ProgressView()
                    .tint(Color.duskAccent)
            } else if let detail {
                Text(detail)
                    .foregroundStyle(Color.duskTextSecondary)
            } else if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .foregroundStyle(Color.duskTextSecondary)
            }
        }
        .frame(minHeight: 72)
        .contentShape(Rectangle())
    }
}

struct TVSettingsExternalLinkRow: View {
    let title: String
    let subtitle: String
    let tint: Color

    init(
        title: String,
        subtitle: String,
        tint: Color = Color.duskTextSecondary
    ) {
        self.title = title
        self.subtitle = subtitle
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 18) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Color.duskTextPrimary)
                .lineLimit(1)

            Spacer(minLength: 24)

            Text(subtitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// Neutral focus band drawn behind a focused tvOS settings row.
    ///
    /// Rows live inside a shared section card, so the app's scale + white-glow
    /// focus effect (`duskTVOSFocusEffectShape`) can't be used here — scaling a
    /// single row would overflow the card and overlap its neighbors. This
    /// background highlight marks the focused row without disturbing the grouped
    /// layout. It must be driven by an explicit per-row `@FocusState` bool: the
    /// environment `isFocused` can't be read above a `.focused()` view, the same
    /// reason the poster cards thread an explicit binding.
    @ViewBuilder
    func tvSettingsRowFocusHighlight(_ isFocused: Bool) -> some View {
        #if os(tvOS)
        background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.duskTextPrimary.opacity(isFocused ? 0.20 : 0))
                .padding(.vertical, 4)
                .padding(.horizontal, -TVSettingsMetrics.rowBandOutset)
        }
        .animation(.easeOut(duration: 0.18), value: isFocused)
        #else
        self
        #endif
    }
}
