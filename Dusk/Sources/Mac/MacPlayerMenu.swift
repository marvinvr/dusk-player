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
    var kind: Kind

    static func action(
        _ title: String,
        subtitle: String? = nil,
        isOn: Bool = false,
        isEnabled: Bool = true,
        _ action: @escaping () -> Void
    ) -> MacPlayerMenuItem {
        MacPlayerMenuItem(title: title, subtitle: subtitle, isOn: isOn, isEnabled: isEnabled, kind: .action(action))
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
                    keyEquivalent: ""
                )
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

/// The system AirPlay route picker for an AVPlayer session, drawn as a plain
/// white glyph to match the play bar.
struct MacPlayerRoutePicker: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.player = player
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.white.withAlphaComponent(0.85), for: .normal)
        view.setRoutePickerButtonColor(.white, for: .normalHighlighted)
        view.setRoutePickerButtonColor(.white, for: .active)
        view.setRoutePickerButtonColor(.white, for: .activeHighlighted)
        return view
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

// MARK: - Track labels

/// One formatter for both engines' audio and subtitle tracks: the language as
/// the item's title, the technical detail (codec, channels, Atmos, forced, …)
/// as its quieter second line, with the language never repeated.
enum MacPlayerTrackLabel {
    struct Label: Equatable {
        let title: String
        let detail: String?
    }

    static func label(for track: AudioTrack) -> Label {
        let language = languageName(code: track.languageCode, name: track.language)
        var detail = strippedDetail(track.displayTitle, removing: languageTerms(code: track.languageCode, name: track.language))
        if detail == nil {
            detail = [codecName(track.codec), channelName(track.channels)]
                .compactMap { $0 }
                .joined(separator: " ")
                .nilIfEmpty
        }
        if !track.isDecodable {
            detail = [detail, "Server Conversion"].compactMap { $0 }.joined(separator: " · ")
        }
        return Label(title: language ?? track.compactDisplayTitle, detail: detail)
    }

    static func label(for track: SubtitleTrack) -> Label {
        let language = languageName(code: track.languageCode, name: track.language)
        var parts: [String] = []
        if let stripped = strippedDetail(track.displayTitle, removing: languageTerms(code: track.languageCode, name: track.language)) {
            parts.append(stripped)
        } else if let codec = subtitleCodecName(track.codec) {
            parts.append(codec)
        }
        if track.isForced, !parts.contains(where: { $0.localizedCaseInsensitiveContains("forced") }) {
            parts.append("Forced")
        }
        if track.isHearingImpaired, !parts.contains(where: { $0.localizedCaseInsensitiveContains("SDH") }) {
            parts.append("SDH")
        }
        if track.isExternal {
            parts.append(track.requiresEngineSwitch ? "External · Switches to VLC" : "External")
        }
        return Label(title: language ?? track.displayTitle, detail: parts.joined(separator: " · ").nilIfEmpty)
    }

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

    /// "English · TrueHD 7.1 Atmos" → "TrueHD 7.1 Atmos", "English (AAC 5.1)"
    /// → "AAC 5.1", "Surround 5.1 (English AAC)" → "Surround 5.1 · AAC",
    /// "English · English" → nil.
    private static func strippedDetail(_ title: String, removing terms: [String]) -> String? {
        let separators = CharacterSet(charactersIn: "·()[]|/")
        let components = title
            .components(separatedBy: separators)
            .map { component -> String in
                var words = component
                    .split(separator: " ")
                    .map(String.init)
                words.removeAll { word in
                    terms.contains { $0.compare(word, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
                }
                return words.joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " -–—,").union(.whitespacesAndNewlines))
            }
            .filter { !$0.isEmpty }

        var unique: [String] = []
        for component in components where !unique.contains(where: { $0.caseInsensitiveCompare(component) == .orderedSame }) {
            unique.append(component)
        }
        return unique.joined(separator: " · ").nilIfEmpty
    }

    private static func codecName(_ codec: String?) -> String? {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return nil }
        switch codec {
        case "truehd", "mlp": return "Dolby TrueHD"
        case "eac3", "ec-3", "ec3": return "Dolby Digital Plus"
        case "ac3", "ac-3", "a52": return "Dolby Digital"
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
        case "mov_text", "tx3g": return nil
        case "vobsub", "dvd_subtitle": return "VobSub"
        case "webvtt", "vtt": return "WebVTT"
        default: return codec.uppercased()
        }
    }
}
#endif
