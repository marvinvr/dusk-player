import SwiftUI

/// Gating rules for the supporter prompt ladder. Deliberately conservative:
/// a device sees at most `milestones.count` prompts, ever, months apart, and
/// only while the user's usage keeps growing — light users stop qualifying
/// instead of getting nagged. Existing users have no recorded install date,
/// so their clock starts with the first launch of the release that ships
/// this feature — which is the intended behavior.
enum SupporterPromptGate {
    struct Milestone {
        /// Days since first launch before this prompt may fire.
        let minDaysSinceFirstLaunch: Int
        /// Distinct usage days before this prompt may fire.
        let minUsageDays: Int
        /// Days since the previous prompt, so a user whose usage catches up
        /// to several milestones at once still sees them well spaced.
        let minDaysSincePreviousPrompt: Int
    }

    /// One entry per prompt a device may ever see; the ladder ends for good
    /// after the last entry. The final prompt tells the user it is the last
    /// ask — keep that promise: do not extend the ladder without an explicit
    /// product decision (docs/supporter.md).
    static let milestones: [Milestone] = [
        Milestone(minDaysSinceFirstLaunch: 7, minUsageDays: 3, minDaysSincePreviousPrompt: 0),
        Milestone(minDaysSinceFirstLaunch: 30, minUsageDays: 10, minDaysSincePreviousPrompt: 14),
        Milestone(minDaysSinceFirstLaunch: 90, minUsageDays: 25, minDaysSincePreviousPrompt: 30),
    ]

    @MainActor
    static func shouldShow(
        preferences: UserPreferences,
        store: SupporterStore,
        now: Date = .now
    ) -> Bool {
        guard preferences.supporterPromptCount < milestones.count else { return false }
        // Checked against StoreKit history, which syncs across devices on the
        // same Apple ID — a supporter's other devices never prompt.
        guard !store.isSupporter else { return false }

        let milestone = milestones[preferences.supporterPromptCount]

        let daysSinceFirstLaunch = Calendar.current.dateComponents(
            [.day],
            from: preferences.firstLaunchDate,
            to: now
        ).day ?? 0
        guard daysSinceFirstLaunch >= milestone.minDaysSinceFirstLaunch else { return false }
        guard preferences.usageDayCount >= milestone.minUsageDays else { return false }

        if let lastPrompt = preferences.supporterLastPromptDate {
            let daysSinceLastPrompt = Calendar.current.dateComponents(
                [.day],
                from: lastPrompt,
                to: now
            ).day ?? 0
            guard daysSinceLastPrompt >= milestone.minDaysSincePreviousPrompt else { return false }
        }

        return true
    }
}

/// Presents the supporter prompts over the main tab shell. Applied in
/// `MainTabView` so it only runs once the user is signed in and connected —
/// usage days are only counted for real sessions.
struct SupporterPromptPresenter: ViewModifier {
    @Environment(UserPreferences.self) private var preferences
    @Environment(SupporterStore.self) private var supporterStore
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsPrompt = false
    @State private var promptNumber = 1

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
                SupporterView(context: .prompt(number: promptNumber))
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

        // Advance the ladder the moment it actually presents.
        preferences.registerSupporterPrompt()
        promptNumber = preferences.supporterPromptCount
        showsPrompt = true
    }
}

extension View {
    func supporterPromptPresenter() -> some View {
        modifier(SupporterPromptPresenter())
    }
}
