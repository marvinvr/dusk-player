import SwiftUI

/// Gating rules for the one-time supporter prompt. Deliberately conservative:
/// it fires once per device, ever, and only for people who have actually been
/// using the app for a while. Existing users have no recorded install date,
/// so their 7-day clock starts with the first launch of the release that
/// ships this feature — which is the intended behavior.
enum SupporterPromptGate {
    static let requiredDaysSinceFirstLaunch = 7
    static let requiredUsageDays = 3

    @MainActor
    static func shouldShow(
        preferences: UserPreferences,
        store: SupporterStore,
        now: Date = .now
    ) -> Bool {
        guard !preferences.supporterPromptShown else { return false }
        // Checked against StoreKit history, which syncs across devices on the
        // same Apple ID — a supporter's other devices never prompt.
        guard !store.isSupporter else { return false }

        let daysSinceFirstLaunch = Calendar.current.dateComponents(
            [.day],
            from: preferences.firstLaunchDate,
            to: now
        ).day ?? 0

        return daysSinceFirstLaunch >= requiredDaysSinceFirstLaunch
            && preferences.usageDayCount >= requiredUsageDays
    }
}

/// Presents the one-time supporter prompt over the main tab shell. Applied in
/// `MainTabView` so it only runs once the user is signed in and connected —
/// usage days are only counted for real sessions.
struct SupporterPromptPresenter: ViewModifier {
    @Environment(UserPreferences.self) private var preferences
    @Environment(SupporterStore.self) private var supporterStore
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsPrompt = false

    func body(content: Content) -> some View {
        content
            .task {
                await registerAndEvaluate()
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task { await registerAndEvaluate() }
            }
            .sheet(isPresented: $showsPrompt) {
                SupporterView(context: .prompt)
            }
    }

    private func registerAndEvaluate() async {
        preferences.registerUsageDay()

        // Small grace period so the prompt never pops mid-launch; if the user
        // starts playback in the meantime, skip and retry another day.
        try? await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        guard !showsPrompt, !playback.showPlayer else { return }
        guard SupporterPromptGate.shouldShow(preferences: preferences, store: supporterStore) else { return }

        // Mark as shown when it actually presents, and never again.
        preferences.supporterPromptShown = true
        showsPrompt = true
    }
}

extension View {
    func supporterPromptPresenter() -> some View {
        modifier(SupporterPromptPresenter())
    }
}
