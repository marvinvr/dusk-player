#if os(tvOS)
import Foundation
import Observation

/// A Top Shelf deep link: `dusk://play?…` resumes the item, `dusk://open?…`
/// opens its detail page. Both carry the item's server, because rating keys
/// collide across servers (see `MediaItemID`).
struct TopShelfLink: Equatable {
    enum Action: String {
        case play
        case open
    }

    static let scheme = "dusk"

    /// A link the app could not act on within this window (its server never
    /// connected, a profile had to be picked first) is dropped rather than
    /// firing minutes later out of nowhere.
    private static let maxPendingAge: TimeInterval = 30

    let action: Action
    let id: MediaItemID
    let type: MediaKind
    let isClip: Bool
    let receivedAt: Date

    init?(url: URL, receivedAt: Date = .now) {
        guard url.scheme == Self.scheme,
              let action = url.host().flatMap(Action.init(rawValue:)),
              let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }

        func value(_ name: String) -> String? {
            queryItems.first { $0.name == name }?.value?.nilIfEmpty
        }

        guard let serverID = value("server"),
              let ratingKey = value("item"),
              let type = value("type").flatMap(MediaKind.init(rawValue:)) else {
            return nil
        }

        self.action = action
        self.id = MediaItemID(serverID: serverID, ratingKey: ratingKey)
        self.type = type
        self.isClip = value("clip") == "1"
        self.receivedAt = receivedAt
    }

    static func url(_ action: Action, for item: MediaItem) -> URL? {
        guard let serverID = item.serverID?.nilIfEmpty else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = action.rawValue
        components.queryItems = [
            URLQueryItem(name: "server", value: serverID),
            URLQueryItem(name: "item", value: item.ratingKey),
            URLQueryItem(name: "type", value: item.type.rawValue),
        ] + (item.isClip ? [URLQueryItem(name: "clip", value: "1")] : [])
        return components.url
    }

    var route: AppNavigationRoute {
        // Same rule as `AppNavigationRoute.destination(for:)`: clips report
        // `type == "movie"` and must never open the movie detail flow.
        isClip ? .video(id: id) : .media(type: type, id: id)
    }

    func isStale(now: Date = .now) -> Bool {
        now.timeIntervalSince(receivedAt) > Self.maxPendingAge
    }
}

/// Holds the Top Shelf link the app was opened with until the tab shell can
/// act on it. A cold launch delivers the URL long before the item's server is
/// connected, so the link waits here; `MainTabView` consumes it.
@MainActor @Observable
final class TopShelfLinkRouter {
    var pending: TopShelfLink?

    func open(_ url: URL) {
        guard let link = TopShelfLink(url: url) else { return }
        pending = link
    }
}
#endif
