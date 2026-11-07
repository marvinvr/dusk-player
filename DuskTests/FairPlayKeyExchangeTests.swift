import Foundation
import Testing
@testable import Dusk

/// The FairPlay flow against a mocked license server. A simulator cannot
/// produce a real SPC (and AVFoundation cannot build an `AVContentKeyRequest`
/// in a test), so the request is a fake; everything Dusk itself does —
/// certificate fetch and cache, content id, SPC POST, CKC hand-back, errors —
/// runs for real. Real FairPlay playback is unverified until tried on device.
@Suite("FairPlay key exchange", .serialized)
struct FairPlayKeyExchangeTests {
    private let certificate = Data("APPLICATION-CERTIFICATE".utf8)
    private let ckc = Data("CONTENT-KEY-CONTEXT".utf8)

    private func client(
        host: String,
        license: Bool = true,
        cache: FairPlayCertificateCache
    ) -> FairPlayLicenseClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockLicenseServer.self]
        return FairPlayLicenseClient(
            certificateURL: URL(string: "https://\(host)/cert.der"),
            licenseURL: license ? URL(string: "https://\(host)/license?channel=7") : nil,
            headers: ["Authorization": "Bearer relay-token"],
            userAgent: "DuskTest/1.0",
            session: URLSession(configuration: configuration),
            certificateCache: cache
        )
    }

    private func temporaryCache() -> FairPlayCertificateCache {
        FairPlayCertificateCache(
            directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("dusk-fps-\(UUID().uuidString)", isDirectory: true)
        )
    }

    @Test func contentIdentifierComesFromTheSkdURI() {
        #expect(FairPlayKeyExchange.contentIdentifier(fromKeyIdentifier: "skd://channel-7") == Data("channel-7".utf8))
        #expect(FairPlayKeyExchange.contentIdentifier(fromKeyIdentifier: "SKD://a/b?c=1") == Data("a/b?c=1".utf8))
        #expect(FairPlayKeyExchange.contentIdentifier(fromKeyIdentifier: "plain-id") == Data("plain-id".utf8))
        #expect(FairPlayKeyExchange.contentIdentifier(fromKeyIdentifier: "skd://") == nil)
        #expect(FairPlayKeyExchange.contentIdentifier(fromKeyIdentifier: nil) == nil)
    }

    @Test func fullExchangePostsTheSPCAndFeedsTheCKCBack() async throws {
        let host = "fps-\(UUID().uuidString.lowercased()).invalid"
        let certificate = certificate
        let ckc = ckc
        let log = RequestLog()
        MockLicenseServer.register(host: host) { request, body in
            log.append(request, body: body)
            switch request.url?.path {
            case "/cert.der":
                return (200, certificate)
            case "/license":
                // The license server sees exactly the SPC, raw.
                guard request.httpMethod == "POST",
                      request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream",
                      body == FakeKeyRequest.spc(certificate: certificate, contentID: Data("channel-7".utf8)) else {
                    return (400, Data())
                }
                return (200, ckc)
            default:
                return (404, Data())
            }
        }
        defer { MockLicenseServer.unregister(host: host) }

        let cache = temporaryCache()
        let exchange = FairPlayKeyExchange(client: client(host: host, cache: cache))
        let first = FakeKeyRequest(keyIdentifier: "skd://channel-7")
        try await exchange.handle(first)
        #expect(first.finishedWith == ckc)
        #expect(first.failure == nil)

        // A second key request (another channel, a renewal) reuses the cached
        // certificate.
        let second = FakeKeyRequest(keyIdentifier: "skd://channel-7")
        try await exchange.handle(second)
        #expect(second.finishedWith == ckc)

        let requests = log.entries
        #expect(requests.map(\.path) == ["/cert.der", "/license", "/license"])
        // The source's header and user agent reach both servers.
        #expect(requests.allSatisfy { $0.authorization == "Bearer relay-token" && $0.userAgent == "DuskTest/1.0" })
        #expect(requests[1].query == "channel=7")
    }

    @Test func refusedLicenseFailsTheRequestWithAReadableError() async {
        let host = "fps-\(UUID().uuidString.lowercased()).invalid"
        let certificate = certificate
        MockLicenseServer.register(host: host) { request, _ in
            request.url?.path == "/cert.der" ? (200, certificate) : (403, Data("denied".utf8))
        }
        defer { MockLicenseServer.unregister(host: host) }

        let request = FakeKeyRequest(keyIdentifier: "skd://channel-7")
        await #expect(throws: FairPlayError.licenseRequestFailed(status: 403)) {
            try await FairPlayKeyExchange(client: client(host: host, cache: temporaryCache())).handle(request)
        }
        #expect(request.failure as? FairPlayError == .licenseRequestFailed(status: 403))
        #expect(request.finishedWith == nil)
        #expect(FairPlayError.licenseRequestFailed(status: 403).localizedDescription.contains("HTTP 403"))
    }

    @Test func missingLicenseServerFailsBeforeAnySPC() async {
        let request = FakeKeyRequest(keyIdentifier: "skd://channel-7")
        let exchange = FairPlayKeyExchange(client: client(host: "unused.invalid", license: false, cache: temporaryCache()))
        await #expect(throws: FairPlayError.missingLicenseURL) {
            try await exchange.handle(request)
        }
        #expect(request.spcRequests == 0)
        #expect(request.failure as? FairPlayError == .missingLicenseURL)
    }

    @Test func failedCertificateFailsTheRequest() async {
        let host = "fps-\(UUID().uuidString.lowercased()).invalid"
        MockLicenseServer.register(host: host) { _, _ in (500, Data()) }
        defer { MockLicenseServer.unregister(host: host) }

        let request = FakeKeyRequest(keyIdentifier: "skd://channel-7")
        await #expect(throws: FairPlayError.certificateRequestFailed(status: 500)) {
            try await FairPlayKeyExchange(client: client(host: host, cache: temporaryCache())).handle(request)
        }
        #expect(request.spcRequests == 0)
    }

    @Test func certificateCachePersistsAcrossInstances() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dusk-fps-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(string: "https://cert.example.com/c.der")!
        await FairPlayCertificateCache(directory: directory).store(certificate, for: url)
        #expect(await FairPlayCertificateCache(directory: directory).certificate(for: url) == certificate)
        await FairPlayCertificateCache(directory: directory).remove(for: url)
        #expect(await FairPlayCertificateCache(directory: directory).certificate(for: url) == nil)
    }
}

// MARK: - Fakes

/// Stands in for `AVContentKeyRequest`. Its "SPC" binds the certificate and
/// content id so the mock server can check both reached it.
private final class FakeKeyRequest: FairPlayKeyRequest, @unchecked Sendable {
    let keyIdentifier: String?
    private(set) var finishedWith: Data?
    private(set) var failure: Error?
    private(set) var spcRequests = 0

    init(keyIdentifier: String?) {
        self.keyIdentifier = keyIdentifier
    }

    static func spc(certificate: Data, contentID: Data) -> Data {
        Data("SPC:".utf8) + certificate + Data(":".utf8) + contentID
    }

    func makeServerPlaybackContext(certificate: Data, contentIdentifier: Data) async throws -> Data {
        spcRequests += 1
        return Self.spc(certificate: certificate, contentID: contentIdentifier)
    }

    func finish(contentKeyContext: Data) { finishedWith = contentKeyContext }
    func fail(_ error: Error) { failure = error }
}

private final class RequestLog: @unchecked Sendable {
    struct Entry {
        let path: String
        let query: String?
        let authorization: String?
        let userAgent: String?
    }

    private let lock = NSLock()
    private var storage: [Entry] = []

    var entries: [Entry] { lock.withLock { storage } }

    func append(_ request: URLRequest, body: Data?) {
        let entry = Entry(
            path: request.url?.path ?? "",
            query: request.url?.query,
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            userAgent: request.value(forHTTPHeaderField: "User-Agent")
        )
        lock.withLock { storage.append(entry) }
    }
}

/// A license + certificate server inside URLSession. Routes by host so each
/// test owns its own server.
private final class MockLicenseServer: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data?) -> (Int, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(host: String, handler: @escaping Handler) {
        lock.withLock { handlers[host] = handler }
    }

    static func unregister(host: String) {
        lock.withLock { handlers[host] = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let handler = Self.lock.withLock({ Self.handlers[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (status, data) = handler(request, Self.body(of: request))
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession moves `httpBody` into a stream before a protocol sees it.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
