import Foundation

/// Parsed Seerr base URL. Built from a string on purpose: assigning
/// `URLComponents.host` drops the port on some systems and turns an IPv6
/// address into a nil URL.
enum SeerrServerURL {
    static let placeholder = "http://192.168.1.10:5055"
    static let publicSettingsPath = "api/v1/settings/public"

    enum RedirectDecision: Equatable, Sendable {
        case follow
        case rejectLogin
        case rejectCrossOrigin
    }

    struct SetCookie: Equatable, Sendable {
        var name: String
        var value: String
        var remove: Bool
    }

    /// Schemeless IP addresses and local names use HTTP. Other hostnames try
    /// HTTPS first, then HTTP. An explicit scheme is used as entered.
    static func candidates(from raw: String) throws -> [URL] {
        let parsed = try parse(raw)
        let schemes: [String]
        if let scheme = parsed.scheme {
            schemes = [scheme]
        } else if prefersPlainHTTP(host: parsed.host) {
            schemes = ["http"]
        } else {
            schemes = ["https", "http"]
        }
        let urls = schemes.compactMap {
            makeURL(scheme: $0, host: parsed.host, port: parsed.port, path: parsed.path)
        }
        guard !urls.isEmpty else { throw SeerrServiceError.invalidServerURL }
        return urls
    }

    static func normalizedBaseURL(from raw: String) throws -> URL {
        guard let url = try candidates(from: raw).first else {
            throw SeerrServiceError.invalidServerURL
        }
        return url
    }

    static func endpointURL(
        base: URL,
        path: String,
        queryItems: [URLQueryItem] = []
    ) -> URL? {
        guard var url = URL(string: base.absoluteString) else { return nil }
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(component))
        }
        guard !queryItems.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        // `queryItems` leaves sub-delimiters like ' ! ( ) * unescaped, and
        // Seerr's OpenAPI validator rejects them with a 400 ("You've got mail").
        components.percentEncodedQueryItems = queryItems.map { item in
            URLQueryItem(
                name: percentEncodedQueryValue(item.name),
                value: item.value.map(percentEncodedQueryValue)
            )
        }
        return components.url
    }

    static func adoptingRedirect(from base: URL, responseURL: URL, requestedPath: String) -> URL {
        guard let scheme = responseURL.scheme?.lowercased(),
              let host = normalizedHost(responseURL.host) else {
            return base
        }
        let path = basePath(
            responsePath: responseURL.path,
            requestedPath: requestedPath,
            fallback: base.path
        )
        return makeURL(scheme: scheme, host: host, port: responseURL.port, path: path) ?? base
    }

    /// Same host only. HTTP may upgrade to HTTPS. HTTPS must not downgrade,
    /// and a hop to another host is refused so a session cookie cannot leak.
    static func redirectDecision(from current: URL, to next: URL) -> RedirectDecision {
        guard let fromHost = normalizedHost(current.host),
              let toHost = normalizedHost(next.host),
              fromHost == toHost else {
            return .rejectCrossOrigin
        }
        let fromScheme = current.scheme?.lowercased()
        let toScheme = next.scheme?.lowercased()
        guard toScheme == "http" || toScheme == "https" else {
            return .rejectCrossOrigin
        }
        if fromScheme == "https", toScheme != "https" {
            return .rejectCrossOrigin
        }
        if isLoginPath(next.path) {
            return .rejectLogin
        }
        return .follow
    }

    static func isLoginLocation(_ location: String) -> Bool {
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let url = URL(string: trimmed), url.host != nil {
            return isLoginPath(url.path)
        }
        let path = trimmed.split(separator: "?").first.map(String.init) ?? trimmed
        return isLoginPath(path)
    }

    static func prefersPlainHTTP(host: String) -> Bool {
        guard let host = normalizedHost(host) else { return false }
        if isIPAddress(host) || isLoopback(host) || isLocalHostname(host) {
            return true
        }
        return false
    }

    /// Local Network permission applies to private LAN addresses and mDNS-style
    /// names. Loopback does not raise the prompt.
    static func requiresLocalNetworkPermission(host: String) -> Bool {
        guard let host = normalizedHost(host) else { return false }
        if isLoopback(host) { return false }
        if isPrivateOrLinkLocal(host) { return true }
        if host.hasSuffix(".local") || isSingleLabel(host) { return true }
        if host.hasSuffix(".lan") || host.hasSuffix(".home")
            || host.hasSuffix(".internal") || host.hasSuffix(".home.arpa") {
            return true
        }
        return false
    }

    static func isPrivateOrLinkLocal(_ host: String) -> Bool {
        guard let host = normalizedHost(host) else { return false }
        if let mapped = ipv4Mapped(host) {
            return isPrivateIPv4(mapped)
        }
        if let octets = ipv4Octets(host) {
            return isPrivateIPv4(octets)
        }
        if isIPv6LinkLocal(host) || isIPv6UniqueLocal(host) {
            return true
        }
        return false
    }

    static func trustKey(host: String, port: Int) -> String {
        "\(normalizedHost(host) ?? host.lowercased())|\(port)"
    }

    static func shortFingerprint(_ fingerprint: String) -> String {
        let hex = fingerprint.lowercased().filter(\.isHexDigit)
        guard hex.count > 16 else { return hex }
        return "\(hex.prefix(8))…\(hex.suffix(8))"
    }

    /// `HTTPCookie` drops some host-only cookies for IP addresses, which is
    /// how Seerr sets `connect.sid`. Parse the header ourselves.
    static func parseSetCookieHeader(_ header: String) -> [SetCookie] {
        splitCombinedSetCookie(header).compactMap(parseOneSetCookie)
    }

    static func mergingCookies(
        _ existing: [String: String],
        response: HTTPURLResponse,
        url: URL
    ) -> [String: String] {
        var updated = existing
        var seen = Set<String>()
        for header in setCookieHeaders(response) {
            for cookie in parseSetCookieHeader(header) {
                seen.insert(cookie.name)
                if cookie.remove {
                    updated.removeValue(forKey: cookie.name)
                } else {
                    updated[cookie.name] = cookie.value
                }
            }
        }

        let headerFields = response.allHeaderFields.reduce(into: [String: String]()) { result, element in
            guard let key = element.key as? String,
                  let value = element.value as? String else {
                return
            }
            result[key] = value
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url) {
            if seen.contains(cookie.name) { continue }
            if cookie.value.isEmpty || cookie.expiresDate.map({ $0 <= Date() }) == true {
                updated.removeValue(forKey: cookie.name)
            } else {
                updated[cookie.name] = cookie.value
            }
        }
        return updated
    }

    private struct Parsed {
        var scheme: String?
        var host: String
        var port: Int?
        var path: String
    }

    private static func parse(_ raw: String) throws -> Parsed {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw SeerrServiceError.invalidServerURL }
        if let hash = value.firstIndex(of: "#") {
            value = String(value[..<hash])
        }
        if let query = value.firstIndex(of: "?") {
            value = String(value[..<query])
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("@") else {
            throw SeerrServiceError.invalidServerURL
        }

        var scheme: String?
        var rest = value
        if let separator = value.range(of: "://") {
            let schemeText = String(value[..<separator.lowerBound]).lowercased()
            guard schemeText == "http" || schemeText == "https" else {
                throw SeerrServiceError.invalidServerURL
            }
            scheme = schemeText
            rest = String(value[separator.upperBound...])
        }
        guard !rest.isEmpty else { throw SeerrServiceError.invalidServerURL }

        let authority: String
        let rawPath: String
        if let slash = rest.firstIndex(of: "/") {
            authority = String(rest[..<slash])
            rawPath = String(rest[slash...])
        } else {
            authority = rest
            rawPath = ""
        }
        guard !authority.isEmpty else { throw SeerrServiceError.invalidServerURL }

        let (host, port) = try splitAuthority(authority)
        guard let normalized = normalizedHost(host), !normalized.isEmpty else {
            throw SeerrServiceError.invalidServerURL
        }
        try validateHost(normalized)
        return Parsed(scheme: scheme, host: normalized, port: port, path: normalizePath(rawPath))
    }

    private static func splitAuthority(_ authority: String) throws -> (String, Int?) {
        if authority.hasPrefix("[") {
            guard let end = authority.firstIndex(of: "]") else {
                throw SeerrServiceError.invalidServerURL
            }
            let host = String(authority[authority.index(after: authority.startIndex)..<end])
            let remainder = authority[authority.index(after: end)...]
            if remainder.isEmpty { return (host, nil) }
            guard remainder.hasPrefix(":") else { throw SeerrServiceError.invalidServerURL }
            return (host, try parsePort(String(remainder.dropFirst())))
        }

        let colonCount = authority.filter { $0 == ":" }.count
        if colonCount >= 2 {
            return (authority, nil)
        }
        if let colon = authority.lastIndex(of: ":") {
            let host = String(authority[..<colon])
            let portText = String(authority[authority.index(after: colon)...])
            if !host.isEmpty, !portText.isEmpty, portText.allSatisfy(\.isNumber) {
                return (host, try parsePort(portText))
            }
        }
        return (authority, nil)
    }

    private static func parsePort(_ text: String) throws -> Int {
        guard let port = Int(text), (1...65535).contains(port) else {
            throw SeerrServiceError.invalidServerURL
        }
        return port
    }

    private static func validateHost(_ host: String) throws {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        if labels.count == 4, labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            guard ipv4Octets(host) != nil else { throw SeerrServiceError.invalidServerURL }
        }
        guard host.contains(":") else { return }
        let zoneParts = host.split(separator: "%", omittingEmptySubsequences: false)
        guard zoneParts.count <= 2 else { throw SeerrServiceError.invalidServerURL }
        let address = String(zoneParts[0])
        guard address.contains(":"),
              address.allSatisfy({ $0.isHexDigit || $0 == ":" }) else {
            throw SeerrServiceError.invalidServerURL
        }
    }

    private static func normalizePath(_ path: String) -> String {
        guard !path.isEmpty, path != "/" else { return "" }
        var resolved: [String] = []
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            if segment == "." { continue }
            if segment == ".." {
                if !resolved.isEmpty { resolved.removeLast() }
                continue
            }
            resolved.append(String(segment))
        }
        if resolved.count >= 2,
           resolved[resolved.count - 2].caseInsensitiveCompare("api") == .orderedSame,
           resolved[resolved.count - 1].caseInsensitiveCompare("v1") == .orderedSame {
            resolved.removeLast(2)
        }
        guard !resolved.isEmpty else { return "" }
        return "/" + resolved.joined(separator: "/")
    }

    private static func basePath(responsePath: String, requestedPath: String, fallback: String) -> String {
        let suffix = requestedPath.split(separator: "/").map(String.init)
        guard !suffix.isEmpty else { return fallback }
        var parts = responsePath.split(separator: "/").map(String.init)
        guard parts.count >= suffix.count else { return fallback }
        let tail = parts.suffix(suffix.count)
        let matches = zip(tail, suffix).allSatisfy {
            $0.0.caseInsensitiveCompare($0.1) == .orderedSame
        }
        guard matches else { return fallback }
        parts.removeLast(suffix.count)
        guard !parts.isEmpty else { return "" }
        return "/" + parts.joined(separator: "/")
    }

    static func makeURL(scheme: String, host: String, port: Int?, path: String) -> URL? {
        let normalized = normalizedHost(host) ?? host
        let authority: String
        if normalized.contains(":") {
            let escaped = normalized.replacingOccurrences(of: "%", with: "%25")
            authority = "[\(escaped)]"
        } else {
            authority = normalized
        }
        var string = "\(scheme)://\(authority)"
        if let port {
            string += ":\(port)"
        }
        if !path.isEmpty {
            string += path.hasPrefix("/") ? path : "/" + path
        }
        return URL(string: string)
    }

    static func normalizedHost(_ host: String?) -> String? {
        guard var host = host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else {
            return nil
        }
        if host.hasPrefix("["), host.hasSuffix("]"), host.count >= 2 {
            host = String(host.dropFirst().dropLast())
        }
        while host.hasSuffix("."), host.count > 1 {
            host.removeLast()
        }
        return host
    }

    private static func isLoginPath(_ path: String) -> Bool {
        path.split(separator: "/").last?.lowercased() == "login"
    }

    private static func isIPAddress(_ host: String) -> Bool {
        ipv4Octets(host) != nil || host.contains(":")
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host.hasPrefix("127.")
    }

    private static func isLocalHostname(_ host: String) -> Bool {
        if isLoopback(host) { return true }
        if host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home")
            || host.hasSuffix(".internal") || host.hasSuffix(".home.arpa")
            || host.hasSuffix(".localdomain") {
            return true
        }
        return isSingleLabel(host)
    }

    private static func isSingleLabel(_ host: String) -> Bool {
        !host.contains(".") && !host.contains(":")
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard let value = Int(part), (0...255).contains(value), part.allSatisfy(\.isNumber) else {
                return nil
            }
            octets.append(value)
        }
        return octets
    }

    private static func isPrivateIPv4(_ octets: [Int]) -> Bool {
        switch octets[0] {
        case 10: return true
        case 172: return (16...31).contains(octets[1])
        case 192: return octets[1] == 168
        case 169: return octets[1] == 254
        default: return false
        }
    }

    private static func ipv4Mapped(_ host: String) -> [Int]? {
        guard let range = host.range(of: "::ffff:") else { return nil }
        return ipv4Octets(String(host[range.upperBound...]))
    }

    private static func isIPv6LinkLocal(_ host: String) -> Bool {
        guard let value = firstHextet(host) else { return false }
        return (0xfe80...0xfebf).contains(value)
    }

    private static func isIPv6UniqueLocal(_ host: String) -> Bool {
        guard let value = firstHextet(host) else { return false }
        return value & 0xfe00 == 0xfc00
    }

    private static func firstHextet(_ host: String) -> UInt16? {
        let head = host.split(separator: ":", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        return UInt16(head, radix: 16)
    }

    private static let queryValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func percentEncodedQueryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? value
    }

    private static func setCookieHeaders(_ response: HTTPURLResponse) -> [String] {
        if let combined = response.value(forHTTPHeaderField: "Set-Cookie"),
           !combined.isEmpty {
            return [combined]
        }
        var headers: [String] = []
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String,
                  key.caseInsensitiveCompare("Set-Cookie") == .orderedSame else {
                continue
            }
            if let string = value as? String, !string.isEmpty {
                headers.append(string)
            } else if let list = value as? [String] {
                headers.append(contentsOf: list)
            }
        }
        return headers
    }

    private static func splitCombinedSetCookie(_ header: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var index = header.startIndex
        while index < header.endIndex {
            if header[index] == "," {
                let after = header[header.index(after: index)...]
                if startsCookie(after) {
                    parts.append(current)
                    current = ""
                    index = header.index(after: index)
                    while index < header.endIndex, header[index] == " " {
                        index = header.index(after: index)
                    }
                    continue
                }
            }
            current.append(header[index])
            index = header.index(after: index)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(current)
        }
        return parts
    }

    private static func startsCookie<S: StringProtocol>(_ rest: S) -> Bool {
        var index = rest.startIndex
        while index < rest.endIndex, rest[index] == " " {
            index = rest.index(after: index)
        }
        let nameStart = index
        while index < rest.endIndex, isCookieToken(rest[index]) {
            index = rest.index(after: index)
        }
        return index > nameStart && index < rest.endIndex && rest[index] == "="
    }

    private static func isCookieToken(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "!#$%&'*+-.^_`|~".contains(character)
    }

    private static func parseOneSetCookie(_ raw: String) -> SetCookie? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(of: "=") else { return nil }
        let name = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, isCookieName(name) else { return nil }
        let after = trimmed[trimmed.index(after: separator)...]
        let valueEnd = after.firstIndex(of: ";") ?? after.endIndex
        let value = String(after[..<valueEnd])
        let attributes = after[valueEnd...].lowercased()
        let remove = value.isEmpty
            || attributes.contains("max-age=0")
            || attributes.contains("max-age=-")
        return SetCookie(name: name, value: value, remove: remove)
    }

    private static func isCookieName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy(isCookieToken)
    }
}
