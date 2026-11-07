import CoreFoundation
import Foundation
import NaturalLanguage

/// Decode whole sidecars, rather than guessing an encoding independently for
/// each cue. Container text tracks already declare their encoding to libvlc.
enum SubtitleTextDecoder {
    static func fileExtension(for codec: String?) -> String? {
        switch codec?.lowercased() {
        case "srt", "subrip": "srt"
        case "ass": "ass"
        case "ssa": "ssa"
        case "vtt", "webvtt": "vtt"
        case "microdvd", "subviewer": "sub"
        case "sami": "smi"
        default: nil // In particular, never rewrite VobSub/PGS or unknown codecs.
        }
    }

    /// Sidecars larger than this are not subtitles worth decoding.
    static let maximumFileSize = 8 * 1_024 * 1_024

    /// The sidecar re-encoded as UTF-8 with a BOM, which makes the demuxer
    /// (including the ASS path) recognize UTF-8. Nil when it cannot be decoded.
    static func normalizedFileData(_ data: Data) -> Data? {
        guard data.count <= maximumFileSize, let text = decode(data) else { return nil }
        return Data(("\u{FEFF}" + text).utf8)
    }

    static func decode(_ data: Data) -> String? {
        // Check UTF-32 before UTF-16: their little-endian BOMs overlap.
        let unicodeBOMs: [([UInt8], String.Encoding)] = [
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian),
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian),
            ([0xEF, 0xBB, 0xBF], .utf8),
        ]
        for (bom, encoding) in unicodeBOMs where data.starts(with: bom) {
            return String(data: data.dropFirst(bom.count), encoding: encoding)
        }
        guard !data.contains(0) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }

        var converted: NSString?
        var lossy: ObjCBool = false
        let encoding = NSString.stringEncoding(
            for: data,
            encodingOptions: [.allowLossyKey: false],
            convertedString: &converted,
            usedLossyConversion: &lossy
        )
        guard encoding != 0, !lossy.boolValue, let converted else { return nil }
        let text = converted as String

        // Apple's detector can mistake KOI8-R for ISO-8859-5. Both round-trip
        // every byte, so use the system language model to resolve that specific
        // ambiguity. Keep the detector's result without a strong improvement.
        let isoCyrillic = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.isoLatinCyrillic.rawValue)
        )
        if encoding == isoCyrillic {
            let koi8 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.KOI8_R.rawValue)
            ))
            if let candidate = String(data: data, encoding: koi8) {
                let candidateScore = russianConfidence(candidate)
                if candidateScore >= 0.99, candidateScore > russianConfidence(text) + 0.03 {
                    return candidate
                }
            }
        }
        return text
    }

    private static func russianConfidence(_ text: String) -> Double {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(16_384)))
        return recognizer.languageHypotheses(withMaximum: 8)[.russian] ?? 0
    }
}

/// Per-engine temporary files. Retained by in-flight preparation tasks so a
/// cancelled session cannot write into the next session's directory. Reopens
/// reuse prepared files; stopping/replacing the session releases the store.
final class SubtitleFileStore: Sendable {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("DuskSubtitles-\(UUID().uuidString)", isDirectory: true)

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func prepare(_ url: URL, codec: String?) async throws -> URL {
        // A .sub suffix alone is ambiguous: MicroDVD is text, VobSub is not.
        guard let fileExtension = SubtitleTextDecoder.fileExtension(for: codec) else { return url }
        let sourceURL: URL
        if url.isFileURL {
            sourceURL = url
        } else {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            try PlexTransportSecurity.validate(request)
            let (download, response) = try await PlexTransportSecurity.session.download(for: request)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                try? FileManager.default.removeItem(at: download)
                throw URLError(.badServerResponse)
            }
            sourceURL = download
        }
        defer {
            if !url.isFileURL { try? FileManager.default.removeItem(at: sourceURL) }
        }
        try Task.checkCancellation()
        let size = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= SubtitleTextDecoder.maximumFileSize else { throw URLError(.dataLengthExceedsMaximum) }
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        guard let normalized = SubtitleTextDecoder.normalizedFileData(data) else {
            throw URLError(.cannotDecodeContentData)
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        try normalized.write(to: target, options: .atomic)
        return target
    }
}
