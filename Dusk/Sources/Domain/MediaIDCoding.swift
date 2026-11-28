import Foundation

/// Version, part, stream and marker ids are opaque strings in the app
/// (docs/jellyfin/04-architecture.md §4.2). Plex sends them as JSON numbers
/// and Dusk has always persisted them as numbers (`downloads.json`, the
/// converted-media blob), so decoding accepts a number or a string and
/// encoding writes a canonical integer back as a number. Anything else is
/// written as a string.
extension KeyedDecodingContainer {
    func decodeID(forKey key: Key) throws -> String {
        do {
            return String(try decode(Int.self, forKey: key))
        } catch DecodingError.typeMismatch {
            return try decode(String.self, forKey: key)
        }
    }

    func decodeIDIfPresent(forKey key: Key) throws -> String? {
        do {
            return try decodeIfPresent(Int.self, forKey: key).map(String.init)
        } catch DecodingError.typeMismatch {
            return try decodeIfPresent(String.self, forKey: key)
        }
    }
}

extension KeyedEncodingContainer {
    mutating func encodeID(_ id: String, forKey key: Key) throws {
        if let number = Int(id), String(number) == id {
            try encode(number, forKey: key)
        } else {
            try encode(id, forKey: key)
        }
    }

    mutating func encodeIDIfPresent(_ id: String?, forKey key: Key) throws {
        guard let id else { return }
        try encodeID(id, forKey: key)
    }
}

/// Orders ids the way their integer values did when they were `Int`
/// (numbers by value, before any non-numeric id); non-numeric ids compare as
/// strings. Use wherever an id order used to be numeric ("the newest stream").
func mediaIDPrecedes(_ lhs: String, _ rhs: String) -> Bool {
    switch (Int(lhs), Int(rhs)) {
    case let (left?, right?): return left < right
    case (.some, nil): return true
    case (nil, .some): return false
    case (nil, nil): return lhs < rhs
    }
}
