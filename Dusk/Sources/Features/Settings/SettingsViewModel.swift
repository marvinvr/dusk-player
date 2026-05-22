import Foundation

@MainActor
@Observable
final class SettingsViewModel {
    var showServerPicker = false
    private(set) var availableServers: [PlexServer] = []
    private(set) var isLoadingServers = false
    private(set) var serverError: String?
    private(set) var imageCacheClearedAt: Date?
    private(set) var imageCacheSize: Int = AppImageCache.shared.currentDiskUsage

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

    func loadServers(using plexService: PlexService) async {
        isLoadingServers = true
        serverError = nil

        do {
            let servers = try await plexService.discoverServers()
            if servers.isEmpty {
                serverError = "No servers found."
            } else {
                availableServers = servers
                showServerPicker = true
            }
        } catch {
            serverError = error.localizedDescription
        }

        isLoadingServers = false
    }

    func connect(to server: PlexServer, using plexService: PlexService) async throws {
        try await plexService.connect(to: server)
        showServerPicker = false
        availableServers = []
    }
}
