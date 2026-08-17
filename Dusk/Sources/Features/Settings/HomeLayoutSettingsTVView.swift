#if os(tvOS)
import SwiftUI

/// tvOS editor for the Home row order and visibility.
///
/// The Siri Remote has no drag, so ordering works as a pick-up: select a row's
/// move button to lift the row, swipe up or down to walk it through the list,
/// then select again (or press Menu) to drop it.
///
/// The move is driven by focus rather than by `onMoveCommand`: while a row is
/// lifted, every row's move button stays focusable, so a swipe reliably moves
/// focus onto the neighboring row, and that focus change is what carries the
/// lifted row into the neighbor's slot before focus is handed back. Directional
/// commands only reach `onMoveCommand` when the focus engine finds no candidate
/// at all, and up here it always would — the tab bar sits above this screen —
/// so a command-driven version would move the row down but not up.
struct HomeLayoutSettingsTVView: View {
    let viewModel: HomeLayoutSettingsViewModel

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedControl: HomeLayoutTVControl?
    @State private var liftedRowID: String?
    @State private var confirmsReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TVSettingsMetrics.sectionSpacing) {
                featuredSection
                rowsSection

                if viewModel.hasSavedLayout {
                    resetSection
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 60)
            .padding(.top, 48)
            .padding(.bottom, 88)
        }
        .onChange(of: focusedControl) { _, newControl in
            carryLiftedRow(to: newControl)
        }
        // Menu drops the lifted row instead of leaving the screen mid-move. With
        // nothing lifted it has to reproduce the default pop itself.
        .onExitCommand {
            if liftedRowID != nil {
                drop()
            } else {
                dismiss()
            }
        }
        .animation(.easeOut(duration: 0.18), value: liftedRowID)
        .alert("Reset the Home layout?", isPresented: $confirmsReset) {
            Button("Reset Layout", role: .destructive) {
                Task { await viewModel.resetLayout() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(HomeLayoutSettingsCopy.resetFooter)
        }
    }

    // MARK: - Sections

    private var featuredSection: some View {
        TVSettingsSection(title: "Featured", footer: HomeLayoutSettingsCopy.featuredFooter) {
            TVSettingsToggleRow(title: "Continue Watching", isOn: featuredBinding)
        }
        .disabled(isLifting)
        .opacity(isLifting ? Self.inertOpacity : 1)
    }

    private var rowsSection: some View {
        TVSettingsSection(title: "Rows", footer: rowsFooterText, footerColor: rowsFooterColor) {
            if viewModel.rows.isEmpty {
                Text("This server has no Home rows to arrange yet.")
                    .font(.headline)
                    .foregroundStyle(Color.duskTextSecondary)
                    .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
            } else {
                ForEach(Array(viewModel.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        rowDivider
                    }

                    HomeLayoutTVRow(
                        row: row,
                        position: index + 1,
                        isLifted: liftedRowID == row.id,
                        isToggleLocked: isLifting,
                        focusedControl: $focusedControl,
                        isVisible: Binding(
                            get: { row.isVisible },
                            set: { viewModel.setVisible($0, rowID: row.id) }
                        ),
                        onMoveButton: { toggleLift(row.id) }
                    )
                }
            }
        }
    }

    private var resetSection: some View {
        TVSettingsSection(title: "Saved Layout", footer: HomeLayoutSettingsCopy.resetFooter) {
            TVSettingsActionRow(title: "Reset Layout", tint: .red, role: .destructive) {
                confirmsReset = true
            }
        }
        .disabled(isLifting)
        .opacity(isLifting ? Self.inertOpacity : 1)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.duskTextSecondary.opacity(0.16))
            .frame(height: 1)
    }

    // MARK: - Lifting and moving

    private func toggleLift(_ rowID: String) {
        if liftedRowID == rowID {
            drop()
        } else {
            liftedRowID = rowID
            focusedControl = .move(rowID)
        }
    }

    /// A tvOS move is a run of single steps, so the Plex write happens once here
    /// instead of once per swipe. `pushOrderToPlex` skips sections whose
    /// server-side order already matches, so dropping a row back where it started
    /// costs nothing.
    private func drop() {
        liftedRowID = nil
        viewModel.pushOrderToPlex()
    }

    /// Moves the lifted row into the slot focus just travelled to, then takes
    /// focus back so the next swipe moves the row again. Focus leaving the row
    /// list entirely (the sections above and below, or the tab bar) means the row
    /// hit an end of the list: it stays put and keeps focus until it is dropped.
    private func carryLiftedRow(to newControl: HomeLayoutTVControl?) {
        guard let liftedRowID, newControl?.rowID != liftedRowID else { return }

        if let targetRowID = newControl?.rowID,
           let destination = viewModel.rows.firstIndex(where: { $0.id == targetRowID }) {
            _ = withAnimation(.easeOut(duration: 0.2)) {
                viewModel.moveRow(id: liftedRowID, toIndex: destination)
            }
        }

        focusedControl = .move(liftedRowID)
        restoreLiftedFocus(liftedRowID)
    }

    /// Second attempt at the hand-back, after the reordered list has been laid
    /// out. Focus follows the row's identity, so this is normally a no-op.
    ///
    /// A `nil` here means the focus request was refused and focus really did leave
    /// the screen (the tab bar above it, most likely). The lift is committed in
    /// that case rather than left holding a row the user can no longer see.
    private func restoreLiftedFocus(_ rowID: String) {
        Task { @MainActor in
            await Task.yield()

            guard liftedRowID == rowID else { return }

            if focusedControl == nil {
                drop()
            } else if focusedControl?.rowID != rowID {
                focusedControl = .move(rowID)
            }
        }
    }

    // MARK: - State

    /// How far the parts of the screen that a lift disables fade back.
    private static let inertOpacity = 0.35

    private var isLifting: Bool {
        liftedRowID != nil
    }

    private var featuredBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isFeaturedVisible },
            set: { viewModel.setFeaturedVisible($0) }
        )
    }

    private var rowsFooterText: String {
        if let liftedTitle = viewModel.rows.first(where: { $0.id == liftedRowID })?.title {
            return "Moving “\(liftedTitle)”. Swipe up or down to change its position, then press select to drop it."
        }

        if viewModel.isSyncing {
            return HomeLayoutSettingsCopy.syncingFooter
        }

        if let syncWarning = viewModel.syncWarning {
            return syncWarning
        }

        let editingHint = "Select a row's move button to pick it up, then swipe up or down. Turn a row off to hide it from Home."
        return "\(editingHint) \(HomeLayoutSettingsCopy.syncFooter(syncsToPlex: viewModel.syncsToPlex))"
    }

    private var rowsFooterColor: Color {
        isLifting || viewModel.syncWarning != nil ? Color.duskAccent : Color.duskTextSecondary
    }
}

/// The two focusable controls a Home layout row owns. Focus is parent-owned: the
/// editor has to know which row focus moved to in order to carry the lifted row
/// there, and it hands focus back afterwards.
enum HomeLayoutTVControl: Hashable {
    case move(String)
    case visibility(String)

    var rowID: String {
        switch self {
        case .move(let rowID), .visibility(let rowID):
            return rowID
        }
    }
}

private struct HomeLayoutTVRow: View {
    let row: HomeLayoutSettingsViewModel.Row
    let position: Int
    let isLifted: Bool
    /// Visibility is locked while any row is lifted, so a swipe can only land on
    /// move buttons and the lifted row is never left behind on a toggle.
    let isToggleLocked: Bool
    @FocusState.Binding var focusedControl: HomeLayoutTVControl?
    @Binding var isVisible: Bool
    let onMoveButton: () -> Void

    var body: some View {
        HStack(spacing: 20) {
            Text("\(position)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(isLifted ? Color.duskAccent : Color.duskTextSecondary)
                .lineLimit(1)
                .frame(width: 48, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.headline)
                    .foregroundStyle(row.isVisible ? Color.duskTextPrimary : Color.duskTextSecondary)
                    .lineLimit(1)

                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Color.duskTextSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 24)

            moveButton
            visibilityToggle
        }
        .frame(minHeight: 92)
        .background { band }
    }

    private var moveButton: some View {
        Button(action: onMoveButton) {
            Image(systemName: "arrow.up.arrow.down")
                .font(.headline.weight(.semibold))
                .foregroundStyle(isLifted ? Color.white : Color.duskTextPrimary)
                .frame(width: 80, height: 52)
                .background(moveButtonFill, in: Capsule())
                .contentShape(Capsule())
        }
        .duskSuppressTVOSButtonChrome()
        .focused($focusedControl, equals: .move(row.id))
        .accessibilityLabel(isLifted ? "Drop \(row.title)" : "Move \(row.title)")
        .accessibilityHint(
            isLifted
                ? "Swipe up or down to change the position, then select to drop the row."
                : "Select to pick the row up."
        )
    }

    private var visibilityToggle: some View {
        Toggle("", isOn: $isVisible)
            .labelsHidden()
            .toggleStyle(SwitchToggleStyle())
            .tint(Color.duskAccent)
            .focused($focusedControl, equals: .visibility(row.id))
            .disabled(isToggleLocked)
            .accessibilityLabel("Show \(row.title) on Home")
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.duskTextPrimary.opacity(isToggleFocused ? 0.24 : 0))
            )
    }

    /// Neutral band behind the row that holds focus, accent-tinted while the row
    /// is lifted. Rows sit inside a shared section card, so this cannot use the
    /// app's scaling focus effect — see the note on `TVSettingsMetrics`. The
    /// control fills above carry the finer "which control has focus" signal.
    private var band: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(bandColor)
            .padding(.vertical, 4)
            .padding(.horizontal, -TVSettingsMetrics.rowBandOutset)
            .animation(.easeOut(duration: 0.18), value: bandColor)
    }

    private var bandColor: Color {
        if isLifted {
            return Color.duskAccent.opacity(0.20)
        }
        if isMoveButtonFocused || isToggleFocused {
            return Color.duskTextPrimary.opacity(0.10)
        }
        return .clear
    }

    private var moveButtonFill: Color {
        if isLifted {
            return Color.duskAccent
        }
        return Color.duskTextPrimary.opacity(isMoveButtonFocused ? 0.30 : 0.12)
    }

    private var isMoveButtonFocused: Bool {
        focusedControl == .move(row.id)
    }

    private var isToggleFocused: Bool {
        focusedControl == .visibility(row.id)
    }
}
#endif
