import Foundation

/// Extended M3U (the IPTV dialect) into `IPTVPlaylist`.
///
/// Understands `#EXTM3U url-tvg/x-tvg-url`, `#EXTINF` attributes (`tvg-id`,
/// `tvg-name`, `tvg-logo`, `group-title`, `tvg-chno`/`channel-number`/
/// `tvg-num`), `#EXTGRP`, `#KODIPROP:inputstream.adaptive.license_type /
/// license_key / server_certificate`, `#EXTVLCOPT:http-user-agent /
/// http-referrer` and Kodi's `url|Header=value` stream suffix. Option lines
/// may come before or after the `#EXTINF` they belong to; everything up to
/// the next URL line is one entry. Anything it does not understand is
/// skipped, never fatal: real-world playlists are full of junk.
enum M3UParser {
    static func parse(_ data: Data) -> IPTVPlaylist {
        let text = String(decoding: data, as: UTF8.self)
        return parse(text)
    }

    static func parse(_ text: String) -> IPTVPlaylist {
        var guideURLs: [URL] = []
        var entries: [IPTVPlaylistEntry] = []
        var pending = PendingEntry()

        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            guard !line.isEmpty else { continue }

            if line.hasPrefix("#") {
                handleDirective(line, pending: &pending, guideURLs: &guideURLs)
                continue
            }

            // A URL line closes the entry. Junk that is not an http(s) URL is
            // dropped together with whatever was pending, so one broken entry
            // cannot leak its options into the next.
            defer { pending = PendingEntry() }
            guard let (url, pipeHeaders) = streamURL(from: line) else { continue }
            entries.append(pending.entry(streamURL: url, pipeHeaders: pipeHeaders))
        }

        return IPTVPlaylist(guideURLs: unique(guideURLs), entries: entries)
    }

    // MARK: - Directives

    private static func handleDirective(
        _ line: String,
        pending: inout PendingEntry,
        guideURLs: inout [URL]
    ) {
        let upper = line.uppercased()
        if upper.hasPrefix("#EXTM3U") {
            let attributes = parseAttributes(String(line.dropFirst("#EXTM3U".count)))
            for key in ["url-tvg", "x-tvg-url", "tvg-url"] {
                guard let value = attributes[key] else { continue }
                guideURLs += value
                    .split(separator: ",")
                    .compactMap { httpURL(String($0)) }
            }
        } else if upper.hasPrefix("#EXTINF:") {
            let body = String(line.dropFirst("#EXTINF:".count))
            let (attributePart, title) = splitTitle(body)
            pending.attributes = parseAttributes(attributePart)
            pending.title = title
            pending.hasInfo = true
        } else if upper.hasPrefix("#EXTGRP:") {
            pending.extGroup = String(line.dropFirst("#EXTGRP:".count))
                .trimmingCharacters(in: .whitespaces)
                .nilIfEmpty
        } else if upper.hasPrefix("#KODIPROP:") {
            let (key, value) = keyValue(String(line.dropFirst("#KODIPROP:".count)))
            switch key.lowercased() {
            case "inputstream.adaptive.license_type":
                pending.drm.licenseType = value.nilIfEmpty
            case "inputstream.adaptive.license_key", "inputstream.adaptive.license_url":
                // Kodi allows `url|headers|body|response`; only the URL is a
                // standard part of the flow Dusk runs.
                let url = value.split(separator: "|", maxSplits: 1).first.map(String.init) ?? value
                pending.drm.licenseURL = httpURL(url)
            case "inputstream.adaptive.server_certificate":
                pending.drm.certificateURL = httpURL(value)
            default:
                break
            }
        } else if upper.hasPrefix("#EXTVLCOPT:") {
            let (key, value) = keyValue(String(line.dropFirst("#EXTVLCOPT:".count)))
            switch key.lowercased() {
            case "http-user-agent":
                pending.userAgent = value.nilIfEmpty
            case "http-referrer", "http-referer":
                pending.referrer = value.nilIfEmpty
            default:
                break
            }
        }
        // Every other `#` line (#EXTVLCOPT we don't use, #EXT-X-…, comments)
        // is ignored.
    }

    // MARK: - Entry assembly

    private struct PendingEntry {
        var hasInfo = false
        var title: String?
        var attributes: [String: String] = [:]
        var extGroup: String?
        var userAgent: String?
        var referrer: String?
        var drm = IPTVDRMConfiguration()

        func entry(streamURL: URL, pipeHeaders: [String: String]) -> IPTVPlaylistEntry {
            var headers = pipeHeaders
            var userAgent = userAgent
            var referrer = referrer
            if let value = headers.removeValue(forKeyCaseInsensitive: "User-Agent") {
                userAgent = userAgent ?? value
            }
            if let value = headers.removeValue(forKeyCaseInsensitive: "Referer")
                ?? headers.removeValue(forKeyCaseInsensitive: "Referrer") {
                referrer = referrer ?? value
            }

            let tvgName = attributes["tvg-name"]?.nilIfEmpty
            let title = title?.nilIfEmpty
                ?? tvgName
                ?? streamURL.deletingPathExtension().lastPathComponent.nilIfEmpty
                ?? streamURL.host
                ?? streamURL.absoluteString
            return IPTVPlaylistEntry(
                title: title,
                streamURL: streamURL,
                tvgID: attributes["tvg-id"]?.nilIfEmpty,
                tvgName: tvgName,
                logoURL: attributes["tvg-logo"].flatMap(M3UParser.httpURL),
                group: attributes["group-title"]?.nilIfEmpty ?? extGroup,
                number: (attributes["tvg-chno"] ?? attributes["channel-number"] ?? attributes["tvg-num"])?.nilIfEmpty,
                userAgent: userAgent,
                referrer: referrer,
                streamHeaders: headers,
                drm: drm.isEmpty ? nil : drm
            )
        }
    }

    // MARK: - Lexing

    /// `-1 tvg-id="a" group-title="b, c",Title, with commas` → attributes and
    /// title. The title starts after the first comma outside quotes.
    static func splitTitle(_ body: String) -> (attributes: String, title: String?) {
        var quote: Character?
        for index in body.indices {
            let character = body[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "," {
                let title = body[body.index(after: index)...].trimmingCharacters(in: .whitespaces)
                return (String(body[..<index]), title.nilIfEmpty)
            }
        }
        return (body, nil)
    }

    /// `key="value" key2='v' key3=bare` → lowercased keys. The leading
    /// duration (`-1`, `0`) has no `=` and is skipped.
    static func parseAttributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var index = text.startIndex

        func skipSpaces() {
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        }

        while index < text.endIndex {
            skipSpaces()
            let keyStart = index
            while index < text.endIndex, !text[index].isWhitespace, text[index] != "=" {
                index = text.index(after: index)
            }
            let key = text[keyStart..<index].lowercased()
            guard index < text.endIndex, text[index] == "=" else { continue }
            index = text.index(after: index)

            let value: String
            if index < text.endIndex, text[index] == "\"" || text[index] == "'" {
                let quote = text[index]
                index = text.index(after: index)
                let valueStart = index
                while index < text.endIndex, text[index] != quote { index = text.index(after: index) }
                value = String(text[valueStart..<index])
                if index < text.endIndex { index = text.index(after: index) }
            } else {
                let valueStart = index
                while index < text.endIndex, !text[index].isWhitespace { index = text.index(after: index) }
                value = String(text[valueStart..<index])
            }
            if !key.isEmpty { result[key] = value.trimmingCharacters(in: .whitespaces) }
        }
        return result
    }

    private static func keyValue(_ text: String) -> (String, String) {
        guard let equals = text.firstIndex(of: "=") else {
            return (text.trimmingCharacters(in: .whitespaces), "")
        }
        return (
            text[..<equals].trimmingCharacters(in: .whitespaces),
            text[text.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        )
    }

    /// The URL line, with Kodi's `|User-Agent=…&Referer=…` suffix split off.
    private static func streamURL(from line: String) -> (URL, [String: String])? {
        let parts = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let url = httpURL(String(first)) else { return nil }
        var headers: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let (key, value) = keyValue(String(pair))
                guard !key.isEmpty, !value.isEmpty else { continue }
                headers[key] = value.removingPercentEncoding ?? value
            }
        }
        return (url, headers)
    }

    static func httpURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }
}

private extension Dictionary where Key == String, Value == String {
    mutating func removeValue(forKeyCaseInsensitive key: String) -> String? {
        guard let match = keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) else {
            return nil
        }
        return removeValue(forKey: match)
    }
}
