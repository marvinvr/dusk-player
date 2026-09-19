import Foundation

extension CodingUserInfoKey {
    /// Machine identifier of the Plex server a payload was fetched from.
    ///
    /// `ServerPool.decoder(for:)` stamps it onto the decoder, so every model's
    /// `init(from:)` can record which server it came from — including models
    /// nested several levels deep, which no post-decode copy pass could reach
    /// without rewriting the whole tree.
    static let duskServerID = CodingUserInfoKey(rawValue: "com.dusk-player.plex.serverID")!
}

extension Decoder {
    /// The server this payload belongs to, or nil when the decoder was not
    /// built by `ServerPool` (offline metadata caches, ad-hoc decodes).
    var duskServerID: String? {
        (userInfo[.duskServerID] as? String)?.nilIfEmpty
    }
}

/// Identity of a library item that is unique across servers.
///
/// Plex rating keys are per-server counters, so two servers routinely hand out
/// the same `ratingKey` for completely different media. Everything that keys,
/// compares, or routes to an item must therefore carry the server too.
///
/// `serverID` is optional because items can still arrive from a decoder with no
/// server stamped on it (an offline metadata cache, for example). Such an item
/// is only ever equal to another equally unstamped one.
struct PlexItemID: Hashable, Codable, Sendable {
    let serverID: String?
    let ratingKey: String

    init(serverID: String?, ratingKey: String) {
        self.serverID = serverID?.nilIfEmpty
        self.ratingKey = ratingKey
    }
}

extension PlexItemID: CustomStringConvertible {
    /// Round-trippable `"<serverID>|<ratingKey>"` form. Rating keys are numeric
    /// on every Plex server, so the first `|` is always the separator.
    var storageKey: String {
        guard let serverID else { return ratingKey }
        return "\(serverID)|\(ratingKey)"
    }

    init?(storageKey: String) {
        guard let separator = storageKey.firstIndex(of: "|") else {
            guard !storageKey.isEmpty else { return nil }
            self.init(serverID: nil, ratingKey: storageKey)
            return
        }
        let serverID = String(storageKey[storageKey.startIndex..<separator])
        let ratingKey = String(storageKey[storageKey.index(after: separator)...])
        guard !ratingKey.isEmpty else { return nil }
        self.init(serverID: serverID, ratingKey: ratingKey)
    }

    var description: String { storageKey }
}
