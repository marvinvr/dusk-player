import Foundation

/// Channels, guide, catch-up recordings and tuning on one server
/// (docs/jellyfin/04-architecture.md §14).
///
/// One value per server, and optional on the provider: a server without Live
/// TV has no facet, and a server whose facet finds no DVR answers `source()`
/// with nil. IPTV is not a server and has no facet: it builds the same `Live*`
/// models itself (`IPTVLineupBuilder`), and the facade never routes an IPTV
/// lineup here (`MediaService.liveTV(for:)`).
///
/// Which server's DVR the tab shows (discovery across the pool) and the guide's
/// refresh policy are Dusk's, in the facade and `LiveTVViewModel`. Filing
/// guide airings under channels is the provider's (`lineup(source:channels:programs:)`):
/// how an airing names its channel differs per server.
///
/// The methods run on the main actor, where the facade and its request routing
/// live.
protocol LiveTVProviding: Sendable {
    /// The server's Live TV source (a DVR), stamped with the server; nil when
    /// it has none.
    @MainActor func source() async throws -> LiveTVProvider?

    /// The source's channels, in channel-number order.
    @MainActor func channels(of source: LiveTVProvider) async throws -> [LiveChannel]

    /// The source's tuner devices and the channels mapped to each, which split
    /// the guide into one section per device. Empty when the server reports
    /// none; the guide is then one section.
    @MainActor func devices(of source: LiveTVProvider) async throws -> [LiveTVDevice]

    /// What is on now on `channels`, filed under them.
    @MainActor func onNow(source: LiveTVProvider, channels: [LiveChannel]) async throws -> LiveTVLineup

    /// Every channel's airings that overlap `window`, unfiled.
    @MainActor func airings(source: LiveTVProvider, window: LiveTVGuideWindow) async throws -> [LiveProgram]

    /// The guide for `channels` over whole local days, asked channel by
    /// channel: for a server whose `airings(source:window:)` came back empty
    /// for a window that has a guide. A channel whose guide failed keeps an
    /// empty row; only every channel failing throws.
    @MainActor func guide(source: LiveTVProvider, channels: [LiveChannel], days: [Date]) async throws -> LiveTVLineup

    /// Files `programs` under `channels`. Every channel gets a guide, empty
    /// when nothing matched, so it stays listed and tunable.
    func lineup(source: LiveTVProvider, channels: [LiveChannel], programs: [LiveProgram]) -> LiveTVLineup

    /// The library copy of a past airing (in practice the DVR's recording of
    /// it), or nil when there is none.
    @MainActor func recording(for program: LiveProgram, source: LiveTVProvider) async throws -> MediaItem?

    /// Tunes `channel` and picks the stream: the tuned stream itself when
    /// `allowsDirectPlay` and the server offers it, otherwise a server stream.
    @MainActor func tune(
        _ channel: LiveChannel,
        source: LiveTVProvider,
        allowsDirectPlay: Bool
    ) async throws -> LiveTuneResult
}
