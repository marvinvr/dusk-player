import Foundation

/// Loss-free JSON tree: unknown keys and their values survive a decode/encode
/// round-trip.
///
/// This exists because the Plex account-level `experience` setting is a single
/// JSON blob that Dusk must rewrite in full (see `PlexService+LibraryOrder`).
/// Decoding it into a strict `Codable` struct would silently drop every key we
/// do not model — `homeSettings`, `reminders`, `autoPinnedProviders`,
/// `schemaVersion`, other Plex clients' future additions — and the next write
/// would wipe the user's Plex Web customization.
///
/// Invariants that matter for that blob:
/// - Integers stay integers, so `schemaVersion: 12` is never rewritten as
///   `12.0`. `JSONSerialization` round-trips are not trusted for this.
/// - Every key of every object is preserved. Key *order* is not preserved
///   (Swift dictionaries are unordered); encoding uses `.sortedKeys` so output
///   is at least deterministic. Plex Web parses the blob with `JSON.parse`, so
///   key order carries no meaning.
/// - Array order *is* preserved, which is what makes `pinnedSources` usable as
///   an ordered list.
indirect enum DuskJSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([DuskJSONValue])
    case object([String: DuskJSONValue])

    // MARK: - Read views

    var objectValue: [String: DuskJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [DuskJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Tolerant boolean read: plex.tv is inconsistent about whether flags come
    /// back as JSON booleans, `0`/`1`, or `"true"`/`"false"`.
    var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .int(let value):
            if value == 0 { return false }
            if value == 1 { return true }
            return nil
        case .string(let value):
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        default:
            return nil
        }
    }

    /// `"3"` for both `.string("3")` and `.int(3)` — Plex is inconsistent about
    /// whether `directoryID` is a string or a number.
    var stringOrNumberValue: String? {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return String(value)
        case .double(let value):
            // Whole doubles are section ids that arrived through a lossy parser.
            if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
                return String(Int(value))
            }
            return String(value)
        default:
            return nil
        }
    }

    /// Reads a key of an object; setting is a no-op on anything that is not an
    /// object, so callers never silently turn a scalar into a dictionary.
    /// Assigning `nil` removes the key.
    subscript(key: String) -> DuskJSONValue? {
        get {
            guard case .object(let object) = self else { return nil }
            return object[key]
        }
        set {
            guard case .object(var object) = self else { return }
            object[key] = newValue
            self = .object(object)
        }
    }

    // MARK: - Codable

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer() {
            if container.decodeNil() {
                self = .null
                return
            }
            // Bool before Int, Int before Double: JSONDecoder is strict about
            // each of these, so the first success is the faithful reading and
            // `schemaVersion: 12` stays an Int.
            if let value = try? container.decode(Bool.self) {
                self = .bool(value)
                return
            }
            if let value = try? container.decode(Int.self) {
                self = .int(value)
                return
            }
            if let value = try? container.decode(Double.self) {
                self = .double(value)
                return
            }
            if let value = try? container.decode(String.self) {
                self = .string(value)
                return
            }
        }

        if var container = try? decoder.unkeyedContainer() {
            var values: [DuskJSONValue] = []
            while !container.isAtEnd {
                values.append(try container.decode(DuskJSONValue.self))
            }
            self = .array(values)
            return
        }

        if let container = try? decoder.container(keyedBy: DuskJSONCodingKey.self) {
            var object: [String: DuskJSONValue] = [:]
            for key in container.allKeys {
                object[key.stringValue] = try container.decode(DuskJSONValue.self, forKey: key)
            }
            self = .object(object)
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Unsupported JSON value"
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .int(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .double(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values {
                try container.encode(value)
            }
        case .object(let object):
            var container = encoder.container(keyedBy: DuskJSONCodingKey.self)
            for (key, value) in object {
                guard let codingKey = DuskJSONCodingKey(stringValue: key) else { continue }
                try container.encode(value, forKey: codingKey)
            }
        }
    }

    // MARK: - Serialization helpers

    /// Deterministic encoder used for everything that is written back to
    /// plex.tv. `.sortedKeys` keeps repeated writes byte-identical (easier to
    /// diff when debugging) and `.withoutEscapingSlashes` keeps provider icon
    /// URLs readable inside the doubly-stringified payload.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Decodes a JSON document. Returns nil when the text is not valid JSON —
    /// used for the doubly-encoded `experience` setting, where an unparseable
    /// value means "treat the account as never customized", not "fail".
    static func decode(jsonString: String) -> DuskJSONValue? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DuskJSONValue.self, from: data)
    }

    /// Encodes to a compact JSON string. Only objects and arrays are supported
    /// as the top level, which is all the Plex payloads need.
    func jsonString() throws -> String {
        let data = try Self.makeEncoder().encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(codingPath: [], debugDescription: "JSON was not valid UTF-8")
            )
        }
        return string
    }
}

/// Dynamic key so arbitrary object keys survive decoding.
struct DuskJSONCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
