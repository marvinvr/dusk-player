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
///
/// Xtream Codes lists (`get.php?…&type=m3u_plus`) mix live channels with the
/// whole movie and series catalogue; those entries are dropped (`XtreamURL`),
/// and raw MPEG-TS live URLs become the panel's HLS URL, which AVPlayer plays.
///
/// Fed line by line (`Reader`), so a list of tens of megabytes is parsed
/// from disk in fixed-size chunks (`parse(fileURL:)`), never held whole.
enum M3UParser {
    struct Options: Sendable {
        /// The Xtream `username` / `password` of the playlist URL, which
        /// identify the panel's extensionless live URLs.
        var xtreamCredentials: XtreamURL.Credentials?

        init(playlistURL: URL? = nil) {
            xtreamCredentials = playlistURL.flatMap(XtreamURL.credentials(fromPlaylistURL:))
        }
    }

    static func parse(_ data: Data, options: Options = Options()) -> IPTVPlaylist {
        parse(String(decoding: data, as: UTF8.self), options: options)
    }

    static func parse(_ text: String, options: Options = Options()) -> IPTVPlaylist {
        var reader = Reader(options: options)
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            reader.consume(line)
        }
        return reader.playlist
    }

    /// Reads a downloaded playlist in 1 MB chunks. Memory stays at one chunk
    /// plus the parsed entries, whatever the file size. A "line" longer than
    /// `maxLineLength` (a binary or broken file) is dropped, not buffered.
    static func parse(fileURL: URL, options: Options = Options()) throws -> IPTVPlaylist {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var reader = Reader(options: options)
        var carry = Data()
        var skippingLongLine = false
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            carry.append(chunk)
            let consumed = carry.withUnsafeBytes { raw -> Int in
                let bytes = raw.bindMemory(to: UInt8.self)
                var start = 0
                for index in 0..<bytes.count where bytes[index] == 0x0A || bytes[index] == 0x0D {
                    if index > start, !skippingLongLine {
                        reader.consume(String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<index]), as: UTF8.self))
                    }
                    skippingLongLine = false
                    start = index + 1
                }
                return start
            }
            carry.removeSubrange(0..<consumed)
            if carry.count > maxLineLength {
                carry.removeAll(keepingCapacity: true)
                skippingLongLine = true
            }
        }
        if !carry.isEmpty, !skippingLongLine {
            reader.consume(String(decoding: carry, as: UTF8.self))
        }
        return reader.playlist
    }

    private static let chunkSize = 1 << 20
    private static let maxLineLength = 1 << 20

    /// The parser state, fed one line at a time.
    struct Reader {
        let options: Options
        private var guideURLs: [URL] = []
        private var entries: [IPTVPlaylistEntry] = []
        private var pending = PendingEntry()
        /// `#EXTM3U catchup=… catchup-days=… catchup-source=…`: defaults for
        /// every entry that names none of its own.
        private var headerAttributes: [String: String] = [:]
        private var skippedVODEntries = 0

        init(options: Options = Options()) {
            self.options = options
        }

        var playlist: IPTVPlaylist {
            IPTVPlaylist(guideURLs: M3UParser.unique(guideURLs), entries: entries, skippedVODEntries: skippedVODEntries)
        }

        mutating func consume<Line: StringProtocol>(_ rawLine: Line) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
            guard !line.isEmpty else { return }

            if line.hasPrefix("#") {
                M3UParser.handleDirective(line, pending: &pending, guideURLs: &guideURLs, headerAttributes: &headerAttributes)
                return
            }

            // A URL line closes the entry. Junk that is not an http(s) URL is
            // dropped together with whatever was pending, so one broken entry
            // cannot leak its options into the next.
            defer { pending = PendingEntry() }
            guard let (url, pipeHeaders) = M3UParser.streamURL(from: line) else { return }
            if XtreamURL.isVOD(url) {
                skippedVODEntries += 1
                return
            }
            let playable = XtreamURL.liveHLSURL(for: url, credentials: options.xtreamCredentials) ?? url
            entries.append(pending.entry(streamURL: playable, pipeHeaders: pipeHeaders, headerAttributes: headerAttributes))
        }
    }

    // MARK: - Directives

    fileprivate static func handleDirective(
        _ line: String,
        pending: inout PendingEntry,
        guideURLs: inout [URL],
        headerAttributes: inout [String: String]
    ) {
        let upper = line.uppercased()
        if upper.hasPrefix("#EXTM3U") {
            let attributes = parseAttributes(String(line.dropFirst("#EXTM3U".count)))
            headerAttributes.merge(attributes) { _, new in new }
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

    fileprivate struct PendingEntry {
        var hasInfo = false
        var title: String?
        var attributes: [String: String] = [:]
        var extGroup: String?
        var userAgent: String?
        var referrer: String?
        var drm = IPTVDRMConfiguration()

        func entry(
            streamURL: URL,
            pipeHeaders: [String: String],
            headerAttributes: [String: String] = [:]
        ) -> IPTVPlaylistEntry {
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
                drm: drm.isEmpty ? nil : drm,
                catchUp: IPTVCatchUp(attributes: attributes, defaults: headerAttributes)
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
    fileprivate static func streamURL(from line: String) -> (URL, [String: String])? {
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

    fileprivate static func unique(_ urls: [URL]) -> [URL] {
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

/// Xtream Codes panels (`get.php?username=…&password=…&type=m3u_plus`), the
/// most common IPTV backend. Recognized by URL shape only:
/// `…/live/<user>/<pass>/<id>.ts`, the older extensionless
/// `…/<user>/<pass>/<id>`, and `…/movie|series/<user>/<pass>/<id>.<ext>`.
enum XtreamURL {
    struct Credentials: Hashable, Sendable {
        let username: String
        let password: String
    }

    /// `username` and `password` from a `get.php` style playlist URL.
    static func credentials(fromPlaylistURL url: URL) -> Credentials? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value?.nilIfEmpty
        }
        guard let username = value("username"), let password = value("password") else { return nil }
        return Credentials(username: username, password: password)
    }

    /// A movie or series episode of the panel's VOD catalogue, which an
    /// `m3u_plus` list includes next to the live channels.
    static func isVOD(_ url: URL) -> Bool {
        let parts = pathParts(of: url)
        guard parts.count >= 4 else { return false }
        let kind = parts[parts.count - 4].lowercased()
        return kind == "movie" || kind == "series"
    }

    /// The panel's HLS URL for a raw MPEG-TS live channel (`output=ts`, the
    /// default), or nil when `url` is not one. Xtream serves every live
    /// channel as HLS at the same path with `.m3u8`; AVPlayer cannot play a
    /// raw transport stream over HTTP at all.
    static func liveHLSURL(for url: URL, credentials: Credentials?) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = pathParts(of: url)
        guard parts.count >= 3, let file = parts.last else { return nil }
        let fileName = file as NSString
        let fileExtension = fileName.pathExtension.lowercased()
        let streamID = fileName.deletingPathExtension
        guard fileExtension == "ts" || fileExtension.isEmpty,
              !streamID.isEmpty, streamID.allSatisfy(\.isASCII), streamID.allSatisfy(\.isNumber) else { return nil }

        let user = parts[parts.count - 3]
        let password = parts[parts.count - 2]
        let isLivePath = parts.count >= 4 && parts[parts.count - 4].lowercased() == "live"
        let matchesCredentials = credentials.map {
            $0.username == (user.removingPercentEncoding ?? user)
                && $0.password == (password.removingPercentEncoding ?? password)
        } ?? false
        guard isLivePath || matchesCredentials else { return nil }

        let prefix = parts.dropLast(isLivePath ? 4 : 3)
        components.percentEncodedPath = "/" + (prefix + ["live", user, password, "\(streamID).m3u8"]).joined(separator: "/")
        return components.url
    }

    /// Path segments as written (still percent-encoded).
    private static func pathParts(of url: URL) -> [String] {
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        return path.split(separator: "/").map(String.init)
    }
}
