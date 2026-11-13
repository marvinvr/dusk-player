import SwiftUI

/// The library grid's Filters sheet: watch state plus Plex's own section
/// filters (decade, resolution, HDR, audio language, people, …), combined.
/// Edits a draft and applies it once, on Done, so picking three filters
/// costs one reload, not three.
struct LibraryFiltersSheet: View {
    let viewModel: LibraryItemsViewModel
    let dismiss: () -> Void

    @State private var draft: LibraryFilterState

    init(viewModel: LibraryItemsViewModel, dismiss: @escaping () -> Void) {
        self.viewModel = viewModel
        self.dismiss = dismiss
        _draft = State(initialValue: viewModel.filterState)
    }

    private var valueFields: [LibraryFilterField] {
        viewModel.availableFilterFields.filter { $0.kind != .toggle }
    }

    private var toggleFields: [LibraryFilterField] {
        viewModel.availableFilterFields.filter { $0.kind == .toggle }
    }

    var body: some View {
        NavigationStack {
            content
            .navigationTitle("Filters")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { draft = LibraryFilterState() }
                        .disabled(draft.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { apply() }
                }
            }
        }
        #if os(macOS)
        .macUISheetSize(idealHeight: 620)
        #endif
    }

    #if os(tvOS)
    /// tvOS uses the Settings rows: a plain `List` here shows no focus.
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                TVSettingsSection(title: "Status") {
                    ForEach(viewModel.watchStatusOptions) { status in
                        TVSettingsActionRow(
                            title: status.title,
                            detail: draft.watchStatus == status ? "✓" : nil
                        ) {
                            draft.watchStatus = status
                        }
                    }
                }

                if !valueFields.isEmpty {
                    TVSettingsSection(title: "Filter By") {
                        ForEach(valueFields) { field in
                            TVSettingsNavigationRow(
                                title: field.title,
                                detail: draft.choices[field.parameter]?.title ?? "Any"
                            ) {
                                LibraryFilterValuesView(field: field, viewModel: viewModel, draft: $draft)
                            }
                        }
                    }
                }

                if !toggleFields.isEmpty {
                    TVSettingsSection(title: "Video") {
                        ForEach(toggleFields) { field in
                            TVSettingsToggleRow(title: field.title, isOn: toggleBinding(field.parameter))
                        }
                    }
                }
            }
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }
    #else
    private var content: some View {
            List {
                Section("Status") {
                    ForEach(viewModel.watchStatusOptions) { status in
                        LibraryFilterCheckRow(title: status.title, isSelected: draft.watchStatus == status) {
                            draft.watchStatus = status
                        }
                    }
                }

                if !valueFields.isEmpty {
                    Section("Filter By") {
                        ForEach(valueFields) { field in
                            NavigationLink {
                                LibraryFilterValuesView(field: field, viewModel: viewModel, draft: $draft)
                            } label: {
                                LabeledContent(field.title, value: draft.choices[field.parameter]?.title ?? "Any")
                                    .duskFont(tvOnly: DuskFont.TV.rowTitle)
                            }
                        }
                    }
                }

                if !toggleFields.isEmpty {
                    Section("Video") {
                        ForEach(toggleFields) { field in
                            Toggle(field.title, isOn: toggleBinding(field.parameter))
                                .duskFont(tvOnly: DuskFont.TV.rowTitle)
                        }
                    }
                }
            }
    }
    #endif

    private func toggleBinding(_ parameter: String) -> Binding<Bool> {
        Binding {
            draft.toggles.contains(parameter)
        } set: { isOn in
            if isOn { draft.toggles.insert(parameter) } else { draft.toggles.remove(parameter) }
        }
    }

    private func apply() {
        let state = draft
        Task { await viewModel.applyFilters(state) }
        dismiss()
    }
}

/// A selectable row with a trailing checkmark, the system list idiom (and
/// what tvOS 27's broken `Picker(.navigationLink)` would have drawn).
private struct LibraryFilterCheckRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .duskFont(tvOnly: DuskFont.TV.rowTitle)
                    .foregroundStyle(Color.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(DuskFont.glyphSmall(ios: .body.weight(.semibold)))
                        .foregroundStyle(Color.primary)
                }
            }
            .contentShape(Rectangle())
        }
        #if os(macOS)
        // A row, as on iOS, not a push button.
        .buttonStyle(.plain)
        #endif
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The values of one filter field ("Any" first), searchable when long
/// (actors and studios run into the thousands).
private struct LibraryFilterValuesView: View {
    let field: LibraryFilterField
    let viewModel: LibraryItemsViewModel
    @Binding var draft: LibraryFilterState

    @Environment(\.dismiss) private var dismiss
    @State private var values: [LibraryFilterChoice]?
    @State private var query = ""

    var body: some View {
        Group {
            if let values {
                #if os(tvOS)
                ScrollView {
                    TVSettingsSection(title: field.title) {
                        TVSettingsActionRow(title: "Any", detail: draft.choices[field.parameter] == nil ? "✓" : nil) {
                            draft.choices[field.parameter] = nil
                            dismiss()
                        }
                        ForEach(filtered(values)) { choice in
                            TVSettingsActionRow(
                                title: choice.title,
                                detail: draft.choices[field.parameter] == choice ? "✓" : nil
                            ) {
                                draft.choices[field.parameter] = choice
                                dismiss()
                            }
                        }
                    }
                    .frame(maxWidth: 1100)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
                .modifier(SearchableIfLong(isLong: values.count > 20, query: $query))
                #else
                List {
                    if query.isEmpty {
                        LibraryFilterCheckRow(title: "Any", isSelected: draft.choices[field.parameter] == nil) {
                            draft.choices[field.parameter] = nil
                            dismiss()
                        }
                    }
                    ForEach(filtered(values)) { choice in
                        LibraryFilterCheckRow(
                            title: choice.title,
                            isSelected: draft.choices[field.parameter] == choice
                        ) {
                            draft.choices[field.parameter] = choice
                            dismiss()
                        }
                    }
                }
                .modifier(SearchableIfLong(isLong: values.count > 20, query: $query))
                #endif
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(field.title)
        .task {
            values = await viewModel.filterValues(for: field)
        }
    }

    private func filtered(_ values: [LibraryFilterChoice]) -> [LibraryFilterChoice] {
        guard !query.isEmpty else { return values }
        return values.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private struct SearchableIfLong: ViewModifier {
        let isLong: Bool
        @Binding var query: String

        func body(content: Content) -> some View {
            if isLong {
                content.searchable(text: $query)
            } else {
                content
            }
        }
    }
}
