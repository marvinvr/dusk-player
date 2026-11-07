import Foundation

/// Standard IPTV catch-up (the `catchup` / `catchup-days` / `catchup-source`
/// M3U attributes Kodi's IPTV Simple, TiviMate and most players read): a past
/// programme of a channel plays from a URL built by substituting the
/// programme's times into a template. Generic: nothing here knows a provider.
///
/// Modes:
/// - `default`: `catchup-source` is the whole URL, with placeholders.
/// - `append`: `catchup-source` is appended to the channel's stream URL.
/// - `shift` / `timeshift`: `?utc={utc}&lutc={lutc}` is appended to the
///   stream URL (no source needed).
///
/// Any other mode (`flussonic`, `xc`, `vod`, …) is ignored: the channel then
/// simply has no catch-up.
struct IPTVCatchUp: Hashable, Sendable {
    enum Mode: String, Hashable, Sendable {
        case `default`, append, shift
    }

    var mode: Mode
    /// How far back programmes can be played.
    var days: Int
    /// The template (`default`: absolute URL; `append`: suffix; `shift`: unused).
    var source: String?

    /// When the attributes name no window. Matches the common provider
    /// default and Dusk's guide horizon.
    static let defaultDays = 7
    /// Never look further back than this, whatever a playlist claims.
    static let maximumDays = 14

    /// From an entry's attributes, with the playlist header's as defaults.
    /// Nil when the entry has no usable catch-up.
    init?(attributes: [String: String], defaults: [String: String] = [:]) {
        func value(_ keys: [String]) -> String? {
            for key in keys {
                if let value = attributes[key]?.nilIfEmpty { return value }
            }
            for key in keys {
                if let value = defaults[key]?.nilIfEmpty { return value }
            }
            return nil
        }

        let rawMode = value(["catchup", "catchup-type"])?.lowercased()
        let source = value(["catchup-source", "catchup-template"])
        let mode: Mode
        switch rawMode {
        case "default", nil:
            // A source without a mode is the default mode; nothing at all
            // means no catch-up.
            guard rawMode != nil || source != nil else { return nil }
            mode = .default
        case "append":
            mode = .append
        case "shift", "timeshift":
            mode = .shift
        default:
            return nil
        }

        switch mode {
        case .default:
            guard let source, M3UParser.httpURL(source) != nil || Self.looksAbsolute(source) else { return nil }
        case .append:
            guard source != nil else { return nil }
        case .shift:
            break
        }

        let days = value(["catchup-days", "timeshift", "tvg-rec"]).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            ?? Self.defaultDays
        guard days > 0 else { return nil }
        self.mode = mode
        self.days = min(days, Self.maximumDays)
        self.source = source
    }

    init(mode: Mode, days: Int, source: String?) {
        self.mode = mode
        self.days = days
        self.source = source
    }

    /// A template with placeholders is not a parseable URL until filled in
    /// (`{utc}` has braces), so the scheme alone decides.
    private static func looksAbsolute(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    // MARK: - Availability

    /// Whether a programme from `start` to `end` can be played back now: it
    /// has ended, and began inside the catch-up window.
    func isAvailable(start: Date, end: Date, now: Date = .now) -> Bool {
        end <= now && start >= now.addingTimeInterval(-TimeInterval(days) * 24 * 60 * 60)
    }

    // MARK: - URL

    /// The playback URL for a programme, or nil when the result is not an
    /// http(s) URL.
    func url(streamURL: URL, start: Date, end: Date, now: Date = .now) -> URL? {
        let template: String
        switch mode {
        case .default:
            template = source ?? ""
        case .append:
            template = streamURL.absoluteString + (source ?? "")
        case .shift:
            let separator = streamURL.query == nil ? "?" : "&"
            template = streamURL.absoluteString + separator + "utc={utc}&lutc={lutc}"
        }
        let filled = Self.fill(template, start: start, end: end, now: now)
        return M3UParser.httpURL(filled)
    }

    /// Substitutes the placeholders Kodi's IPTV Simple documents:
    /// `{utc}` / `${start}` (start, unix seconds), `{utcend}` / `${end}`,
    /// `{lutc}` / `${now}` / `${timestamp}` (now), `{duration}` (seconds;
    /// `{duration:60}` divides, so minutes), `{offset:N}` (seconds since the
    /// start, divided by N), `{Y} {m} {d} {H} {M} {S}` (start, UTC), and
    /// `{utc:FORMAT}` / `{utcend:FORMAT}` / `${start:FORMAT}` /
    /// `${end:FORMAT}` with the same letters inside FORMAT. Anything else in
    /// braces is left as written.
    static func fill(_ template: String, start: Date, end: Date, now: Date) -> String {
        let startSeconds = Int(start.timeIntervalSince1970)
        let endSeconds = Int(end.timeIntervalSince1970)
        let nowSeconds = Int(now.timeIntervalSince1970)
        let duration = max(endSeconds - startSeconds, 0)
        let offset = max(nowSeconds - startSeconds, 0)

        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            var openIndex = index
            if character == "$", template.index(after: index) < template.endIndex,
               template[template.index(after: index)] == "{" {
                openIndex = template.index(after: index)
            } else if character != "{" {
                result.append(character)
                index = template.index(after: index)
                continue
            }
            guard let close = template[openIndex...].firstIndex(of: "}") else {
                result.append(contentsOf: template[index...])
                break
            }
            let token = String(template[template.index(after: openIndex)..<close])
            if let value = value(
                for: token, start: start, end: end,
                startSeconds: startSeconds, endSeconds: endSeconds, nowSeconds: nowSeconds,
                duration: duration, offset: offset
            ) {
                result += value
            } else {
                result += template[index...close]
            }
            index = template.index(after: close)
        }
        return result
    }

    private static func value(
        for token: String,
        start: Date,
        end: Date,
        startSeconds: Int,
        endSeconds: Int,
        nowSeconds: Int,
        duration: Int,
        offset: Int
    ) -> String? {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        let name = parts.first?.lowercased() ?? ""
        let argument = parts.count > 1 ? parts[1] : nil

        switch name {
        case "utc", "start", "timestamp-start":
            if let argument { return format(start, argument) }
            return String(startSeconds)
        case "utcend", "end", "stop":
            if let argument { return format(end, argument) }
            return String(endSeconds)
        case "lutc", "now", "timestamp":
            return String(nowSeconds)
        case "duration":
            let divisor = argument.flatMap(Int.init) ?? 1
            return String(duration / max(divisor, 1))
        case "offset":
            let divisor = argument.flatMap(Int.init) ?? 1
            return String(offset / max(divisor, 1))
        default:
            break
        }
        // Single-letter start components (case matters: M is minutes).
        if argument == nil, token.count == 1, let component = component(token, of: start) {
            return component
        }
        return nil
    }

    /// `Y-m-d H:M:S` style formats, UTC: each of Y m d H M S becomes the
    /// zero-padded component; every other character is kept.
    static func format(_ date: Date, _ pattern: String) -> String {
        var result = ""
        for character in pattern {
            result += component(String(character), of: date) ?? String(character)
        }
        return result
    }

    private static func component(_ letter: String, of date: Date) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        switch letter {
        case "Y": return String(format: "%04d", parts.year ?? 0)
        case "m": return String(format: "%02d", parts.month ?? 0)
        case "d": return String(format: "%02d", parts.day ?? 0)
        case "H": return String(format: "%02d", parts.hour ?? 0)
        case "M": return String(format: "%02d", parts.minute ?? 0)
        case "S": return String(format: "%02d", parts.second ?? 0)
        default: return nil
        }
    }
}

extension IPTVPlayableChannel {
    /// The same channel (headers, user agent, DRM — the KODIPROP lines apply
    /// to catch-up too) pointed at a past programme. Nil when the channel has
    /// no catch-up, the programme is outside its window, or the template
    /// yields no URL.
    func catchUpStream(start: Date, end: Date, now: Date = .now) -> IPTVPlayableChannel? {
        guard let catchUp, catchUp.isAvailable(start: start, end: end, now: now),
              let url = catchUp.url(streamURL: streamURL, start: start, end: end, now: now) else { return nil }
        return IPTVPlayableChannel(
            sourceID: sourceID,
            streamURL: url,
            headers: headers,
            userAgent: userAgent,
            drm: drm,
            catchUp: nil,
            isCatchUp: true
        )
    }

    func canCatchUp(start: Date, end: Date, now: Date = .now) -> Bool {
        catchUp?.isAvailable(start: start, end: end, now: now) == true
    }
}
