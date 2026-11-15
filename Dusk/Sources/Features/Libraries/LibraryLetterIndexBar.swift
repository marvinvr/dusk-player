import SwiftUI

#if os(tvOS)
/// The tvOS A–Z strip at the grid's trailing edge. It stays focusable while
/// hidden, so a swipe right off the last column lands on it; it shows while
/// it holds focus or while `isRevealed` (the grid scrolling fast). Letters
/// with no titles are drawn dimmed and can't take focus.
struct LibraryLetterIndexBar: View {
    let index: LibraryLetterIndex
    /// The letter of the focused title; entering the strip starts there.
    let currentEntry: LibraryLetterIndex.Entry?
    let isRevealed: Bool
    let onSelect: (LibraryLetterIndex.Entry) -> Void

    @FocusState private var focusedLabel: String?

    private var isVisible: Bool { isRevealed || focusedLabel != nil }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(index.entries) { entry in
                Button {
                    onSelect(entry)
                } label: {
                    LetterLabel(
                        entry: entry,
                        isCurrent: entry == currentEntry,
                        isVisible: isVisible
                    )
                }
                .buttonStyle(LetterButtonStyle())
                .disabled(!entry.isAvailable)
                .focused($focusedLabel, equals: entry.label)
                .accessibilityLabel(entry.label == "#" ? "Numbers and symbols" : entry.label)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(focusedLabel != nil ? 1 : 0)
        }
        // Hidden by clearing the letters, never with opacity: the focus
        // engine skips fully transparent views, and a swipe right off the
        // grid has to land here while it is hidden (a near-zero opacity left
        // faint ghost letters at the screen edge).
        .animation(.easeOut(duration: 0.2), value: isVisible)
        .focusSection()
        .onChange(of: focusedLabel) { previous, label in
            // Arriving from the grid lands on the letter being browsed rather
            // than whichever row of the strip happened to be nearest.
            guard previous == nil, label != nil,
                  let current = currentEntry, current.label != label else { return }
            focusedLabel = current.label
        }
    }

    private struct LetterLabel: View {
        @Environment(\.isFocused) private var isFocused
        let entry: LibraryLetterIndex.Entry
        let isCurrent: Bool
        let isVisible: Bool

        var body: some View {
            Text(entry.label)
                .font(.system(size: 21, weight: isFocused || isCurrent ? .bold : .semibold))
                .foregroundStyle(foreground)
                .frame(width: 36, height: 30)
                .background {
                    Circle()
                        .fill(Color.duskTextPrimary)
                        .frame(width: 34, height: 34)
                        .opacity(isFocused ? 1 : 0)
                }
        }

        private var foreground: Color {
            if isFocused { return Color.duskBackground }
            if !isVisible { return .clear }
            if !entry.isAvailable { return Color.duskTextSecondary.opacity(0.45) }
            return isCurrent ? Color.duskTextPrimary : Color.duskTextSecondary
        }
    }

    private struct LetterButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.9 : 1)
                .focusEffectDisabled()
        }
    }
}
#else
/// The iOS section index: a column of letters on the grid's trailing edge.
/// Touching or dragging along it jumps the grid, with a selection tick per
/// letter, like `UITableView`'s index.
struct LibraryLetterIndexBar: View {
    let index: LibraryLetterIndex
    let onSelect: (LibraryLetterIndex.Entry) -> Void

    @State private var scrubbedLabel: String?

    private let rowHeight: CGFloat = 15

    var body: some View {
        VStack(spacing: 0) {
            ForEach(index.entries) { entry in
                Text(entry.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(entry.isAvailable ? Color.duskTextPrimary : Color.duskTextSecondary.opacity(0.5))
                    .frame(width: 18, height: rowHeight)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let row = Int(((value.location.y - 4) / rowHeight).rounded(.down))
                    let entry = index.entries[min(max(row, 0), index.entries.count - 1)]
                    guard entry.label != scrubbedLabel else { return }
                    scrubbedLabel = entry.label
                    onSelect(entry)
                }
                .onEnded { _ in scrubbedLabel = nil }
        )
        .sensoryFeedback(.selection, trigger: scrubbedLabel) { _, new in new != nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Section index")
        .accessibilityValue(scrubbedLabel ?? "")
        .accessibilityAdjustableAction { direction in
            let available = index.entries.filter(\.isAvailable)
            let current = available.firstIndex { $0.label == scrubbedLabel } ?? -1
            let next = direction == .increment ? current + 1 : current - 1
            guard available.indices.contains(next) else { return }
            scrubbedLabel = available[next].label
            onSelect(available[next])
        }
    }
}
#endif
