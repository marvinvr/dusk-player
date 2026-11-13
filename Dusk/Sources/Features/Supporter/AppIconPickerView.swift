import SwiftUI

#if os(iOS)
/// Grid picker for the alternate app icons, opened from Settings → Appearance.
/// Two groups: the classic alternates (an active subscription, or a tip from Generous up), and the
/// subscriber exclusives. Locked tiles open the supporter sheet instead of applying.
struct AppIconPickerView: View {
    @Environment(SupporterStore.self) private var store
    @Environment(AnalyticsClient.self) private var analytics: AnalyticsClient?
    @Environment(\.dismiss) private var dismiss
    @State private var currentIcon: DuskAppIcon = .dusk
    @State private var showsSupporterSheet = false

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 18)]

    private var supporterIconsFootnote: String {
        if store.hasIconTip {
            return "Thanks for supporting Dusk — these came with your tip and are yours to keep."
        }
        if store.hasActiveSubscription {
            return "Included with your subscription. If it ends, Dusk switches back to the default icon."
        }
        return "Alternate icons come with an active subscription or a tip from Generous up. Everything else in Dusk stays free."
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.duskBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        iconGroup(
                            title: "Supporter Icons",
                            icons: DuskAppIcon.supporterIcons,
                            footnote: supporterIconsFootnote
                        )

                        iconGroup(
                            title: "Subscriber Exclusives",
                            icons: DuskAppIcon.subscriptionIcons,
                            footnote: store.hasActiveSubscription
                                ? "Included with your subscription. If it ends, Dusk switches back to the default icon."
                                : "Velvet, Emerald, Gilded and Sapphire unlock while a Dusk Supporter subscription is active. Tips don't include them."
                        )
                    }
                    .padding(20)
                }
            }
            .navigationTitle("App Icon")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                analytics?.record(AnalyticsEvent(.supporterIconPickerOpened))
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.duskAccent)
                }
            }
        }
        .onAppear { currentIcon = DuskAppIcon.current }
        .onChange(of: store.hasActiveSubscription) { _, _ in currentIcon = DuskAppIcon.current }
        .sheet(isPresented: $showsSupporterSheet) {
            SupporterView(context: .settings)
        }
    }

    private func iconGroup(title: String, icons: [DuskAppIcon], footnote: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(Color.duskTextSecondary)

            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(icons) { icon in
                    tile(for: icon)
                }
            }

            Text(footnote)
                .font(.caption)
                .foregroundStyle(Color.duskTextSecondary)
        }
    }

    private func tile(for icon: DuskAppIcon) -> some View {
        let isSelected = currentIcon == icon
        let isLocked = !store.isUnlocked(icon)
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

        return Button {
            if isLocked {
                showsSupporterSheet = true
            } else {
                apply(icon)
            }
        } label: {
            VStack(spacing: 8) {
                Image(icon.previewImageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .clipShape(shape)
                    .overlay {
                        shape.strokeBorder(
                            isSelected ? Color.duskAccent : Color.primary.opacity(0.08),
                            lineWidth: isSelected ? 2 : 1
                        )
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if isLocked {
                            Image(systemName: "lock.fill")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.duskTextPrimary)
                                .padding(7)
                                .background(.ultraThinMaterial, in: Circle())
                                .padding(4)
                        } else if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.duskAccent)
                                .background(Color.duskBackground, in: Circle())
                                .padding(4)
                        }
                    }

                Text(icon.displayName)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.duskTextPrimary : Color.duskTextSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func apply(_ icon: DuskAppIcon) {
        analytics?.record(AnalyticsEvent(.supporterIconApplied, [
            "icon": .string(icon.rawValue)
        ]))
        Task {
            try? await DuskAppIcon.select(icon)
            currentIcon = DuskAppIcon.current
        }
    }
}
#endif
