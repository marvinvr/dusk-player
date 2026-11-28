import Foundation

/// The server's `PlaySessionId` of each open server stream, by the stream
/// session id the coordinator chose. `PlaybackInfo` assigns the id; ping and
/// stop need it. Shared because a server's provider (and its facets) can be
/// rebuilt while a stream plays.
@MainActor
final class JellyfinServerStreams {
    static let shared = JellyfinServerStreams()

    private var playSessions: [(streamSessionID: String, playSessionID: String)] = []
    /// Streams closed before their `PlaybackInfo` answer arrived.
    private var closedEarly: [String] = []
    private static let remembered = 32

    /// Records an opened stream. False when it was closed meanwhile: the
    /// caller stops its encoding.
    func register(streamSessionID: String, playSessionID: String) -> Bool {
        if let index = closedEarly.firstIndex(of: streamSessionID) {
            closedEarly.remove(at: index)
            return false
        }
        playSessions.removeAll { $0.streamSessionID == streamSessionID }
        playSessions.append((streamSessionID, playSessionID))
        if playSessions.count > Self.remembered {
            playSessions.removeFirst(playSessions.count - Self.remembered)
        }
        return true
    }

    func playSessionID(for streamSessionID: String) -> String? {
        playSessions.last { $0.streamSessionID == streamSessionID }?.playSessionID
    }

    /// The stream's play session, forgotten; nil (and remembered as closed)
    /// when it has not opened yet.
    func close(streamSessionID: String) -> String? {
        if let index = playSessions.lastIndex(where: { $0.streamSessionID == streamSessionID }) {
            return playSessions.remove(at: index).playSessionID
        }
        closedEarly.append(streamSessionID)
        if closedEarly.count > Self.remembered {
            closedEarly.removeFirst(closedEarly.count - Self.remembered)
        }
        return nil
    }
}
