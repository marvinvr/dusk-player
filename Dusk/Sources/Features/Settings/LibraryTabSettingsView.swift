import SwiftUI

struct LibraryTabSettingsView: View {
    @Environment(UserPreferences.self) private var preferences

    var body: some View {
        Group {
            #if os(tvOS)
            tvContent
            #else
            iosContent
            #endif
        }
        .background(Color.duskBackground.ignoresSafeArea())
        .duskNavigationTitle("Navigation Tabs")
    }

    #if !os(tvOS)
    private var iosContent: some View {
        List {
            Section {
                ForEach(preferences.libraryTabOrder, id: \.self) { libraryType in
                    Toggle(
                        isOn: visibilityBinding(for: libraryType)
                    ) {
                        Label(libraryType.tabTitle, systemImage: libraryType.systemImage)
                            .foregroundStyle(Color.duskTextPrimary)
                    }
                    .tint(Color.duskAccent)
                }
                .onMove(perform: preferences.moveLibraryTabs)
            } header: {
                Text("Navigation Tabs")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text("Turn off a destination to remove it from the navigation bar. Tap Edit, then drag to change the order.")
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)
        }
        .contentMargins(.top, 12, for: .scrollContent)
        .duskScrollContentBackgroundHidden()
        .toolbar {
            EditButton()
        }
    }
    #endif

    #if os(tvOS)
    private var tvContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                TVSettingsSection(
                    title: "Visibility",
                    footer: "Turn off a destination to remove it from the navigation bar."
                ) {
                    ForEach(Array(preferences.libraryTabOrder.enumerated()), id: \.element) { index, libraryType in
                        if index > 0 {
                            tvRowDivider
                        }

                        TVSettingsToggleRow(
                            title: libraryType.tabTitle,
                            isOn: visibilityBinding(for: libraryType)
                        )
                    }
                }

                TVSettingsSection(
                    title: "Order",
                    footer: "Choose the position of each destination in the navigation bar."
                ) {
                    ForEach(Array(preferences.libraryTabOrder.enumerated()), id: \.element) { index, libraryType in
                        if index > 0 {
                            tvRowDivider
                        }

                        TVSettingsMenuRow(
                            title: libraryType.tabTitle,
                            options: Array(preferences.libraryTabOrder.indices),
                            selection: positionBinding(for: libraryType),
                            selectedTitle: positionName(for: index)
                        ) {
                            positionName(for: $0)
                        }
                    }
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.top, 48)
            .padding(.bottom, 88)
        }
    }

    private var tvRowDivider: some View {
        Rectangle()
            .fill(Color.duskTextSecondary.opacity(0.16))
            .frame(height: 1)
    }

    private func positionBinding(for libraryType: PlexLibraryType) -> Binding<Int> {
        Binding(
            get: { preferences.libraryTabOrder.firstIndex(of: libraryType) ?? 0 },
            set: { preferences.moveLibraryTab(libraryType, to: $0) }
        )
    }

    private func positionName(for index: Int) -> String {
        switch index {
        case 0:
            "First"
        case 1:
            "Second"
        default:
            index == 2 ? "Third" : "Fourth"
        }
    }
    #endif

    private func visibilityBinding(for libraryType: PlexLibraryType) -> Binding<Bool> {
        Binding(
            get: { preferences.isLibraryTabVisible(libraryType) },
            set: { preferences.setLibraryTabVisible($0, for: libraryType) }
        )
    }
}
