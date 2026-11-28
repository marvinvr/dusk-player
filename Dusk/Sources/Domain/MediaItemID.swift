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
/// the same `itemID` for completely different media. Everything that keys,
/// compares, or routes to an item must therefore carry the server too.
///
/// `serverID` is optional because items can still arrive from a decoder with no
/// server stamped on it (an offline metadata cache, for example). Such an item
/// is only ever equal to another equally unstamped one.
struct MediaItemID: Hashable, Codable, Sendable {
    let serverID: String?
    let itemID: String

    enum CodingKeys: String, CodingKey {
        case serverID, itemID = "ratingKey"
    }

    init(serverID: String?, itemID: String) {
        self.serverID = serverID?.nilIfEmpty
        self.itemID = itemID
    }
}

extension MediaItemID: CustomStringConvertible {
    /// Round-trippable `"<serverID>|<itemID>"` form. Server ids never contain
    /// `|` (Plex machine identifiers and Jellyfin server ids are hex), so the
    /// first `|` is always the separator.
    var storageKey: String {
        guard let serverID else { return itemID }
        return "\(serverID)|\(itemID)"
    }

    init?(storageKey: String) {
        guard let separator = storageKey.firstIndex(of: "|") else {
            guard !storageKey.isEmpty else { return nil }
            self.init(serverID: nil, itemID: storageKey)
            return
        }
        let serverID = String(storageKey[storageKey.startIndex..<separator])
        let itemID = String(storageKey[storageKey.index(after: separator)...])
        guard !itemID.isEmpty else { return nil }
        self.init(serverID: serverID, itemID: itemID)
    }

    var description: String { storageKey }
}
