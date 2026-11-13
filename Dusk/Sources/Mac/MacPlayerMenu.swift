#if os(macOS)
import AppKit
import AVKit
import SwiftUI

// MARK: - Menu model

/// One row of a play-bar menu. The play bar's menus are real `NSMenu`s popped
/// up *above* their button, the way AVKit's are: a SwiftUI `Menu` always drops
/// down, which from a bar at the bottom of the window covers the timeline and
/// runs off the window.
struct MacPlayerMenuItem {
    enum Kind {
        case action(() -> Void)
        case submenu([MacPlayerMenuItem])
        case header
        case separator
    }

    var title: String
    var subtitle: String?
    var isOn = false
    var isEnabled = true
    /// Shown at the trailing edge; the same shortcut must work from the menu
    /// bar's Playback menu, which is where it really lives.
    var shortcut: (key: String, modifiers: NSEvent.ModifierFlags)?
    var kind: Kind

    static func action(
        _ title: String,
        subtitle: String? = nil,
        isOn: Bool = false,
        isEnabled: Bool = true,
        shortcut: (key: String, modifiers: NSEvent.ModifierFlags)? = nil,
        _ action: @escaping () -> Void
    ) -> MacPlayerMenuItem {
        MacPlayerMenuItem(
            title: title,
            subtitle: subtitle,
            isOn: isOn,
            isEnabled: isEnabled,
            shortcut: shortcut,
            kind: .action(action)
        )
    }

    static func submenu(
        _ title: String,
        subtitle: String? = nil,
        isEnabled: Bool = true,
        _ items: [MacPlayerMenuItem]
    ) -> MacPlayerMenuItem {
        MacPlayerMenuItem(title: title, subtitle: subtitle, isEnabled: isEnabled, kind: .submenu(items))
    }

    static func header(_ title: String) -> MacPlayerMenuItem {
        MacPlayerMenuItem(title: title, kind: .header)
    }

    static var separator: MacPlayerMenuItem {
        MacPlayerMenuItem(title: "", kind: .separator)
    }
}

private final class MacPlayerMenuActionTarget: NSObject {
    let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func perform(_ sender: Any?) {
        handler()
    }
}

enum MacPlayerMenuBuilder {
    static func makeMenu(_ items: [MacPlayerMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Over video, like AVKit's own menus.
        menu.appearance = NSAppearance(named: .darkAqua)

        for item in trimmedSeparators(items) {
            switch item.kind {
            case .separator:
                menu.addItem(.separator())
            case .header:
                menu.addItem(.sectionHeader(title: item.title))
            case .action(let handler):
                let target = MacPlayerMenuActionTarget(handler)
                let menuItem = NSMenuItem(
                    title: item.title,
                    action: #selector(MacPlayerMenuActionTarget.perform(_:)),
                    keyEquivalent: item.shortcut?.key ?? ""
                )
                if let shortcut = item.shortcut {
                    menuItem.keyEquivalentModifierMask = shortcut.modifiers
                }
                menuItem.target = target
                // `target` is weak; the represented object keeps it alive for
                // as long as the menu exists.
                menuItem.representedObject = target
                menuItem.state = item.isOn ? .on : .off
                menuItem.isEnabled = item.isEnabled
                menuItem.subtitle = item.subtitle
                menu.addItem(menuItem)
            case .submenu(let children):
                let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                menuItem.subtitle = item.subtitle
                menuItem.isEnabled = item.isEnabled && !children.isEmpty
                menuItem.submenu = makeMenu(children)
                menu.addItem(menuItem)
            }
        }
        return menu
    }

    /// Drops leading, trailing and doubled separators, so callers can add one
    /// between optional groups without bookkeeping.
    private static func trimmedSeparators(_ items: [MacPlayerMenuItem]) -> [MacPlayerMenuItem] {
        var result: [MacPlayerMenuItem] = []
        for item in items {
            if case .separator = item.kind {
                guard let last = result.last else { continue }
                if case .separator = last.kind { continue }
            }
            result.append(item)
        }
        while let last = result.last, case .separator = last.kind {
            result.removeLast()
        }
        return result
    }
}

// MARK: - Menu button

/// Holds the AppKit view behind a play-bar button, so the menu can be placed
/// relative to it.
final class MacPlayerMenuAnchor {
    weak var view: NSView?
}

private struct MacPlayerMenuAnchorView: NSViewRepresentable {
    let anchor: MacPlayerMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = MacPlayerPassthroughView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

private final class MacPlayerPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// An icon button in the play bar that opens an `NSMenu` above itself. Its
/// icon keeps a soft platter only while the menu is open.
struct MacPlayerMenuButton: View {
    let systemName: String
    let help: String
    let accessibilityLabel: String
    var accessibilityValue: String = ""
    let items: () -> [MacPlayerMenuItem]

    @Environment(\.isEnabled) private var isEnabled
    @State private var anchor = MacPlayerMenuAnchor()
    @State private var isOpen = false

    var body: some View {
        Button(action: open) {
            MacPlayerHUDIcon(systemName: systemName, isActive: isOpen)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .background(MacPlayerMenuAnchorView(anchor: anchor))
        .help(help)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.isButton)
    }

    private func open() {
        guard isEnabled, !isOpen, let view = anchor.view else { return }
        let menu = MacPlayerMenuBuilder.makeMenu(items())
        guard !menu.items.isEmpty else { return }
        isOpen = true
        // After the click finishes: `popUp` runs the menu's tracking loop.
        DispatchQueue.main.async {
            let size = menu.size
            let gap: CGFloat = 10
            let bounds = view.bounds
            // Bottom edge `gap` above the button, centred on it. AppKit keeps
            // it on screen if there is no room.
            let topLeft = NSPoint(
                x: bounds.midX - size.width / 2,
                y: view.isFlipped
                    ? bounds.minY - gap - size.height
                    : bounds.maxY + gap + size.height
            )
            menu.popUp(positioning: nil, at: topLeft, in: view)
            isOpen = false
        }
    }
}

// MARK: - AirPlay

/// AirPlay for an AVPlayer session: the play bar's own `airplay.video` glyph
/// (AVRoutePickerView on macOS can only draw the audio glyph) over an
/// invisible system route picker that takes the click and shows the system's
/// device menu. One 28×28 control and one "AirPlay" accessibility element.
struct MacPlayerAirPlayButton: View {
    let player: AVPlayer
    /// Playing to an AirPlay device: the glyph keeps its platter.
    var isActive = false

    @State private var handle = MacPlayerRoutePickerHandle()

    var body: some View {
        MacPlayerHUDIcon(systemName: "airplay.video", isActive: isActive)
            .overlay {
                MacPlayerRoutePicker(player: player, handle: handle)
            }
            .frame(width: MacPlayerHUDLayout.iconSize, height: MacPlayerHUDLayout.iconSize)
            .help("AirPlay")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("AirPlay")
            .accessibilityAddTraits(.isButton)
            .accessibilityValue(isActive ? "On" : "")
            .accessibilityAction { handle.open() }
    }
}

/// Reaches the route picker's own button for the accessibility action.
@MainActor
final class MacPlayerRoutePickerHandle {
    weak var view: AVRoutePickerView?

    func open() {
        guard let view, let button = Self.firstButton(in: view) else { return }
        button.performClick(nil)
    }

    private static func firstButton(in view: NSView) -> NSButton? {
        for subview in view.subviews {
            if let button = subview as? NSButton { return button }
            if let button = firstButton(in: subview) { return button }
        }
        return nil
    }
}

private struct MacPlayerRoutePicker: NSViewRepresentable {
    let player: AVPlayer
    let handle: MacPlayerRoutePickerHandle

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.isRoutePickerButtonBordered = false
        // Invisible: the SwiftUI glyph underneath is what shows.
        for state in [AVRoutePickerView.ButtonState.normal, .normalHighlighted, .active, .activeHighlighted] {
            view.setRoutePickerButtonColor(.clear, for: state)
        }
        view.setAccessibilityElement(false)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        handle.view = view
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
        handle.view = nsView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVRoutePickerView, context: Context) -> CGSize? {
        CGSize(width: MacPlayerHUDLayout.iconSize, height: MacPlayerHUDLayout.iconSize)
    }
}

// MARK: - Track labels

/// One formatter for both engines' audio and subtitle tracks: the language as
/// the item's title, the technical detail as its quieter second line, in one
/// order everywhere ("AAC 5.1", "TrueHD 7.1 Atmos", "AC3 Stereo · Commentary",
/// "SRT · Forced"), with the language never repeated and every row unique.
enum MacPlayerTrackLabel {
    struct Label: Equatable {
        var title: String
        var detail: String?
    }

    // MARK: Lists

    /// Audio rows in the file's order (it carries meaning: main mix first).
    static func audioRows(_ tracks: [AudioTrack]) -> [(track: AudioTrack, label: Label)] {
        uniqued(tracks.map { ($0, label(for: $0)) })
    }

    /// Subtitle rows sorted by language, the full track before its forced
    /// and SDH variants. AVPlayer's synthesized "forced only" twin of a track
    /// (same Plex stream) is left out like AVKit's own menu does, unless it is
    /// the one playing.
    static func subtitleRows(
        _ tracks: [SubtitleTrack],
        selectedID: Int?
    ) -> [(track: SubtitleTrack, label: Label)] {
        let fullStreamIDs = Set(tracks.filter { !$0.isForced }.compactMap(\.plexStreamID))
        let visible = tracks.enumerated().filter { _, track in
            guard track.isForced, let streamID = track.plexStreamID,
                  fullStreamIDs.contains(streamID) else { return true }
            return track.id == selectedID
        }
        let rows = visible
            .map { (offset: $0.offset, track: $0.element, label: label(for: $0.element)) }
            .sorted { lhs, rhs in
                let order = lhs.label.title.localizedStandardCompare(rhs.label.title)
                if order != .orderedSame { return order == .orderedAscending }
                let lhsKey = [lhs.track.isForced, lhs.track.isHearingImpaired, lhs.track.isExternal].map { $0 ? 1 : 0 }
                let rhsKey = [rhs.track.isForced, rhs.track.isHearingImpaired, rhs.track.isExternal].map { $0 ? 1 : 0 }
                if lhsKey != rhsKey { return lhsKey.lexicographicallyPrecedes(rhsKey) }
                return lhs.offset < rhs.offset
            }
            .map { ($0.track, $0.label) }
        return uniqued(rows)
    }

    /// Rows that would still read the same get a counter: "Spanish (2)".
    private static func uniqued<Track>(_ rows: [(Track, Label)]) -> [(track: Track, label: Label)] {
        var seen: [String: Int] = [:]
        let keys = rows.map { "\($0.1.title)\u{1}\($0.1.detail ?? "")" }
        let duplicated = Set(Dictionary(grouping: keys, by: { $0 }).filter { $0.value.count > 1 }.keys)
        return zip(rows, keys).map { row, key in
            var label = row.1
            if duplicated.contains(key) {
                let count = (seen[key] ?? 0) + 1
                seen[key] = count
                if count > 1 { label.title += " (\(count))" }
            }
            return (row.0, label)
        }
    }

    // MARK: Single tracks

    static func label(for track: AudioTrack) -> Label {
        let language = languageName(code: track.languageCode, name: track.language)
        let components = detailComponents(
            track.displayTitle,
            removing: languageTerms(code: track.languageCode, name: track.language)
        )

        var parts: [String] = []
        if let first = components.first, startsWithAudioCodec(first) {
            // Already codec first ("TrueHD 7.1 Atmos"): keep it, plus any
            // non-technical extras ("Commentary").
            parts.append(first)
            parts += components.dropFirst().compactMap { nonTechnical($0, words: audioTechnicalWords) }
        } else {
            let base = [audioCodecName(track.codec), channelName(track.channels)]
                .compactMap { $0 }
                .joined(separator: " ")
                .nilIfEmpty
            if let base {
                parts.append(base)
                parts += components.compactMap { nonTechnical($0, words: audioTechnicalWords) }
            } else {
                parts += components
            }
        }
        if !track.isDecodable {
            parts.append("Server Conversion")
        }
        return Label(title: language ?? track.compactDisplayTitle, detail: unique(parts).joined(separator: " · ").nilIfEmpty)
    }

    static func label(for track: SubtitleTrack) -> Label {
        let language = languageName(code: track.languageCode, name: track.language)
        let components = detailComponents(
            track.displayTitle,
            removing: languageTerms(code: track.languageCode, name: track.language)
        )

        var parts: [String] = []
        // The title's own format word wins ("English · PGS"), then the codec.
        let titledCodec = components
            .flatMap { $0.split(separator: " ").map(String.init) }
            .lazy
            .compactMap { subtitleCodecName($0) }
            .first
        if let codec = titledCodec ?? subtitleCodecName(track.codec) {
            parts.append(codec)
        }
        parts += components.compactMap { nonTechnical($0, words: subtitleTechnicalWords) }
        if track.isForced { parts.append("Forced") }
        if track.isHearingImpaired { parts.append("SDH") }
        if track.isExternal {
            parts.append(track.requiresEngineSwitch ? "External · Switches to VLC" : "External")
        }
        return Label(title: language ?? track.displayTitle, detail: unique(parts).joined(separator: " · ").nilIfEmpty)
    }

    // MARK: Helpers

    /// The language in the viewer's own locale ("German", not "Deutsch").
    private static func languageName(code: String?, name: String?) -> String? {
        if let code, let localized = Locale.current.localizedString(forLanguageCode: code) {
            return localized.capitalized(with: Locale.current)
        }
        return name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// Every spelling of the language a title might carry: Plex's name, the
    /// localized name and the language's own name for itself.
    private static func languageTerms(code: String?, name: String?) -> [String] {
        var terms: [String] = []
        if let name { terms.append(name) }
        if let code {
            if let localized = Locale.current.localizedString(forLanguageCode: code) { terms.append(localized) }
            if let native = Locale(identifier: code).localizedString(forLanguageCode: code) { terms.append(native) }
            if let english = Locale(identifier: "en").localizedString(forLanguageCode: code) { terms.append(english) }
        }
        return terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// "English · TrueHD 7.1 Atmos" → ["TrueHD 7.1 Atmos"], "Surround 5.1
    /// (English AAC)" → ["Surround 5.1", "AAC"], "English" → [].
    private static func detailComponents(_ title: String, removing terms: [String]) -> [String] {
        let separators = CharacterSet(charactersIn: "·()[]|/")
        let components = title
            .components(separatedBy: separators)
            .map { component -> String in
                var words = component.split(separator: " ").map(String.init)
                words.removeAll { word in
                    terms.contains { $0.compare(word, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
                }
                return words.joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " -–—,").union(.whitespacesAndNewlines))
            }
            .filter { !$0.isEmpty }
        return unique(components)
    }

    private static func unique(_ parts: [String]) -> [String] {
        var result: [String] = []
        for part in parts where !result.contains(where: { $0.caseInsensitiveCompare(part) == .orderedSame }) {
            result.append(part)
        }
        return result
    }

    /// What is left of a component once its technical words are gone, or nil.
    private static func nonTechnical(_ component: String, words technical: Set<String>) -> String? {
        component
            .split(separator: " ")
            .filter { !technical.contains($0.lowercased()) }
            .joined(separator: " ")
            .nilIfEmpty
    }

    private static let audioCodecWords: Set<String> = [
        "aac", "ac3", "ac-3", "eac3", "e-ac3", "e-ac-3", "ec3", "truehd", "dts", "dts-hd", "dts:x",
        "dolby", "flac", "alac", "opus", "mp3", "pcm", "lpcm", "mp2", "vorbis", "atmos",
    ]

    private static let audioTechnicalWords: Set<String> = audioCodecWords.union([
        "digital", "digital+", "plus", "ma", "hd", "hra", "x", "mono", "stereo", "surround",
        "1.0", "2.0", "2.1", "5.0", "5.1", "6.1", "7.1", "ch", "lc", "he-aac",
    ])

    private static let subtitleTechnicalWords: Set<String> = [
        "srt", "subrip", "pgs", "ass", "ssa", "vobsub", "webvtt", "vtt", "mov_text", "tx3g", "text",
        "forced", "sdh", "cc", "external", "hearing", "impaired",
    ]

    private static func startsWithAudioCodec(_ component: String) -> Bool {
        guard let first = component.split(separator: " ").first?.lowercased() else { return false }
        return audioCodecWords.contains(first)
    }

    private static func audioCodecName(_ codec: String?) -> String? {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return nil }
        switch codec {
        case "truehd", "mlp": return "TrueHD"
        case "eac3", "ec-3", "ec3": return "E-AC3"
        case "ac3", "ac-3", "a52": return "AC3"
        case "dca", "dts": return "DTS"
        case "aac", "mp4a": return "AAC"
        case "flac": return "FLAC"
        case "alac": return "ALAC"
        case "opus": return "Opus"
        case "mp3", "mpga": return "MP3"
        case "pcm", "lpcm": return "PCM"
        default: return codec.uppercased()
        }
    }

    private static func channelName(_ channels: Int?) -> String? {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        case let count?: return "\(count) ch"
        case nil: return nil
        }
    }

    private static func subtitleCodecName(_ codec: String?) -> String? {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return nil }
        switch codec {
        case "pgs", "hdmv_pgs_subtitle", "pgssub": return "PGS"
        case "srt", "subrip": return "SRT"
        case "ass", "ssa": return "SSA"
        case "mov_text", "tx3g": return "Text"
        case "vobsub", "dvd_subtitle": return "VobSub"
        case "webvtt", "vtt", "wvtt": return "WebVTT"
        case "eia_608", "eia_708", "cc_dec": return "CC"
        default: return nil
        }
    }
}
#endif
