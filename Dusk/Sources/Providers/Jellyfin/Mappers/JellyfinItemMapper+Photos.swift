import Foundation

/// Photo library rows (02 §13).
extension JellyfinItemMapper {
    /// `PhotoAlbum` and plain `Folder` are albums, `Photo` a photo, `Video` a
    /// clip; anything else has no kind and is dropped by the caller.
    ///
    /// - `thumb` is the item's Primary image. The server applies the EXIF
    ///   orientation to it, so the viewer shows it as is; there is no Plex
    ///   style `partKey` (the viewer then asks for the Primary image at screen
    ///   size).
    /// - `originallyAvailableAt` is the day of `PremiereDate` in the device's
    ///   time zone. The EXIF time has no zone; the server reads it in its own
    ///   zone and stores it as UTC (EXIF 09:15 on a server in Zurich becomes
    ///   07:15Z), so the device's zone, usually the server's, gives back the
    ///   camera-local day Plex shows. A photo without an EXIF date has none,
    ///   and the grid falls back to `DateCreated`.
    /// - Width and height are the stored pixels, before rotation, as on Plex.
    static func photoItem(_ dto: JellyfinItemDTO, serverID: String?) -> PhotoItem {
        let kind: PhotoItem.Kind?
        switch dto.type {
        case let type? where type.matches(.photoAlbum) || type.matches(.folder): kind = .album
        case let type? where type.matches(.photo): kind = .photo
        case let type? where type.matches(.video): kind = .clip
        default: kind = nil
        }
        let itemID = JellyfinID.normalized(dto.id)
        return PhotoItem(
            serverID: normalizedServerID(serverID),
            itemID: itemID,
            key: itemPath(itemID),
            kind: kind,
            title: dto.name ?? "",
            thumb: JellyfinArtworkLocator.path(itemID: itemID, type: .primary, tag: dto.imageTag(.primary)),
            composite: nil,
            originallyAvailableAt: photoDay(dto.premiereDate),
            addedAt: epochSeconds(dto.dateCreated),
            year: dto.productionYear,
            duration: kind == .clip ? duration(dto) : nil,
            width: dto.width,
            height: dto.height,
            partKey: nil,
            make: dto.cameraMake?.nilIfEmpty,
            model: dto.cameraModel?.nilIfEmpty,
            places: []
        )
    }

    /// `YYYY-MM-DD` of the day the timestamp falls on in `timeZone`. Unlike
    /// `airDate` it never rounds: a photo taken at 19:10 belongs to that day.
    static func photoDay(_ date: JellyfinDate?, in timeZone: TimeZone = .autoupdatingCurrent) -> String? {
        guard let date = date?.date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
