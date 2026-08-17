import Foundation

/// The complete vocabulary Dusk is allowed to report.
///
/// Adding an event means adding a case here. `AnalyticsEvent` cannot be built
/// from a free-form string, so the reported vocabulary is always exactly this
/// list — which is what keeps the privacy policy's description of it accurate.
///
/// Only the name and its properties go over the wire. What an event *means* is
/// documented here and in `docs/analytics.md`.
enum AnalyticsEventName: String, CaseIterable, Sendable {
    /// Dusk was opened or brought to the foreground. Sent at most once per
    /// device per calendar day, so the daily count is an active-device count.
    case appOpened = "app_opened"

    /// The prompt ladder passed its gate and asked for the sheet to be
    /// presented. Compare against `supporter_sheet_shown` with `source=prompt`:
    /// a gap means presentation is failing, not that the gate is wrong.
    case supporterPromptTriggered = "supporter_prompt_triggered"

    /// The Support Dusk sheet actually appeared on screen.
    /// Props: `source` (`prompt`/`settings`), `milestone` when source is prompt.
    case supporterSheetShown = "supporter_sheet_shown"

    /// The sheet was closed by a button. Props: `control`
    /// (`maybe_later`/`close`), `source`. Swipe-to-dismiss is not reported.
    case supporterDismissed = "supporter_dismissed"

    /// A tip or subscription row was tapped, before the App Store sheet
    /// appears. Props: `product`, `source`.
    case supporterPurchaseTapped = "supporter_purchase_tapped"

    /// A purchase completed and verified. Props: `product`. Revenue itself
    /// lives in App Store Connect; this exists so the shown-to-purchased ratio
    /// is computable.
    case supporterPurchaseCompleted = "supporter_purchase_completed"

    /// The user backed out of the payment sheet, or it stayed pending.
    /// Props: `product`.
    case supporterPurchaseCancelled = "supporter_purchase_cancelled"

    /// A purchase threw an error. Props: `product`. An error signal, not a
    /// funnel step.
    case supporterPurchaseFailed = "supporter_purchase_failed"

    /// Restore Purchases was tapped. Props: `source`.
    case supporterRestoreTapped = "supporter_restore_tapped"

    /// Manage Subscription was tapped (iOS only, active subscriptions only).
    case supporterManageSubscriptionTapped = "supporter_manage_subscription_tapped"

    /// An outbound link in the sheet was tapped.
    /// Props: `link` (`privacy`/`terms`/`about_me`/`github`).
    case supporterLinkTapped = "supporter_link_tapped"

    /// The sheet rendered with no purchasable products, so nothing could be
    /// bought. A steady stream here means the App Store products are not
    /// resolving in production.
    case supporterProductsUnavailable = "supporter_products_unavailable"

    /// Try Again was tapped on the products-unavailable state.
    case supporterProductsRetryTapped = "supporter_products_retry_tapped"

    /// The alternate app icon picker was opened.
    case supporterIconPickerOpened = "supporter_icon_picker_opened"

    /// An alternate app icon was applied. Props: `icon`.
    case supporterIconApplied = "supporter_icon_applied"

    /// Sent as a Rybbit pageview rather than a custom event, so the built-in
    /// users / sessions / retention / countries dashboards are driven by it.
    /// Everything else is a custom event.
    var isPageview: Bool { self == .appOpened }

    /// Rybbit groups by path, so each event is attributed to the screen it
    /// happened on. These are synthetic — the app has no URLs.
    var path: String {
        switch self {
        case .appOpened: "/app"
        case .supporterIconPickerOpened, .supporterIconApplied: "/supporter/icons"
        default: "/supporter"
        }
    }
}

/// A property value on an event. Rybbit only accepts strings and numbers, with
/// no nesting and a 2 KB cap on the whole property bag — which doubles as a
/// useful limit, since it stops this from quietly becoming a place where
/// arbitrary user data ends up.
enum AnalyticsValue: Sendable, Encodable {
    case string(String)
    case int(Int)

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        }
    }
}

/// One reportable event: a name from the fixed vocabulary plus flat properties.
struct AnalyticsEvent: Sendable {
    let name: AnalyticsEventName
    let properties: [String: AnalyticsValue]

    init(_ name: AnalyticsEventName, _ properties: [String: AnalyticsValue] = [:]) {
        self.name = name
        self.properties = properties
    }
}

/// Where a supporter interaction happened, reported as the `source` property.
enum AnalyticsSupporterSource: String, Sendable {
    case prompt
    case settings
}
