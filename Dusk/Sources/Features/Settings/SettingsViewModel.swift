import Foundation

@MainActor
@Observable
final class SettingsViewModel {
    var showServerPicker = false
    var showHomeUserPicker = false
    private(set) var availableServers: [PlexServer] = []
    private var isRefreshingServers = false
    private(set) var imageCacheClearedAt: Date?
    private(set) var imageCacheSize: Int = AppImageCache.shared.currentDiskUsage

    var hasMultipleServers: Bool {
        availableServers.count > 1
    }

    var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var connectionType: String {
        "Connected"
    }

    var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(imageCacheSize), countStyle: .file)
    }

    var storageFooterText: String {
        let base = "Clear Image Cache removes locally cached posters and artwork so they re-download on demand. Cached images also refresh automatically after 3 days."

        guard imageCacheClearedAt != nil else { return base }
        return "\(base) Image cache cleared."
    }

    func clearImageCache() {
        AppImageCache.clear()
        imageCacheClearedAt = .now
        imageCacheSize = AppImageCache.shared.currentDiskUsage
    }

    func refreshAvailableServers(using plexService: PlexService) async {
        guard !isRefreshingServers else { return }
        isRefreshingServers = true
        defer { isRefreshingServers = false }

        do {
            availableServers = try await plexService.discoverServers()
        } catch {
            // Discovery here only controls whether server switching is relevant.
            // Keep the last known list and avoid surfacing transient refresh errors.
        }
    }

    func connect(to server: PlexServer, using plexService: PlexService) async throws {
        try await plexService.connect(to: server)
        showServerPicker = false
    }
}
