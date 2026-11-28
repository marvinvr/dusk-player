import Foundation

/// Jellyfin codec and container names → the domain's one lower-case
/// vocabulary (docs/jellyfin/04-architecture.md §4.2), the names
/// `StreamResolver`, the track pickers and the quality labels already match.
///
/// Jellyfin reports ffprobe's names, and a few of them differ from what the
/// rest of Dusk expects (02 §9): `PGSSUB` is `pgs`, `subrip` is `srt`,
/// `dvdsub` is `vobsub`, and the container of an `.mp4` can come back as
/// `mov`. Every Jellyfin mapper goes through this table; `StreamResolver`
/// never sees a raw server string.
enum JellyfinCodecAliases {
    /// Names that are not the canonical spelling. Anything not listed is
    /// already canonical once lower-cased (`hevc`, `h264`, `av1`, `eac3`,
    /// `truehd`, `dts`, `aac`, `ac3`, `flac`, `ass`, `mov_text`, …).
    private static let codecAliases: [String: String] = [
        // video
        "h265": "hevc",
        "avc": "h264",
        "avc1": "h264",
        "mpeg2": "mpeg2video",
        // audio
        "dca": "dts",
        "e-ac-3": "eac3",
        "ac-3": "ac3",
        // subtitles
        "subrip": "srt",
        "pgssub": "pgs",
        "hdmv_pgs_subtitle": "pgs",
        "dvdsub": "vobsub",
        "dvd_subtitle": "vobsub",
        "webvtt": "vtt",
    ]

    static func codec(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespaces).lowercased().nilIfEmpty else { return nil }
        return codecAliases[value] ?? value
    }

    /// The container as Plex names it: `mkv`, `mp4`, `mov`, `mpegts`, `avi`, …
    ///
    /// ffprobe sometimes answers with its whole format list
    /// (`mov,mp4,m4a,3gp,3g2,mj2`, `matroska,webm`), and with `mov` for an
    /// `.mp4`; the file extension decides between the members of one list.
    static func container(_ raw: String?, path: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespaces).lowercased().nilIfEmpty else { return nil }
        let fileExtension = path.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""
        let members = Set(value.split(separator: ",").map { String($0) })

        if !members.isDisjoint(with: ["mov", "mp4", "m4v", "m4a", "3gp", "3g2", "mj2"]) {
            if ["mp4", "m4v", "mov"].contains(fileExtension) { return fileExtension }
            return members.count == 1 ? value : "mp4"
        }
        if !members.isDisjoint(with: ["matroska", "webm", "mkv"]) {
            return fileExtension == "webm" ? "webm" : "mkv"
        }
        if !members.isDisjoint(with: ["ts", "mpegts", "m2ts", "mts"]) {
            return "mpegts"
        }
        return value
    }
}
