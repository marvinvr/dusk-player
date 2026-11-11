import SwiftUI

/// When the supporter prompt may show. Never pushy, but it keeps giving a
/// chance: a first ask once someone actually uses Dusk, then growing gaps
/// while they keep dismissing it. A tip snoozes it for a year; an active
/// subscription (either level, incl. Family Sharing) keeps it away entirely,
/// and after a lapse it waits a while before resuming the same schedule.
/// All intervals live here.
enum SupporterPromptSchedule {
    /// The first prompt: days since first launch and distinct usage days.
    static let firstPromptMinDays = 7
    static let firstPromptMinUsageDays = 3
    /// Gap after the 1st, 2nd, 3rd prompt …; the last value repeats.
    static let dismissalGapDays = [60, 120, 180]
    /// Distinct usage days since the previous prompt, so someone who barely
    /// opens the app isn't asked again just because time passed.
    static let minUsageDaysSincePreviousPrompt = 5
    /// Snooze after any tip, counted from that purchase.
    static let tipSnoozeDays = 365
    /// Earliest prompt after a subscription ends, counted from its expiry.
    static let lapseGraceDays = 30

    struct State: Equatable {
        var firstLaunchDate: Date
        var usageDayCount: Int
        var promptCount: Int
        var lastPromptDate: Date?
        var lastPromptUsageDayCount: Int
        var hasActiveSubscription: Bool
        /// Last known end of a subscription period (cached, so it also covers
        /// launch before StoreKit has answered).
        var lastSubscriptionExpiration: Date?
        var lastTipDate: Date?
    }

    /// Gap required after the given number of prompts already shown.
    static func gapDays(afterPromptCount count: Int) -> Int {
        guard count > 0 else { return 0 }
        return dismissalGapDays[min(count, dismissalGapDays.count) - 1]
    }

    static func shouldShow(_ state: State, now: Date = .now, calendar: Calendar = .current) -> Bool {
        func days(since date: Date) -> Int {
            calendar.dateComponents([.day], from: date, to: now).day ?? 0
        }

        guard !state.hasActiveSubscription else { return false }
        if let expiration = state.lastSubscriptionExpiration,
           expiration > now || days(since: expiration) < lapseGraceDays {
            return false
        }
        if let tip = state.lastTipDate, days(since: tip) < tipSnoozeDays {
            return false
        }

        guard days(since: state.firstLaunchDate) >= firstPromptMinDays,
              state.usageDayCount >= firstPromptMinUsageDays else { return false }

        guard let lastPrompt = state.lastPromptDate else { return true }
        guard days(since: lastPrompt) >= gapDays(afterPromptCount: max(state.promptCount, 1)) else { return false }
        return state.usageDayCount - state.lastPromptUsageDayCount >= minUsageDaysSincePreviousPrompt
    }

    @MainActor
    static func shouldShow(preferences: UserPreferences, store: SupporterStore, now: Date = .now) -> Bool {
        shouldShow(
            State(
                firstLaunchDate: preferences.firstLaunchDate,
                usageDayCount: preferences.usageDayCount,
                promptCount: preferences.supporterPromptCount,
                lastPromptDate: preferences.supporterLastPromptDate,
                lastPromptUsageDayCount: preferences.supporterLastPromptUsageDayCount,
                hasActiveSubscription: store.hasActiveSubscription,
                lastSubscriptionExpiration: store.lastKnownSubscriptionExpiration,
                lastTipDate: store.lastTipDate
            ),
            now: now
        )
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
            .duskPopUp(isPresented: $showsPrompt) {
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
        guard SupporterPromptSchedule.shouldShow(preferences: preferences, store: supporterStore) else { return }

        // Stamp the prompt the moment it actually presents; the schedule's
        // gap (weeks at least) also keeps it to one per session.
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
