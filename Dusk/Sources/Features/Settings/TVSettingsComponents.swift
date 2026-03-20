import SwiftUI

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
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.duskTextPrimary)

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(Color.duskSurface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))

            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.subheadline)
                    .foregroundStyle(footerColor)
                    .fixedSize(horizontal: false, vertical: true)
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
        .accessibilityLabel(title)
        .accessibilityValue(selectedTitle)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
    }
}

struct TVSettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool

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
        }
        .frame(minHeight: 72)
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
