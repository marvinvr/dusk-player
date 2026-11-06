import Foundation

/// Streaming XMLTV reader. Built on `XMLParser(stream:)` so a 100 MB guide is
/// read from disk element by element, never loaded whole.
///
/// Only what the Live TV guide shows is kept: programmes inside `window`
/// whose channel is wanted. Everything else is skipped as it streams past,
/// which keeps memory bounded by the guide Dusk shows, not the file.
final class XMLTVParser: NSObject, XMLParserDelegate {
    struct Options: Sendable {
        /// Programmes that do not overlap this range are dropped.
        var window: ClosedRange<Date>
        /// XMLTV channel ids to keep programmes for; nil keeps all.
        var channelIDs: Set<String>?
    }

    private let options: Options
    private var channels: [String: IPTVGuideChannel] = [:]
    private var programmes: [String: [IPTVProgramme]] = [:]

    // Element state
    private var currentChannel: IPTVGuideChannel?
    private var currentProgramme: IPTVProgramme?
    private var text = ""
    private var capturesText = false
    /// The first title / sub-title / desc wins; later ones (other languages)
    /// never overwrite it.
    private var hasTitle = false
    private var hasSubtitle = false
    private var hasSummary = false

    private init(options: Options) {
        self.options = options
    }

    static func parse(stream: InputStream, options: Options) throws -> IPTVGuide {
        let parser = XMLParser(stream: stream)
        return try run(parser, options: options)
    }

    static func parse(data: Data, options: Options) throws -> IPTVGuide {
        try run(XMLParser(data: data), options: options)
    }

    /// Reads a guide file from disk, gunzipping `.gz` guides first.
    static func parse(fileURL: URL, options: Options) throws -> IPTVGuide {
        let readableURL = try GzipFile.decompressedIfNeeded(fileURL)
        defer {
            if readableURL != fileURL { try? FileManager.default.removeItem(at: readableURL) }
        }
        guard let stream = InputStream(url: readableURL) else {
            throw URLError(.cannotOpenFile)
        }
        return try parse(stream: stream, options: options)
    }

    private static func run(_ parser: XMLParser, options: Options) throws -> IPTVGuide {
        let delegate = XMLTVParser(options: options)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        let succeeded = parser.parse()
        // A truncated or slightly broken file still yields what was read
        // before the error; only a file with nothing usable is an error.
        if !succeeded, delegate.channels.isEmpty, delegate.programmes.isEmpty {
            throw parser.parserError ?? XMLTVError.unreadable
        }
        return delegate.guide
    }

    private var guide: IPTVGuide {
        IPTVGuide(
            channels: channels,
            programmes: programmes.mapValues { list in
                list.sorted { $0.start < $1.start }
            }
        )
    }

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes: [String: String] = [:]
    ) {
        switch elementName {
        case "channel":
            guard let id = attributes["id"]?.nilIfEmpty else { return }
            currentChannel = IPTVGuideChannel(id: id, displayNames: [], iconURL: nil)
        case "programme":
            hasTitle = false
            hasSubtitle = false
            hasSummary = false
            guard let channelID = attributes["channel"]?.nilIfEmpty,
                  options.channelIDs?.contains(channelID) ?? true,
                  let start = attributes["start"].flatMap(Self.date),
                  let stop = attributes["stop"].flatMap(Self.date) ?? Optional(start),
                  stop >= start,
                  stop > options.window.lowerBound,
                  start < options.window.upperBound else {
                currentProgramme = nil
                return
            }
            currentProgramme = IPTVProgramme(
                channelID: channelID,
                start: start,
                stop: stop,
                title: ""
            )
        case "display-name", "title", "sub-title", "desc":
            guard currentChannel != nil || currentProgramme != nil else { return }
            text = ""
            capturesText = true
        case "icon":
            guard let src = attributes["src"].flatMap(M3UParser.httpURL) else { return }
            if currentProgramme != nil, currentProgramme?.iconURL == nil {
                currentProgramme?.iconURL = src
            } else if currentChannel != nil, currentChannel?.iconURL == nil {
                currentChannel?.iconURL = src
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturesText { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if capturesText { text += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = capturesText ? text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty : nil
        switch elementName {
        case "display-name":
            if let value, currentProgramme == nil { currentChannel?.displayNames.append(value) }
        case "title":
            if let value, !hasTitle, currentProgramme != nil {
                currentProgramme?.title = value
                hasTitle = true
            }
        case "sub-title":
            if let value, !hasSubtitle, currentProgramme != nil {
                currentProgramme?.subtitle = value
                hasSubtitle = true
            }
        case "desc":
            if let value, !hasSummary, currentProgramme != nil {
                currentProgramme?.summary = value
                hasSummary = true
            }
        case "channel":
            if let channel = currentChannel { channels[channel.id] = channel }
            currentChannel = nil
        case "programme":
            if let programme = currentProgramme {
                programmes[programme.channelID, default: []].append(programme)
            }
            currentProgramme = nil
        default:
            break
        }
        if ["display-name", "title", "sub-title", "desc"].contains(elementName) {
            capturesText = false
            text = ""
        }
    }

    // MARK: - Dates

    /// XMLTV times: `YYYYMMDDhhmmss ±hhmm`, where seconds, minutes, hours and
    /// the offset may each be missing (missing offset = UTC).
    static func date(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isNumber }
        guard digits.count >= 8 else { return nil }
        let chars = Array(digits)
        func number(_ start: Int, _ length: Int) -> Int? {
            guard chars.count >= start + length else { return nil }
            return Int(String(chars[start..<(start + length)]))
        }

        var components = DateComponents()
        components.year = number(0, 4)
        components.month = number(4, 2)
        components.day = number(6, 2)
        components.hour = number(8, 2) ?? 0
        components.minute = number(10, 2) ?? 0
        components.second = number(12, 2) ?? 0

        var offsetSeconds = 0
        let rest = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        if let sign = rest.first, sign == "+" || sign == "-" {
            let offsetDigits = Array(rest.dropFirst().prefix { $0.isNumber })
            if offsetDigits.count >= 4,
               let hours = Int(String(offsetDigits[0..<2])),
               let minutes = Int(String(offsetDigits[2..<4])) {
                offsetSeconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
            }
        }
        guard let timeZone = TimeZone(secondsFromGMT: offsetSeconds) else { return nil }
        components.timeZone = timeZone
        return utcCalendar.date(from: components)
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()
}

enum XMLTVError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "The program guide couldn’t be read."
    }
}
