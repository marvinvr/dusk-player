import Foundation

enum JellyfinHTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case delete = "DELETE"
}

/// What the client knows when it finishes a request: who is signed in.
struct JellyfinRequestContext: Sendable {
    let userID: String?
}

/// A JSON request body, built once the signed-in user is known so bodies
/// that carry `UserId` get it from the same place as the query. A struct
/// rather than a bare closure so trailing closures on the request factories
/// always mean `validate`.
struct JellyfinRequestBody: Sendable {
    let make: @Sendable (JellyfinRequestContext) -> any Encodable & Sendable

    init(_ make: @escaping @Sendable (JellyfinRequestContext) -> any Encodable & Sendable) {
        self.make = make
    }

    static func fixed(_ value: any Encodable & Sendable) -> JellyfinRequestBody {
        JellyfinRequestBody { _ in value }
    }
}

/// `204` and other bodies Dusk ignores.
struct JellyfinNoContent: Hashable, Sendable {}

/// One Jellyfin call: path, query, optional JSON body and how to turn the
/// answer into `Response`, including the shape checks for that answer.
///
/// Requests are pure values; `JellyfinClient` adds the base URL, the
/// `Authorization` header and, for user-scoped calls, `userId=`. Endpoints are
/// built in `JellyfinAPI`.
struct JellyfinRequest<Response: Sendable>: Sendable {
    enum Authentication: Sendable {
        /// Public endpoint (`/System/Info/Public`, `/QuickConnect/*`,
        /// `/Users/AuthenticateByName`): the identity header without a token.
        case none
        /// Needs the access token.
        case token
    }

    var method: JellyfinHTTPMethod
    /// Server-relative, starting with `/`. Paths are case-insensitive on the
    /// server; the modern forms are used (`/UserViews`, `/UserItems/…`), the
    /// legacy `/Users/{id}/…` routes are expected to disappear (03 §10.7).
    var path: String
    var query: [URLQueryItem]
    var authentication: Authentication
    /// Adds `userId=` from the signed-in user. Without it `UserData` is missing
    /// from items (02 §0).
    var isUserScoped: Bool
    var timeout: TimeInterval?
    var body: JellyfinRequestBody?
    let decode: @Sendable (Data, JellyfinRequestContext) throws -> Response

    init(
        method: JellyfinHTTPMethod = .get,
        path: String,
        query: [URLQueryItem] = [],
        authentication: Authentication = .token,
        isUserScoped: Bool = false,
        timeout: TimeInterval? = nil,
        body: JellyfinRequestBody? = nil,
        decode: @escaping @Sendable (Data, JellyfinRequestContext) throws -> Response
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.authentication = authentication
        self.isUserScoped = isUserScoped
        self.timeout = timeout
        self.body = body
        self.decode = decode
    }
}

extension JellyfinRequest {
    /// A JSON response decoded into `Response`, then checked by `validate`.
    static func json(
        _ method: JellyfinHTTPMethod = .get,
        _ path: String,
        query: [URLQueryItem] = [],
        authentication: Authentication = .token,
        isUserScoped: Bool = false,
        body: JellyfinRequestBody? = nil,
        validate: @escaping @Sendable (Response, JellyfinRequestContext) throws -> Void = { _, _ in }
    ) -> JellyfinRequest<Response> where Response: Decodable {
        JellyfinRequest(
            method: method, path: path, query: query, authentication: authentication,
            isUserScoped: isUserScoped, body: body
        ) { data, context in
            let value = try JellyfinJSON.decode(Response.self, from: data)
            try validate(value, context)
            return value
        }
    }
}

extension JellyfinRequest where Response == JellyfinNoContent {
    /// A call whose body is ignored (`204`, or a `200` Dusk does not need).
    static func noContent(
        _ method: JellyfinHTTPMethod,
        _ path: String,
        query: [URLQueryItem] = [],
        authentication: Authentication = .token,
        isUserScoped: Bool = false,
        body: JellyfinRequestBody? = nil
    ) -> JellyfinRequest<JellyfinNoContent> {
        JellyfinRequest(
            method: method, path: path, query: query, authentication: authentication,
            isUserScoped: isUserScoped, body: body
        ) { _, _ in JellyfinNoContent() }
    }
}

enum JellyfinJSON {
    /// Dates and ticks decode through `JellyfinDate` / `JellyfinTicks`, so the
    /// decoder needs no date strategy.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw JellyfinError.decoding(describe(error, type: type))
        } catch {
            throw JellyfinError.decoding("\(type): \(error.localizedDescription)")
        }
    }

    static func encode(_ value: any Encodable) throws -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw JellyfinError.decoding("Could not encode \(type(of: value)): \(error.localizedDescription)")
        }
    }

    private static func describe<T>(_ error: DecodingError, type: T.Type) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "\(type): missing \(key.stringValue) at \(path(context))"
        case .typeMismatch(let expected, let context):
            return "\(type): expected \(expected) at \(path(context))"
        case .valueNotFound(let expected, let context):
            return "\(type): null \(expected) at \(path(context))"
        case .dataCorrupted(let context):
            return "\(type): corrupted at \(path(context))"
        @unknown default:
            return "\(type): \(error.localizedDescription)"
        }
    }
}

/// Builds query items from typed values. Booleans are `true` / `false`,
/// lists comma-separated.
struct JellyfinQuery: Sendable {
    private(set) var items: [URLQueryItem] = []

    mutating func add(_ name: String, _ value: String?) {
        guard let value else { return }
        items.append(URLQueryItem(name: name, value: value))
    }

    mutating func add(_ name: String, _ value: Bool?) {
        add(name, value.map { $0 ? "true" : "false" })
    }

    mutating func add(_ name: String, _ value: Int?) {
        add(name, value.map(String.init))
    }

    mutating func add(_ name: String, list: [String], separator: String = ",") {
        guard !list.isEmpty else { return }
        add(name, list.joined(separator: separator))
    }

    mutating func add<E: JellyfinOpenEnum>(_ name: String, list: [E]) {
        add(name, list: list.map(\.rawValue))
    }
}
