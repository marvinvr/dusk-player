import Compression
import Foundation

/// Gunzips a downloaded file to a temporary file, streaming, so big
/// `guide.xml.gz` files never sit in memory. XMLTV guides are very often
/// served gzipped as files (not as a `Content-Encoding`, which URLSession
/// already undoes). Uses Apple's Compression framework: `COMPRESSION_ZLIB` is
/// raw DEFLATE, so the gzip header is parsed and skipped here.
enum GzipFile {
    static func isGzip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let magic = (try? handle.read(upToCount: 2)) ?? Data()
        return magic == Data([0x1F, 0x8B])
    }

    /// `url` itself when it is not gzip, otherwise a new temporary file the
    /// caller removes.
    static func decompressedIfNeeded(_ url: URL) throws -> URL {
        guard isGzip(url) else { return url }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("dusk-xmltv-\(UUID().uuidString).xml")
        try decompress(url, to: output)
        return output
    }

    static func decompress(_ input: URL, to output: URL) throws {
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }

        let headerLength = try gzipHeaderLength(reader)
        try reader.seek(toOffset: UInt64(headerLength))

        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw GzipError.corrupt
        }
        defer { compression_stream_destroy(streamPointer) }

        let bufferSize = 256 * 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }

        var finished = false
        while !finished {
            let chunk = try reader.read(upToCount: bufferSize) ?? Data()
            let isLastChunk = chunk.isEmpty
            try chunk.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                streamPointer.pointee.src_ptr = source.bindMemory(to: UInt8.self).baseAddress
                    ?? UnsafePointer(destination)
                streamPointer.pointee.src_size = chunk.count
                repeat {
                    streamPointer.pointee.dst_ptr = destination
                    streamPointer.pointee.dst_size = bufferSize
                    let flags = isLastChunk ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                    let status = compression_stream_process(streamPointer, flags)
                    let produced = bufferSize - streamPointer.pointee.dst_size
                    if produced > 0 {
                        writer.write(Data(bytes: destination, count: produced))
                    }
                    switch status {
                    case COMPRESSION_STATUS_OK:
                        break
                    case COMPRESSION_STATUS_END:
                        // Trailing CRC/size (and any concatenated member) are
                        // ignored: the XML itself is complete.
                        finished = true
                        return
                    default:
                        throw GzipError.corrupt
                    }
                } while streamPointer.pointee.src_size > 0 || streamPointer.pointee.dst_size == 0
            }
            if isLastChunk { finished = true }
        }
    }

    /// RFC 1952 header: 10 fixed bytes, then optional EXTRA, NAME, COMMENT
    /// and HCRC fields as the flag byte says.
    private static func gzipHeaderLength(_ handle: FileHandle) throws -> Int {
        try handle.seek(toOffset: 0)
        let header = try handle.read(upToCount: 64 * 1024) ?? Data()
        let bytes = [UInt8](header)
        guard bytes.count >= 10, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else {
            throw GzipError.corrupt
        }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {
            guard bytes.count >= offset + 2 else { throw GzipError.corrupt }
            offset += 2 + Int(bytes[offset]) + Int(bytes[offset + 1]) << 8
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset <= bytes.count else { throw GzipError.corrupt }
        return offset
    }
}

enum GzipError: LocalizedError {
    case corrupt

    var errorDescription: String? { "The compressed program guide is damaged." }
}
