import AVFoundation
import Foundation
import OSLog

private let atmosSignalingLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "AtmosSignaling"
)

/// Restores Dolby Atmos signaling on Plex's fragmented-MP4 HLS remux.
///
/// Plex's transcoder copies an E-AC-3 + JOC (Dolby Atmos) bitstream into
/// fMP4 segments intact, but writes a 13-byte `dec3` box without the
/// `flag_ec3_extension_type_a` / `complexity_index_type_a` trailer. AVFoundation
/// derives the track's format from that box, so it sees plain 5.1 E-AC-3 and
/// never offers the Atmos (`ec+3`) layer — no Atmos over HDMI, no multichannel
/// spatial audio. (MPEG-TS remuxes are unaffected: AVFoundation reads the
/// signaling from the bitstream there, but HEVC cannot ride MPEG-TS HLS.)
///
/// Only use it for streams Plex reports as Atmos: the patch asserts JOC, and
/// a plain E-AC-3 track must not be labelled Atmos.
///
/// `RemuxHLSLoader` sits in front of the stream as an
/// `AVAssetResourceLoader` delegate. It rewrites the playlists so only the
/// init segment (`EXT-X-MAP`) comes back through it, patches that segment's
/// `dec3`, and points every media segment straight at the server — segment
/// traffic never passes through the app.
enum EAC3JOCSignaling {
    /// Complexity index written into the restored trailer. Plex does not
    /// surface the bitstream's value; 16 is what Dolby's encoders emit for
    /// streaming DD+ Atmos, and what ffmpeg reproduces from those streams.
    static let defaultComplexityIndex: UInt8 = 16

    private static let containerHeaderPadding: [String: Int] = [
        "moov": 0, "trak": 0, "mdia": 0, "minf": 0, "stbl": 0,
        "stsd": 8,    // full box header + entry count
        "ec-3": 28,   // AudioSampleEntry fields
    ]

    /// Returns the init segment with the JOC trailer appended to every
    /// `dec3` box that lacks one (and every enclosing box resized), or nil
    /// when there was nothing to patch or the data is not a parseable MP4.
    static func patchedInitSegment(
        _ data: Data,
        complexityIndex: UInt8 = defaultComplexityIndex
    ) -> Data? {
        var didPatch = false
        guard let patched = patchBoxes(
            [UInt8](data),
            complexityIndex: complexityIndex,
            didPatch: &didPatch
        ), didPatch else {
            return nil
        }
        return Data(patched)
    }

    private static func patchBoxes(
        _ bytes: [UInt8],
        complexityIndex: UInt8,
        didPatch: inout Bool
    ) -> [UInt8]? {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + 2)
        var offset = 0

        while offset < bytes.count {
            guard offset + 8 <= bytes.count else { return nil }
            let size = Int(readUInt32(bytes, at: offset))
            // size 0 ("to end of file") and 1 (64-bit size) never occur in an
            // init segment's moov tree; treat them as unparseable.
            guard size >= 8, offset + size <= bytes.count else { return nil }
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            var box = Array(bytes[offset..<(offset + size)])

            if type == "dec3", let extended = extendedDEC3(box, complexityIndex: complexityIndex) {
                box = extended
                didPatch = true
            } else if let padding = containerHeaderPadding[type] {
                let headerLength = 8 + padding
                guard headerLength <= box.count,
                      let children = patchBoxes(
                        Array(box[headerLength...]),
                        complexityIndex: complexityIndex,
                        didPatch: &didPatch
                      ) else {
                    return nil
                }
                box = Array(box[..<headerLength]) + children
                writeUInt32(UInt32(box.count), into: &box, at: 0)
            }

            output += box
            offset += size
        }
        return output
    }

    /// `dec3` payload: data_rate(13) num_ind_sub(3), then per independent
    /// substream fscod(2) bsid(5) reserved(1) asvc(1) bsmod(3) acmod(3)
    /// lfeon(1) reserved(3) num_dep_sub(4) and either chan_loc(9) or
    /// reserved(1) — three bytes each. An optional trailer follows:
    /// reserved(7) flag_ec3_extension_type_a(1) complexity_index_type_a(8).
    private static func extendedDEC3(_ box: [UInt8], complexityIndex: UInt8) -> [UInt8]? {
        let payload = box.count - 8
        guard payload >= 2 else { return nil }
        let independentSubstreams = Int(box[9] & 0x07) + 1
        let baseLength = 2 + independentSubstreams * 3
        // Already carries a trailer (or is something we do not understand).
        guard payload == baseLength else { return nil }

        var extended = box + [0x01, complexityIndex]
        writeUInt32(UInt32(extended.count), into: &extended, at: 0)
        return extended
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func writeUInt32(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(value >> 24)
        bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
        bytes[offset + 3] = UInt8(value & 0xFF)
    }
}

/// Resource-loader front for a Plex fMP4 HLS remux (Dolby Atmos sessions).
///
/// Playlists and the init segment are requested through a private URL
/// scheme and fetched here; media segments are rewritten to absolute server
/// URLs so AVFoundation fetches them directly, and the init segment's Atmos
/// signaling is restored on the way through (`EAC3JOCSignaling`). Anything
/// unexpected is passed through untouched, so the worst case is 5.1 without
/// the Atmos layer, never a broken stream.
final class RemuxHLSLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private static let schemePrefix = "dusk-remux-"

    let queue = DispatchQueue(label: "com.dusk-player.remux-hls-loader")
    private let session: URLSession
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// The URL to hand AVFoundation in place of `url` (http/https only).
    static func loaderURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = schemePrefix + scheme
        return components.url
    }

    static func serverURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme.hasPrefix(schemePrefix),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = String(scheme.dropFirst(schemePrefix.count))
        return components.url
    }

    /// Builds an asset whose playlists/init segment flow through `loader`.
    /// The asset holds its resource loader's delegate weakly — keep `loader`
    /// alive for as long as the item plays.
    static func makeAsset(url: URL, loader: RemuxHLSLoader) -> AVURLAsset? {
        guard let loaderURL = loaderURL(for: url) else { return nil }
        let asset = AVURLAsset(url: loaderURL)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
        return asset
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let requestURL = loadingRequest.request.url,
              let serverURL = Self.serverURL(for: requestURL) else {
            return false
        }

        let key = ObjectIdentifier(loadingRequest)
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            await self.load(loadingRequest, serverURL: serverURL)
            self.queue.async { self.tasks[key] = nil }
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))?.cancel()
    }

    private func load(_ loadingRequest: AVAssetResourceLoadingRequest, serverURL: URL) async {
        var request = loadingRequest.request
        request.url = serverURL
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw URLError(.badServerResponse)
            }
            let body = transformedBody(data, response: response, serverURL: serverURL)
            queue.async {
                guard !loadingRequest.isCancelled else { return }
                Self.respond(to: loadingRequest, with: body.data, contentType: body.contentType)
            }
        } catch {
            queue.async {
                guard !loadingRequest.isCancelled else { return }
                loadingRequest.finishLoading(with: error)
            }
        }
    }

    private func transformedBody(
        _ data: Data,
        response: URLResponse,
        serverURL: URL
    ) -> (data: Data, contentType: String) {
        if Self.isPlaylist(data) {
            let text = String(decoding: data, as: UTF8.self)
            return (Data(rewrittenPlaylist(text, baseURL: serverURL).utf8), "public.m3u-playlist")
        }

        if let patched = EAC3JOCSignaling.patchedInitSegment(data) {
            atmosSignalingLogger.notice("Restored Dolby Atmos (E-AC-3 JOC) signaling in the HLS init segment")
            return (patched, "public.mpeg-4")
        }
        return (data, "public.mpeg-4")
    }

    /// Sends playlists and the init segment back through the loader; media
    /// segments go straight to the server as absolute URLs.
    func rewrittenPlaylist(_ playlist: String, baseURL: URL) -> String {
        var routeNextURIThroughLoader = false
        var lines: [String] = []

        for rawLine in playlist.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                routeNextURIThroughLoader = true
                lines.append(line)
            } else if line.hasPrefix("#EXT-X-MAP") || line.hasPrefix("#EXT-X-MEDIA") {
                lines.append(rewritingURIAttribute(in: line, baseURL: baseURL))
            } else if line.isEmpty || line.hasPrefix("#") {
                lines.append(line)
            } else if let absolute = URL(string: line, relativeTo: baseURL)?.absoluteURL {
                if routeNextURIThroughLoader, let loaderURL = Self.loaderURL(for: absolute) {
                    lines.append(loaderURL.absoluteString)
                } else {
                    lines.append(absolute.absoluteString)
                }
                routeNextURIThroughLoader = false
            } else {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    private func rewritingURIAttribute(in line: String, baseURL: URL) -> String {
        guard let start = line.range(of: "URI=\""),
              let end = line[start.upperBound...].firstIndex(of: "\"") else {
            return line
        }
        let uri = String(line[start.upperBound..<end])
        guard let absolute = URL(string: uri, relativeTo: baseURL)?.absoluteURL,
              let loaderURL = Self.loaderURL(for: absolute) else {
            return line
        }
        return line.replacingCharacters(in: start.upperBound..<end, with: loaderURL.absoluteString)
    }

    private static func isPlaylist(_ data: Data) -> Bool {
        data.prefix(7).elementsEqual("#EXTM3U".utf8)
    }

    private static func respond(
        to loadingRequest: AVAssetResourceLoadingRequest,
        with data: Data,
        contentType: String
    ) {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }
        if let dataRequest = loadingRequest.dataRequest {
            let start = Int(dataRequest.requestedOffset)
            let length = dataRequest.requestsAllDataToEndOfResource
                ? data.count - start
                : dataRequest.requestedLength
            let end = min(data.count, start + max(0, length))
            if start < end {
                dataRequest.respond(with: data.subdata(in: start..<end))
            }
        }
        loadingRequest.finishLoading()
    }
}
