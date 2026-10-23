import Foundation

/// Public-settings probe shared by connect and the simulator checks.
enum SeerrProbe {
    struct Resolved: Sendable {
        var baseURL: URL
        var settings: SeerrPublicSettings
    }

    static func resolve(
        rawURL: String,
        session: URLSession,
        delegate: SeerrURLSessionDelegate
    ) async throws -> Resolved {
        let candidates = try SeerrServerURL.candidates(from: rawURL)
        var best: SeerrServiceError?
        for candidate in candidates {
            do {
                return try await load(candidate: candidate, session: session, delegate: delegate)
            } catch let error as SeerrServiceError {
                if error.haltsCandidateSearch { throw error }
                best = SeerrServiceError.prefer(error, over: best)
            } catch {
                let mapped = map(error, delegate: delegate)
                if mapped.haltsCandidateSearch { throw mapped }
                best = SeerrServiceError.prefer(mapped, over: best)
            }
        }
        throw best ?? SeerrServiceError.invalidServerURL
    }

    private static func load(
        candidate: URL,
        session: URLSession,
        delegate: SeerrURLSessionDelegate
    ) async throws -> Resolved {
        guard let url = SeerrServerURL.endpointURL(
            base: candidate,
            path: SeerrServerURL.publicSettingsPath
        ) else {
            throw SeerrServiceError.invalidServerURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        delegate.prepareForRequest()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw map(error, delegate: delegate)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SeerrServiceError.invalidResponse
        }
        if let failure = httpFailure(http, data: data) {
            throw failure
        }
        let settings: SeerrPublicSettings
        do {
            settings = try JSONDecoder().decode(SeerrPublicSettings.self, from: data)
        } catch {
            throw SeerrServiceError.notASeerrServer
        }
        let finalURL = http.url ?? candidate
        let baseURL = SeerrServerURL.adoptingRedirect(
            from: candidate,
            responseURL: finalURL,
            requestedPath: SeerrServerURL.publicSettingsPath
        )
        return Resolved(baseURL: baseURL, settings: settings)
    }

    private static func httpFailure(_ response: HTTPURLResponse, data: Data) -> SeerrServiceError? {
        let status = response.statusCode
        guard !(200...299).contains(status) else { return nil }
        if (300..<400).contains(status) {
            let location = response.value(forHTTPHeaderField: "Location") ?? ""
            return SeerrServerURL.isLoginLocation(location) ? .redirectedToLogin : .notASeerrServer
        }
        if status == 404 || status == 410 {
            return .notASeerrServer
        }
        if let message = jsonMessage(data) {
            return .serverError(message)
        }
        return .notASeerrServer
    }

    private static func jsonMessage(_ data: Data) -> String? {
        struct Body: Decodable {
            let message: String?
            let error: String?
        }
        guard let body = try? JSONDecoder().decode(Body.self, from: data) else { return nil }
        let message = body.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message, !message.isEmpty { return message }
        let error = body.error?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error, !error.isEmpty { return error }
        return nil
    }

    private static func map(_ error: Error, delegate: SeerrURLSessionDelegate) -> SeerrServiceError {
        if let failure = delegate.takeTrustFailure() {
            return .tlsUntrusted(
                host: failure.host,
                port: failure.port,
                fingerprint: failure.fingerprint
            )
        }
        return .classifyTransport(error)
    }
}
