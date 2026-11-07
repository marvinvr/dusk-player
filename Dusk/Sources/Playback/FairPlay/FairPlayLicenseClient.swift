import CryptoKit
import Foundation

/// The two network legs of Apple's standard FairPlay Streaming flow, for an
/// IPTV channel whose M3U names them:
///
/// 1. GET the application certificate from `server_certificate` (cached).
/// 2. POST the SPC to `license_key` as a raw body
///    (`Content-Type: application/octet-stream`) and return the raw CKC.
///
/// Both requests carry the source's headers. Dusk never sees a content key:
/// the SPC and CKC are opaque blobs exchanged between AVFoundation and the
/// license server.
struct FairPlayLicenseClient: Sendable {
    let certificateURL: URL?
    let licenseURL: URL?
    let headers: [String: String]
    let userAgent: String?
    var session: URLSession = .shared
    var certificateCache: FairPlayCertificateCache = .shared

    func applicationCertificate() async throws -> Data {
        guard let certificateURL else { throw FairPlayError.missingCertificateURL }
        if let cached = await certificateCache.certificate(for: certificateURL) {
            return cached
        }
        var request = URLRequest(url: certificateURL)
        request.httpMethod = "GET"
        apply(to: &request)
        let data = try await perform(request, failure: FairPlayError.certificateRequestFailed)
        guard !data.isEmpty else { throw FairPlayError.certificateRequestFailed(status: nil) }
        await certificateCache.store(data, for: certificateURL)
        return data
    }

    func contentKeyContext(forSPC spc: Data) async throws -> Data {
        guard let licenseURL else { throw FairPlayError.missingLicenseURL }
        var request = URLRequest(url: licenseURL)
        request.httpMethod = "POST"
        request.httpBody = spc
        apply(to: &request)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let data = try await perform(request, failure: FairPlayError.licenseRequestFailed)
        guard !data.isEmpty else { throw FairPlayError.licenseRequestFailed(status: nil) }
        return data
    }

    private func apply(to request: inout URLRequest) {
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
    }

    private func perform(
        _ request: URLRequest,
        failure: (Int?) -> FairPlayError
    ) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw failure(nil)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw failure(http.statusCode)
        }
        return data
    }
}

/// Application certificates rarely change, and every channel of a source
/// usually shares one, so they are kept in memory and on disk (Caches) by URL.
actor FairPlayCertificateCache {
    static let shared = FairPlayCertificateCache()

    private var memory: [URL: Data] = [:]
    private let directory: URL?

    init(directory: URL? = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("FairPlayCertificates", isDirectory: true)
    ) {
        self.directory = directory
    }

    func certificate(for url: URL) -> Data? {
        if let data = memory[url] { return data }
        guard let file = fileURL(for: url), let data = try? Data(contentsOf: file), !data.isEmpty else {
            return nil
        }
        memory[url] = data
        return data
    }

    func store(_ data: Data, for url: URL) {
        memory[url] = data
        guard let directory, let file = fileURL(for: url) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Drops a certificate the license server no longer accepts.
    func remove(for url: URL) {
        memory[url] = nil
        if let file = fileURL(for: url) { try? FileManager.default.removeItem(at: file) }
    }

    private func fileURL(for url: URL) -> URL? {
        guard let directory else { return nil }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("cer")
    }
}

enum FairPlayError: LocalizedError, Equatable {
    case missingLicenseURL
    case missingCertificateURL
    case missingContentIdentifier
    case certificateRequestFailed(status: Int?)
    case licenseRequestFailed(status: Int?)
    case unsupportedKeySystem(String)
    case unavailableOnSimulator

    var errorDescription: String? {
        switch self {
        case .missingLicenseURL:
            "This channel is protected with FairPlay, but its IPTV source doesn’t name a license server."
        case .missingCertificateURL:
            "This channel is protected with FairPlay, but its IPTV source doesn’t name a server certificate."
        case .missingContentIdentifier:
            "The channel’s FairPlay key request had no content identifier."
        case .certificateRequestFailed(let status):
            "The FairPlay certificate couldn’t be loaded\(Self.statusSuffix(status))."
        case .licenseRequestFailed(let status):
            "The license server refused this channel\(Self.statusSuffix(status))."
        case .unavailableOnSimulator:
            "FairPlay-protected channels play only on a real iPhone, iPad or Apple TV."
        case .unsupportedKeySystem(let name):
            "This channel uses \(name) protection, which Apple devices can’t play. Only FairPlay is supported."
        }
    }

    private static func statusSuffix(_ status: Int?) -> String {
        status.map { " (HTTP \($0))" } ?? ""
    }
}
