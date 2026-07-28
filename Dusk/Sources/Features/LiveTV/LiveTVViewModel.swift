import Foundation

@MainActor
@Observable
final class LiveTVViewModel {
    private let plexService: PlexService

    private(set) var provider: PlexLiveTVProvider?
    private(set) var channels: [PlexLiveChannel] = []
    private(set) var lineup: PlexLiveTVLineup?
    private(set) var nowPlayingLineup: PlexLiveTVLineup?
    private(set) var selectedDate = Calendar.current.startOfDay(for: .now)
    private(set) var isLoading = false
    private(set) var isAvailable = false
    private(set) var error: String?

    private var loadedDate: Date?
    private var discoveryCompleted = false

    init(plexService: PlexService) {
        self.plexService = plexService
    }

    func discover() async {
        guard !discoveryCompleted else { return }
        do {
            provider = try await plexService.getLiveTVProvider()
            isAvailable = provider != nil
            discoveryCompleted = true
        } catch {
            // Live TV is optional. A discovery failure must not block the rest
            // of Dusk, but opening the destination can retry and show details.
            isAvailable = false
        }
    }

    func load(force: Bool = false) async {
        guard !isLoading else { return }
        if !force, lineup != nil, Calendar.current.isDate(loadedDate ?? .distantPast, inSameDayAs: selectedDate) {
            return
        }

        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            if provider == nil {
                provider = try await plexService.getLiveTVProvider()
            }
            guard let provider else {
                isAvailable = false
                discoveryCompleted = true
                lineup = nil
                return
            }

            isAvailable = true
            discoveryCompleted = true
            if channels.isEmpty || force {
                channels = try await plexService.getLiveTVChannels(provider: provider)
            }
            lineup = try await plexService.getLiveTVGuide(
                provider: provider,
                channels: channels,
                date: selectedDate
            )
            loadedDate = selectedDate
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadNowPlaying(force: Bool = false) async {
        guard !isLoading else { return }
        guard force || nowPlayingLineup == nil else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            if provider == nil {
                provider = try await plexService.getLiveTVProvider()
            }
            guard let provider else {
                isAvailable = false
                discoveryCompleted = true
                return
            }
            isAvailable = true
            discoveryCompleted = true
            if channels.isEmpty {
                channels = try await plexService.getLiveTVChannels(provider: provider)
            }
            nowPlayingLineup = try await plexService.getLiveTVNowPlaying(
                provider: provider,
                channels: channels
            )
        } catch {
            self.error = error.localizedDescription
        }
    }

    func selectDate(_ date: Date) async {
        selectedDate = Calendar.current.startOfDay(for: date)
        await load(force: true)
    }

    func imageURL(for path: String?, width: Int, height: Int) -> URL? {
        plexService.imageURL(for: path, width: width, height: height)
    }

    var dateOptions: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        return (-1...7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }
}
