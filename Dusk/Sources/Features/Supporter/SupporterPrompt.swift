import SwiftUI

/// Gating rules for supporter prompts. The initial ladder is deliberately
/// conservative, followed by at most one prompt per year for people who keep
/// using Dusk. Existing users have no recorded install date, so their clock
/// starts with the first launch of the release that ships this feature.
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

    static let initialMilestones: [Milestone] = [
        Milestone(minDaysSinceFirstLaunch: 7, minUsageDays: 3, minDaysSincePreviousPrompt: 0),
        Milestone(minDaysSinceFirstLaunch: 30, minUsageDays: 10, minDaysSincePreviousPrompt: 14),
        Milestone(minDaysSinceFirstLaunch: 90, minUsageDays: 25, minDaysSincePreviousPrompt: 30),
    ]

    private static let annualStartDays = 365
    private static let firstAnnualPromptGapDays = 180
    private static let annualPromptGapDays = 365
    private static let annualUsageDaysSincePreviousPrompt = 12

    @MainActor
    static func shouldShow(
        preferences: UserPreferences,
        store: SupporterStore,
        now: Date = .now
    ) -> Bool {
        // Checked against StoreKit history, which syncs across devices on the
        // same Apple ID — a supporter's other devices never prompt.
        guard !store.isSupporter else { return false }

        let daysSinceFirstLaunch = Calendar.current.dateComponents(
            [.day],
            from: preferences.firstLaunchDate,
            to: now
        ).day ?? 0

        if preferences.supporterPromptCount >= initialMilestones.count {
            return shouldShowAnnualPrompt(
                preferences: preferences,
                daysSinceFirstLaunch: daysSinceFirstLaunch,
                now: now
            )
        }

        let milestone = initialMilestones[preferences.supporterPromptCount]
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

    @MainActor
    private static func shouldShowAnnualPrompt(
        preferences: UserPreferences,
        daysSinceFirstLaunch: Int,
        now: Date
    ) -> Bool {
        guard daysSinceFirstLaunch >= annualStartDays else { return false }
        guard let lastPrompt = preferences.supporterLastPromptDate else { return false }

        let daysSinceLastPrompt = Calendar.current.dateComponents(
            [.day],
            from: lastPrompt,
            to: now
        ).day ?? 0
        let isFirstAnnualPrompt = preferences.supporterPromptCount == initialMilestones.count
        let requiredGap = isFirstAnnualPrompt ? firstAnnualPromptGapDays : annualPromptGapDays
        guard daysSinceLastPrompt >= requiredGap else { return false }

        let usageDaysSinceLastPrompt =
            preferences.usageDayCount - preferences.supporterLastPromptUsageDayCount
        return usageDaysSinceLastPrompt >= annualUsageDaysSincePreviousPrompt
    }
}

/// Presents the supporter prompts over the main tab shell on iOS and iPadOS.
/// Applied in `MainTabView` so it only runs once the user is signed in and
/// connected — usage days are only counted for real sessions. Apple TV keeps
/// support discoverable in Settings without presenting automatic prompts.
struct SupporterPromptPresenter: ViewModifier {
    @Environment(UserPreferences.self) private var preferences
    @Environment(SupporterStore.self) private var supporterStore
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(AnalyticsClient.self) private var analytics: AnalyticsClient?
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
        // Reported before presentation, so this can be compared against
        // `supporter_sheet_shown` to catch a prompt that burns a milestone
        // without the sheet ever reaching the screen.
        analytics?.record(AnalyticsEvent(.supporterPromptTriggered, [
            "milestone": .int(promptNumber)
        ]))
        showsPrompt = true
    }
}

extension View {
    func supporterPromptPresenter() -> some View {
        modifier(SupporterPromptPresenter())
    }
}
