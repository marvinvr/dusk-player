import Foundation

/// The Home calls (02 §4) that need more than `JellyfinAPI.resume` /
/// `nextUp` offer: one library at a time (`parentId`), and the user's
/// `Configuration` as the server sent it, for Hide Row.
extension JellyfinAPI {
    /// Partly played titles of one library, newest first.
    static func resume(parentID: String, limit: Int, fields: [JellyfinItemField]) -> JellyfinRequest<Items> {
        var query = JellyfinQuery()
        query.add("parentId", parentID)
        query.add("mediaTypes", list: [JellyfinMediaType.video])
        query.add("limit", limit)
        query.add("fields", list: fields)
        return .json(.get, "/UserItems/Resume", query: query.items, isUserScoped: true) { result, _ in
            try JellyfinItemQuery.validate(result.items, limit: limit)
        }
    }

    /// The next episode of each show in progress in one library, most
    /// recently watched show first. Resumable episodes are Resume's.
    static func nextUp(parentID: String, limit: Int, fields: [JellyfinItemField]) -> JellyfinRequest<Items> {
        var query = JellyfinQuery()
        query.add("parentId", parentID)
        query.add("limit", limit)
        query.add("enableResumable", false)
        query.add("enableRewatching", false)
        query.add("fields", list: fields)
        return .json(.get, "/Shows/NextUp", query: query.items, isUserScoped: true) { result, _ in
            try JellyfinItemQuery.validate(result.items, includeItemTypes: [.episode], limit: limit)
        }
    }

    /// `/Users/Me` with `Configuration` kept whole. `POST /Users/Configuration`
    /// replaces the entire object and resets what it leaves out, and the
    /// typed `JellyfinUserConfigurationDTO` does not carry every field
    /// (`CastReceiverId`, `EnableLocalPassword`, …).
    static func currentUserConfiguration() -> JellyfinRequest<JellyfinJSONObject> {
        JellyfinRequest(path: "/Users/Me") { data, context in
            let user = try JellyfinJSON.decode(JellyfinJSONObject.self, from: data)
            if let userID = context.userID, case .string(let id)? = user["Id"], !JellyfinID.same(id, userID) {
                throw JellyfinError.unexpectedResponse("token belongs to another user")
            }
            guard case .object(let configuration)? = user["Configuration"] else {
                throw JellyfinError.unexpectedResponse("user without Configuration")
            }
            return configuration
        }
    }

    /// Writes back a `Configuration` read with `currentUserConfiguration()`.
    /// Needs `Policy.EnableUserPreferenceAccess`.
    static func updateUserConfiguration(raw configuration: JellyfinJSONObject) -> JellyfinRequest<JellyfinNoContent> {
        .noContent(.post, "/Users/Configuration", isUserScoped: true, body: .fixed(JellyfinJSONValue.object(configuration)))
    }
}

typealias JellyfinJSONObject = [String: JellyfinJSONValue]

/// Any JSON value, decoded and encoded without loss, so a read-modify-write
/// of a server object sends back every field it did not touch. Integers stay
/// integers.
enum JellyfinJSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JellyfinJSONValue])
    case object(JellyfinJSONObject)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JellyfinJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode(JellyfinJSONObject.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// The strings of an array value; nil for anything else.
    var strings: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap { if case .string(let value) = $0 { value } else { nil } }
    }
}
