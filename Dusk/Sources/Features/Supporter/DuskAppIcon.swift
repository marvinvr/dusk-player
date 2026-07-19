import SwiftUI

/// The app icon variants offered as a supporter perk. The raw value is stable
/// and only used for identity; the alternate icon name must match the
/// Icon Composer bundle basename registered in project.yml
/// (`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`).
///
/// Alternate icons are iOS/iPadOS-only: tvOS alternates would need full
/// layered image stacks, so the Apple TV app always uses the primary icon and
/// the supporter UI there only showcases the variants.
enum DuskAppIcon: String, CaseIterable, Identifiable {
    case dusk
    case dawn
    case midnight
    case neon
    case mono
    case aurora
    case goldenHour

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
        }
    }

    /// Only the primary icon is free; every alternate is a supporter perk.
    var requiresSupporter: Bool { self != .dusk }

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
