import Foundation

/// Sends requests for `JellyfinClient`. Tests inject a stub. The shared
/// provider transport (timeouts, session delegate) is wired in when the
/// Jellyfin provider is assembled.
protocol JellyfinTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

/// A `URLSession` as transport. A wrapper rather than a conformance on
/// `URLSession`, so no `URLSession` call elsewhere in the app changes overload.
struct JellyfinURLSessionTransport: JellyfinTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

/// The signed-in side of a client: the access token and whose it is.
struct JellyfinCredentials: Hashable, Sendable {
    let accessToken: String
    let userID: String
}

/// HTTP core for one Jellyfin server and, once signed in, one user.
///
/// - One header form only: `Authorization: MediaBrowser …`
///   (`JellyfinAuthorization`). URLs handed to a player or downloader carry
///   `ApiKey=` (`authenticatedURL`).
/// - User-scoped requests get `userId=` from the credentials.
/// - Status codes map to `JellyfinError`; bodies are decoded and checked
///   against what was asked for, because the server answers `200` with a
///   default result when it does not understand a parameter.
///
/// A value type: signing in returns a new client (`signedIn(_:)`).
struct JellyfinClient: Sendable {
    let baseURL: URL
    let identity: JellyfinClientIdentity
    let credentials: JellyfinCredentials?
    let transport: any JellyfinTransport

    /// `baseURL` may include a path prefix (a reverse proxy at `/jellyfin`).
    init(
        baseURL: URL,
        identity: JellyfinClientIdentity,
        credentials: JellyfinCredentials? = nil,
        transport: any JellyfinTransport = JellyfinURLSessionTransport()
    ) {
        self.baseURL = baseURL
        self.identity = identity
        self.credentials = credentials
        self.transport = transport
    }

    func signedIn(_ credentials: JellyfinCredentials?) -> JellyfinClient {
        JellyfinClient(baseURL: baseURL, identity: identity, credentials: credentials, transport: transport)
    }

    var context: JellyfinRequestContext {
        JellyfinRequestContext(userID: credentials?.userID)
    }

    // MARK: Sending

    func send<Response>(_ request: JellyfinRequest<Response>) async throws -> Response {
        let urlRequest = try makeURLRequest(for: request)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw JellyfinError.transport(code: error.code.rawValue, description: error.localizedDescription)
        } catch let error as JellyfinError {
            throw error
        } catch {
            throw JellyfinError.transport(code: 0, description: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError.transport(code: 0, description: "The Jellyfin server sent no HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinError.status(http.statusCode, body: data)
        }
        return try request.decode(data, context)
    }

    /// The `URLRequest` `send` would issue. Pure; used by tests.
    func makeURLRequest<Response>(for request: JellyfinRequest<Response>) throws -> URLRequest {
        if request.authentication == .token, credentials == nil {
            throw JellyfinError.notAuthenticated
        }
        var query = request.query
        if request.isUserScoped {
            guard let userID = credentials?.userID else { throw JellyfinError.notAuthenticated }
            if !query.contains(where: { $0.name.caseInsensitiveCompare("userId") == .orderedSame }) {
                query.append(URLQueryItem(name: "userId", value: userID))
            }
        }
        let url = try makeURL(path: request.path, query: query)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        if let timeout = request.timeout {
            urlRequest.timeoutInterval = timeout
        }
        let token = request.authentication == .token ? credentials?.accessToken : nil
        urlRequest.setValue(JellyfinAuthorization.headerValue(identity: identity, token: token),
                            forHTTPHeaderField: JellyfinAuthorization.headerName)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body = request.body {
            urlRequest.httpBody = try JellyfinJSON.encode(body.make(context))
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return urlRequest
    }

    // MARK: URLs

    /// `baseURL` + `path` + query. Query values are percent-encoded except for
    /// unreserved characters and `,` (list separator), so `&`, `=`, `+`, `#`
    /// and `|` inside a value can never split or change a parameter.
    func makeURL(path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme != nil, components.host != nil else {
            throw JellyfinError.invalidURL
        }
        let prefix = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        let relative = path.hasPrefix("/") ? path : "/" + path
        guard let encodedPath = relative.addingPercentEncoding(withAllowedCharacters: Self.pathAllowed) else {
            throw JellyfinError.invalidURL
        }
        components.percentEncodedPath = prefix + encodedPath
        components.percentEncodedQuery = query.isEmpty ? nil : query.map { item in
            let name = item.name.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? item.name
            guard let value = item.value else { return name }
            return name + "=" + (value.addingPercentEncoding(withAllowedCharacters: Self.queryAllowed) ?? "")
        }.joined(separator: "&")
        guard let url = components.url else { throw JellyfinError.invalidURL }
        return url
    }

    /// A URL for AVPlayer, VLCKit or a download task, which cannot send the
    /// `Authorization` header: the token rides as `ApiKey=` (the only query
    /// carrier the server accepts; `api_key` is `401`). Never log it
    /// unredacted (`JellyfinRedaction`).
    func authenticatedURL(path: String, query: [URLQueryItem] = []) throws -> URL {
        guard let token = credentials?.accessToken else { throw JellyfinError.notAuthenticated }
        let cleaned = query.filter { $0.name.caseInsensitiveCompare("ApiKey") != .orderedSame }
        return try makeURL(path: path, query: cleaned + [URLQueryItem(name: "ApiKey", value: token)])
    }

    /// Resolves a server-relative URL the server handed out (`TranscodingUrl`,
    /// `DeliveryUrl`: path plus query, token already embedded) against the base
    /// URL, keeping a reverse-proxy path prefix. Absolute URLs pass through.
    func resolveServerURL(_ serverURL: String) throws -> URL {
        if let absolute = URL(string: serverURL), absolute.scheme != nil {
            return absolute
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let relative = URLComponents(string: serverURL.hasPrefix("/") ? serverURL : "/" + serverURL) else {
            throw JellyfinError.invalidURL
        }
        let prefix = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = prefix + relative.percentEncodedPath
        components.percentEncodedQuery = relative.percentEncodedQuery
        guard let url = components.url else { throw JellyfinError.invalidURL }
        return url
    }

    private static let pathAllowed: CharacterSet = {
        var set = JellyfinAuthorization.unreserved
        set.insert(charactersIn: "/")
        return set
    }()

    private static let queryAllowed: CharacterSet = {
        var set = JellyfinAuthorization.unreserved
        set.insert(charactersIn: ",")
        return set
    }()
}
