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
        .duskSettingsPageBackground()
        .duskNavigationTitle(Self.pageTitle)
    }

    /// The Mac calls the destinations sidebar items; iOS and tvOS tabs.
    private static var pageTitle: String {
        #if os(macOS)
        "Sidebar Items"
        #else
        "Navigation Tabs"
        #endif
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
                }
                .onMove(perform: preferences.moveLibraryTabs)
            } header: {
                Text(Self.pageTitle)
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                #if os(macOS)
                Text("Drag to reorder.")
                    .foregroundStyle(Color.duskTextSecondary)
                #else
                Text("Tap Edit, then drag to reorder.")
                    .foregroundStyle(Color.duskTextSecondary)
                #endif
            }
            .duskSettingsRowBackground()
        }
        .contentMargins(.top, 12, for: .scrollContent)
        .duskSettingsScrollBackgroundHidden()
        #if !os(macOS)
        // The Mac reorders by dragging a row, no edit mode.
        .toolbar {
            EditButton()
        }
        #endif
    }
    #endif

    #if os(tvOS)
    private var tvContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                TVSettingsPageTitle(Self.pageTitle)
                TVSettingsSection(title: "Visibility") {
                    ForEach(Array(preferences.libraryTabOrder.enumerated()), id: \.element) { index, libraryType in
                        if index > 0 {
                            tvRowDivider
                        }

                        // Open at the top. The switches are small targets,
                        // so the focus engine picked the first full-width
                        // Order row mid-page.
                        TVSettingsToggleRow(
                            title: libraryType.tabTitle,
                            isOn: visibilityBinding(for: libraryType),
                            takesInitialFocus: index == 0
                        )
                    }
                }

                TVSettingsSection(title: "Order") {
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

    private func positionBinding(for libraryType: LibraryKind) -> Binding<Int> {
        Binding(
            get: { preferences.libraryTabOrder.firstIndex(of: libraryType) ?? 0 },
            set: { preferences.moveLibraryTab(libraryType, to: $0) }
        )
    }

    /// "1st", "2nd", … like Server Priority; never capped (six tab types).
    private func positionName(for index: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: index + 1)) ?? "\(index + 1)"
    }
    #endif

    private func visibilityBinding(for libraryType: LibraryKind) -> Binding<Bool> {
        Binding(
            get: { preferences.isLibraryTabVisible(libraryType) },
            set: { preferences.setLibraryTabVisible($0, for: libraryType) }
        )
    }
}
