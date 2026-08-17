import SwiftUI

#if os(iOS)
/// Grid picker for the alternate app icons, opened from Settings → Appearance.
/// Locked tiles route non-supporters to the supporter sheet instead of
/// applying the icon.
struct AppIconPickerView: View {
    @Environment(SupporterStore.self) private var store
    @Environment(AnalyticsClient.self) private var analytics: AnalyticsClient?
    @Environment(\.dismiss) private var dismiss
    @State private var currentIcon: DuskAppIcon = .dusk
    @State private var showsSupporterSheet = false

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 18)]

    var body: some View {
        NavigationStack {
            ZStack {
                Color.duskBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        LazyVGrid(columns: columns, spacing: 20) {
                            ForEach(DuskAppIcon.allCases) { icon in
                                tile(for: icon)
                            }
                        }

                        Text(store.isSupporter
                            ? "Thanks for supporting Dusk — enjoy the icons."
                            : "Alternate icons are a small thank-you for supporters. Everything else in Dusk stays free.")
                            .font(.caption)
                            .foregroundStyle(Color.duskTextSecondary)
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
        .sheet(isPresented: $showsSupporterSheet) {
            SupporterView(context: .settings)
        }
    }

    private func tile(for icon: DuskAppIcon) -> some View {
        let isSelected = currentIcon == icon
        let isLocked = icon.requiresSupporter && !store.isSupporter
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
