import SwiftUI

// MARK: - Expandable Summary

/// A synopsis clamped to a few lines that offers the rest only when it is
/// actually cut off.
///
/// - tvOS: the clamped text itself is the control, like the TV app's
///   description. It joins the focus chain only while truncated (a quiet
///   platter on focus, no tint), and Select opens `SummaryFullTextView` full
///   screen; Menu closes it and focus returns to the text.
/// - iOS: "Show More" / "Show Less", or a tap on the text, expands in place.
///   Where the layout can't grow (`allowsExpansion: false`, the iPad hero
///   column) a tap opens the full text in a sheet instead.
struct ExpandableSummaryText: View {
    /// Default collapsed height of a synopsis block. tvOS fits one extra line in
    /// the same space now that the prose is 27pt rather than 29pt.
    static var defaultCollapsedLineLimit: Int {
        #if os(tvOS)
        10
        #else
        9
        #endif
    }

    let text: String
    /// Heads the full-text view (episode / show / season title).
    var title: String?
    var collapsedLineLimit = ExpandableSummaryText.defaultCollapsedLineLimit
    var font = DuskFont.body(ios: .body)
    var lineSpacing: CGFloat = 4
    var foregroundStyle = Color.primary.opacity(0.76)
    var allowsExpansion = true

    @State private var isTruncated = false
    @State private var isExpanded = false
    @State private var showsFullText = false

    var body: some View {
        #if os(tvOS)
        Button {
            showsFullText = true
        } label: {
            SummaryTextLabel(
                text: text,
                font: font,
                lineSpacing: lineSpacing,
                lineLimit: collapsedLineLimit,
                foregroundStyle: foregroundStyle,
                isTruncated: $isTruncated
            )
        }
        .buttonStyle(SummaryTextPlatterButtonStyle())
        // A disabled button never takes focus, so text that fits stays out of
        // the way of Up/Down between the rows around it.
        .disabled(!isTruncated)
        .accessibilityHint(isTruncated ? "Shows the full text" : "")
        .fullScreenCover(isPresented: $showsFullText) {
            SummaryFullTextView(title: title, text: text)
        }
        #else
        #if os(macOS)
        if !allowsExpansion {
            macClampedBody
        } else {
            expandingBody
        }
        #else
        expandingBody
        #endif
        #endif
    }

    #if os(macOS)
    /// The Mac hero's clamped synopsis: a small secondary "more" sits on the
    /// last line's baseline at the trailing edge, like the TV app; it (or a
    /// click on the text) opens the full text in a popover.
    private var macClampedBody: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Text(text)
                .font(font)
                .foregroundStyle(foregroundStyle)
                .lineSpacing(lineSpacing)
                .lineLimit(collapsedLineLimit)
                .truncationMode(.tail)
                .summaryTruncation(
                    text: text,
                    font: font,
                    lineSpacing: lineSpacing,
                    lineLimit: collapsedLineLimit,
                    isTruncated: $isTruncated
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    guard isTruncated else { return }
                    showsFullText = true
                }
                .accessibilityAddTraits(isTruncated ? .isButton : [])

            if isTruncated {
                Button("more") {
                    showsFullText = true
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .fixedSize()
                .help("Show the full description")
            }
        }
        .popover(isPresented: $showsFullText, arrowEdge: .bottom) {
            ScrollView {
                Text(text)
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 420, alignment: .leading)
                    .padding(16)
            }
            .frame(maxHeight: 420)
        }
    }
    #endif

    #if !os(tvOS)
    private var expandingBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(font)
                .foregroundStyle(foregroundStyle)
                .lineSpacing(lineSpacing)
                .lineLimit(isExpanded ? nil : collapsedLineLimit)
                .truncationMode(.tail)
                .summaryTruncation(
                    text: text,
                    font: font,
                    lineSpacing: lineSpacing,
                    lineLimit: collapsedLineLimit,
                    isTruncated: $isTruncated
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    guard isTruncated else { return }
                    if allowsExpansion {
                        isExpanded.toggle()
                    } else {
                        showsFullText = true
                    }
                }
                .accessibilityAddTraits(isTruncated ? .isButton : [])

            if allowsExpansion, isTruncated {
                Button(isExpanded ? "Show Less" : "Show More") {
                    isExpanded.toggle()
                }
                .font(DuskFont.buttonLabel(ios: .subheadline.weight(.semibold)))
                .foregroundStyle(Color.primary)
                .buttonStyle(.plain)
            }
        }
        #if !os(macOS)
        .sheet(isPresented: $showsFullText) {
            SummaryFullTextView(title: title, text: text)
        }
        #endif
    }
    #endif
}

// MARK: - Truncation

extension View {
    /// Reports whether `text` set in this font is cut off at `lineLimit` at the
    /// width this view gets. The font and spacing must match the visible text.
    fileprivate func summaryTruncation(
        text: String,
        font: Font,
        lineSpacing: CGFloat,
        lineLimit: Int,
        isTruncated: Binding<Bool>
    ) -> some View {
        modifier(SummaryTruncationReader(
            text: text,
            font: font,
            lineSpacing: lineSpacing,
            lineLimit: lineLimit,
            isTruncated: isTruncated
        ))
    }
}

/// Lays out the text twice, hidden, at the clamp and unclamped, and compares
/// the heights.
private struct SummaryTruncationReader: ViewModifier {
    let text: String
    let font: Font
    let lineSpacing: CGFloat
    let lineLimit: Int
    @Binding var isTruncated: Bool

    @State private var collapsedHeight: CGFloat = 0
    @State private var expandedHeight: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                ZStack {
                    measurementText(lineLimit: lineLimit) { collapsedHeight = $0 }
                    measurementText(lineLimit: nil) { expandedHeight = $0 }
                }
                .hidden()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onChange(of: expandedHeight > collapsedHeight + 1, initial: true) { _, truncated in
                isTruncated = truncated
            }
    }

    private func measurementText(
        lineLimit: Int?,
        onHeightChange: @escaping (CGFloat) -> Void
    ) -> some View {
        Text(text)
            .font(font)
            .lineSpacing(lineSpacing)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                onHeightChange(height)
            }
    }
}

// MARK: - tvOS Focus

#if os(tvOS)
private struct SummaryTextLabel: View {
    @Environment(\.isFocused) private var isFocused

    let text: String
    let font: Font
    let lineSpacing: CGFloat
    let lineLimit: Int
    let foregroundStyle: Color
    @Binding var isTruncated: Bool

    var body: some View {
        Text(text)
            .font(font)
            // Focused prose reads at full strength, like the TV app.
            .foregroundStyle(isFocused ? Color.primary : foregroundStyle)
            .lineSpacing(lineSpacing)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .summaryTruncation(
                text: text,
                font: font,
                lineSpacing: lineSpacing,
                lineLimit: lineLimit,
                isTruncated: $isTruncated
            )
    }
}

/// The TV app's description focus: a soft neutral platter just outside the
/// text and a slight lift. The platter overhangs instead of padding the
/// text, so the text stays aligned with everything around it.
private struct SummaryTextPlatterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Platter(configuration: configuration)
    }

    private struct Platter: View {
        @Environment(\.isFocused) private var isFocused

        let configuration: Configuration

        private let outset = EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20)

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.primary.opacity(isFocused ? 0.12 : 0))
                        .padding(EdgeInsets(
                            top: -outset.top,
                            leading: -outset.leading,
                            bottom: -outset.bottom,
                            trailing: -outset.trailing
                        ))
                }
                .scaleEffect(configuration.isPressed ? 0.99 : (isFocused ? 1.02 : 1))
                // Callers may disable animations around the text (the series
                // banner does, so zapping episodes doesn't cross-fade); the
                // focus change still eases.
                .transaction(value: isFocused) { transaction in
                    transaction.disablesAnimations = false
                    transaction.animation = .easeOut(duration: 0.18)
                }
        }
    }
}
#endif

// MARK: - Full Text

/// The whole synopsis on its own. tvOS: a full-screen cover over the blurred
/// page, Menu closes it. iOS: a sheet with a close button.
struct SummaryFullTextView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String?
    let text: String

    private var paragraphs: [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        #if os(tvOS)
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    if let title, !title.isEmpty {
                        Text(title)
                            .font(DuskFont.TV.pageTitle)
                            .foregroundStyle(Color.duskTextPrimary)
                            .lineLimit(2)
                    }

                    VStack(alignment: .leading, spacing: 24) {
                        // Each paragraph takes focus (invisibly) so a synopsis
                        // taller than the screen scrolls with the remote.
                        ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph)
                                .font(DuskFont.TV.pageSubtitle)
                                .foregroundStyle(Color.primary.opacity(0.86))
                                .lineSpacing(6)
                                .fixedSize(horizontal: false, vertical: true)
                                .focusable()
                                .focusEffectDisabled()
                        }
                    }
                }
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
                .padding(.vertical, 60)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
        .duskTVOSPopUpBackground()
        #else
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.body)
                    .foregroundStyle(Color.primary.opacity(0.86))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .navigationTitle(title ?? "Synopsis")
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #else
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    closeButton
                }
            }
            #endif
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #if os(macOS)
        .macUISheetSize(minHeight: 320, idealHeight: 480)
        #endif
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var closeButton: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close) {
                dismiss()
            }
        } else {
            Button("Done") {
                dismiss()
            }
        }
    }
    #endif
}
