import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum DuskAsyncImagePhase {
    case empty
    case success(Image)
    case failure(any Error)
}

struct DuskAsyncImage<Content: View>: View {
    @Environment(PlexService.self) private var plexService

    let url: URL?
    @ViewBuilder let content: (DuskAsyncImagePhase) -> Content

    @State private var phase = DuskAsyncImagePhase.empty

    var body: some View {
        content(phase)
            .task(id: url) {
                await loadImage()
            }
    }

    @MainActor
    private func loadImage() async {
        guard let url else {
            phase = .empty
            return
        }

        phase = .empty

        do {
            let image = try await DuskImageLoader.shared.image(for: url, using: plexService)
            guard !Task.isCancelled else { return }
            phase = .success(Image(uiImage: image))
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failure(error)
        }
    }
}

actor DuskImageLoader {
    static let shared = DuskImageLoader()

    private let session: URLSession
    #if canImport(UIKit)
    private let memoryCache = NSCache<NSURL, UIImage>()
    #endif
    private var inFlightTasks: [URL: Task<UIImage, Error>] = [:]

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = AppImageCache.shared
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30

        session = URLSession(configuration: configuration)
        #if canImport(UIKit)
        memoryCache.countLimit = 512
        #endif
    }

    func image(for url: URL, using plexService: PlexService? = nil) async throws -> UIImage {
        #if canImport(UIKit)
        let cacheKey = url as NSURL
        if let cachedImage = memoryCache.object(forKey: cacheKey) {
            return cachedImage
        }
        #endif

        if let task = inFlightTasks[url] {
            return try await task.value
        }

        let task = Task<UIImage, Error> { [session] in
            let request = URLRequest(
                url: url,
                cachePolicy: .returnCacheDataElseLoad,
                timeoutInterval: 30
            )

            if let cachedResponse = AppImageCache.shared.cachedResponse(for: request),
               let cachedImage = UIImage(data: cachedResponse.data) {
                return cachedImage
            }

            let data: Data
            if let plexService {
                data = try await plexService.imageData(for: url)
            } else {
                let (fetchedData, response) = try await session.data(for: request)

                if let httpResponse = response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    throw URLError(.badServerResponse)
                }

                data = fetchedData
            }

            guard let image = UIImage(data: data) else {
                throw URLError(.cannotDecodeContentData)
            }

            if let cachedResponse = URLCache.shared.cachedResponse(for: request) {
                AppImageCache.shared.storeCachedResponse(cachedResponse, for: request)
            }
            return image
        }

        inFlightTasks[url] = task

        do {
            let image = try await task.value
            #if canImport(UIKit)
            memoryCache.setObject(image, forKey: cacheKey)
            #endif
            inFlightTasks[url] = nil
            return image
        } catch {
            inFlightTasks[url] = nil
            throw error
        }
    }
}
