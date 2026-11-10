import SwiftUI

/// The app icon variants offered as a supporter perk. The raw value is stable
/// and only used for identity; the alternate icon name must match the
/// Icon Composer bundle basename registered in project.yml
/// (`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`).
///
/// Alternate icons are iOS/iPadOS-only: tvOS alternates would need full
/// layered image stacks, so the Apple TV app always uses the primary icon and
/// the supporter UI there only showcases the variants.
///
/// Access comes in three steps: the primary icon is free, the classic
/// alternates come with an active subscription or a tip from Generous up, and
/// Velvet/Emerald/Gilded only with an active subscription. `SupporterStore`
/// switches back to the primary icon when a subscription lapses. TestFlight
/// unlocks every icon and never reverts (`TestFlightInstall`).
enum DuskAppIcon: String, CaseIterable, Identifiable {
    case dusk
    case dawn
    case midnight
    case neon
    case mono
    case aurora
    case goldenHour
    case velvet
    case emerald
    case gilded

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dusk: "Dusk"
        case .dawn: "Dawn"
        case .midnight: "Midnight"
        case .neon: "Neon"
        case .mono: "Mono"
        case .aurora: "Aurora"
        case .goldenHour: "Golden Hour"
        case .velvet: "Velvet"
        case .emerald: "Emerald"
        case .gilded: "Gilded"
        }
    }

    /// Name passed to `setAlternateIconName`; nil selects the primary icon.
    var alternateIconName: String? {
        switch self {
        case .dusk: nil
        case .dawn: "DuskIconDawn"
        case .midnight: "DuskIconMidnight"
        case .neon: "DuskIconNeon"
        case .mono: "DuskIconMono"
        case .aurora: "DuskIconAurora"
        case .goldenHour: "DuskIconGoldenHour"
        case .velvet: "DuskIconVelvet"
        case .emerald: "DuskIconEmerald"
        case .gilded: "DuskIconGilded"
        }
    }

    /// Bundled preview rendered by the icon generator; shown in the picker and
    /// the supporter sheet's perk showcase on every platform.
    var previewImageName: String {
        switch self {
        case .dusk: "IconPreviewDusk"
        case .dawn: "IconPreviewDawn"
        case .midnight: "IconPreviewMidnight"
        case .neon: "IconPreviewNeon"
        case .mono: "IconPreviewMono"
        case .aurora: "IconPreviewAurora"
        case .goldenHour: "IconPreviewGoldenHour"
        case .velvet: "IconPreviewVelvet"
        case .emerald: "IconPreviewEmerald"
        case .gilded: "IconPreviewGilded"
        }
    }

    /// The launch splash logo in this icon's colours: `LaunchLogo` itself for
    /// the primary icon, the others derived from each icon's mark by
    /// `scripts/generate_launch_logo_variants.py`.
    var launchLogoImageName: String {
        guard let alternateIconName else { return "LaunchLogo" }
        return alternateIconName.replacingOccurrences(of: "DuskIcon", with: "LaunchLogo")
    }

    /// The icon on the Home Screen right now. Reads the system's applied icon,
    /// not the picker's selection or the supporter state, so it already
    /// reflects a revert after a lapsed subscription (and keeps the old icon
    /// until that revert actually went through). Always the primary icon on
    /// tvOS, where alternates are preview-only.
    @MainActor
    static var applied: DuskAppIcon {
        #if os(iOS)
        current
        #else
        .dusk
        #endif
    }

    /// Only the primary icon is free; every alternate is a supporter perk.
    var requiresSupporter: Bool { self != .dusk }

    /// Exclusive to an active subscription; no tip unlocks these.
    var requiresSubscription: Bool {
        switch self {
        case .velvet, .emerald, .gilded: true
        default: false
        }
    }

    /// The primary icon and the classic alternates (an active subscription, or
    /// a tip from Generous up).
    static var supporterIcons: [DuskAppIcon] { allCases.filter { !$0.requiresSubscription } }

    /// Icons that only stay unlocked while a subscription is active.
    static var subscriptionIcons: [DuskAppIcon] { allCases.filter(\.requiresSubscription) }

    func isUnlocked(hasIconAccess: Bool, hasActiveSubscription: Bool) -> Bool {
        if requiresSubscription { return hasActiveSubscription }
        return !requiresSupporter || hasIconAccess
    }

    #if os(iOS)
    @MainActor
    static var current: DuskAppIcon {
        guard let activeName = UIApplication.shared.alternateIconName else { return .dusk }
        return allCases.first { $0.alternateIconName == activeName } ?? .dusk
    }

    @MainActor
    static func select(_ icon: DuskAppIcon) async throws {
        guard UIApplication.shared.supportsAlternateIcons else { return }
        guard UIApplication.shared.alternateIconName != icon.alternateIconName else { return }
        try await UIApplication.shared.setAlternateIconName(icon.alternateIconName)
    }
    #endif
}

extension SupporterStore {
    func isUnlocked(_ icon: DuskAppIcon) -> Bool {
        if TestFlightInstall.isTestFlight { return true }
        return icon.isUnlocked(hasIconAccess: hasIconAccess, hasActiveSubscription: hasActiveSubscription)
    }
}
