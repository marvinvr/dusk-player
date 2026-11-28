import Foundation

/// The `ArtworkRef.locator` form for a Jellyfin image
/// (docs/jellyfin/04-architecture.md §10):
///
///     jf:<itemID>:<type>:<index>:<tag>
///
/// The item id is the one that *owns* the image (an episode's show poster names
/// the series), normalised to 32 lower-case hex characters. The tag goes into
/// the image URL, which makes the URL an immutable cache key (03 §10.4). Only
/// the Jellyfin image provider reads a locator; everything else treats it as
/// an opaque string, exactly like a Plex path.
struct JellyfinArtworkLocator: Hashable, Sendable {
    static let scheme = "jf"

    let itemID: String
    let type: JellyfinImageType
    /// `Backdrop/0`, `Backdrop/1`, …; 0 for every single-image type.
    let index: Int
    let tag: String?

    init(itemID: String, type: JellyfinImageType, index: Int = 0, tag: String?) {
        self.itemID = JellyfinID.normalized(itemID)
        self.type = type
        self.index = max(0, index)
        self.tag = tag?.nilIfEmpty
    }

    /// Ids and tags are hex and image types are words, so `:` never occurs in
    /// a field; an empty tag stays an empty last field.
    var locator: String {
        "\(Self.scheme):\(itemID):\(type.rawValue):\(index):\(tag ?? "")"
    }

    init?(locator: String) {
        let fields = locator.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 5, fields[0] == Self.scheme, !fields[1].isEmpty, !fields[2].isEmpty,
              let index = Int(fields[3]), index >= 0 else { return nil }
        self.init(itemID: fields[1], type: JellyfinImageType(rawValue: fields[2]), index: index, tag: fields[4])
    }

    /// An image the item says exists. Jellyfin answers `404` for a type the
    /// item has no tag for (03 §10.4), so there is no tagless ref: no tag, no
    /// image.
    static func path(itemID: String?, type: JellyfinImageType, index: Int = 0, tag: String?) -> String? {
        guard let itemID = itemID?.nilIfEmpty, let tag = tag?.nilIfEmpty else { return nil }
        return JellyfinArtworkLocator(itemID: itemID, type: type, index: index, tag: tag).locator
    }
}
