import SwiftUI

/// Dusk's type scale.
///
/// **Why this exists.** SwiftUI's semantic text styles resolve to *much* larger
/// point sizes on tvOS than on iOS (`.subheadline` = 38pt, `.title3` = 48pt,
/// `.title` = 76pt, and most styles default to Medium weight). The app was tuned
/// by eye on iOS, so every shared view inflates by 2.1–2.7× on the TV. `DuskFont`
/// is the single place where tvOS gets explicit, hand-tuned point sizes while iOS
/// keeps exactly the style it uses today.
///
/// **Invariants.**
/// 1. iOS rendering must stay byte-identical. Nothing here invents an iOS value:
///    every token takes the call site's current iOS style through `ios:` and
///    returns it unchanged on non-tvOS platforms.
/// 2. tvOS views go through `DuskFont` — never raw semantic text styles
///    (`.headline`, `.title3`, `.caption`, …) in a tvOS-reachable path.
///
/// **Three entry points.**
///
/// 1. Shared views (the common case) — pass the style the site uses today:
///
/// ```swift
/// Text(item.title)
///     .font(DuskFont.sectionHeader(ios: .title3.bold()))   // tvOS 33 semibold
/// ```
///
/// 2. tvOS-only code paths (already inside `#if os(tvOS)`, or a `.tv` layout
///    preset) — skip the meaningless `ios:` argument:
///
/// ```swift
/// #if os(tvOS)
/// Text("Settings").font(DuskFont.TV.pageTitle)             // 48 bold
/// #endif
/// ```
///
/// 3. Sites where iOS deliberately applies **no** `.font` at all (the text
///    inherits `.body`) — use the modifier so iOS keeps inheriting:
///
/// ```swift
/// Text(serverName).duskFont(tvOnly: DuskFont.TV.rowValue) // tvOS 27, iOS untouched
/// ```
///
/// Raw point sizes, for layout structs that store a `CGFloat` rather than a
/// `Font` (hero layouts, player overlay metrics):
/// `DuskFont.TV.Size.heroTitle` → `56`.
///
/// **Chaining rule.** Modifiers chained onto the result apply on *both*
/// platforms, so only chain what both platforms should have; anything
/// platform-specific belongs in the `ios:` argument.
///
/// ```swift
/// // iOS was `.subheadline.monospacedDigit()` → still is; tvOS gets 25 medium + digits
/// .font(DuskFont.metadata(ios: .subheadline).monospacedDigit())
/// ```
///
/// **Escape hatch.** The tokens name *roles*, not every pixel. A genuine one-off
/// (the `plex.tv/link` code, a glyph sized from a layout metric) may stay an
/// explicit `.system(size:)` inside `#if os(tvOS)`.
///
/// The ladder: heroTitle 56 → pageTitle 48 → playerOverlayTitle 44 → sectionHeader
/// 33 → heroSubtitle 31 → glyphMedium 30 → rowTitle/pageSubtitle 29 →
/// body/rowValue/buttonLabel 27 → cardTitle/metadata/groupHeader 25 →
/// cardSubtitle/caption/glyphSmall 23 → badge 21.
enum DuskFont {

    // MARK: - tvOS values

    /// The tvOS side of the scale, usable directly from tvOS-only code.
    ///
    /// These are tvOS point sizes. Reference them only inside `#if os(tvOS)` or
    /// through `duskFont(tvOnly:)` — using one in a path iOS also renders would
    /// break the "iOS unchanged" invariant.
    enum TV {

        /// Raw point sizes, for layout structs that store a `CGFloat`.
        enum Size {
            static let heroTitle: CGFloat = 56
            static let heroSubtitle: CGFloat = 31
            static let pageTitle: CGFloat = 48
            static let pageSubtitle: CGFloat = 29
            static let sectionHeader: CGFloat = 33
            static let groupHeader: CGFloat = 25
            static let rowTitle: CGFloat = 29
            static let rowValue: CGFloat = 27
            static let cardTitle: CGFloat = 25
            static let cardSubtitle: CGFloat = 23
            static let body: CGFloat = 27
            static let metadata: CGFloat = 25
            static let caption: CGFloat = 23
            static let buttonLabel: CGFloat = 27
            static let badge: CGFloat = 21
            static let glyphSmall: CGFloat = 23
            static let glyphMedium: CGFloat = 30
            static let glyphLarge: CGFloat = 52
            static let playerTitle: CGFloat = 33
            static let playerTitleCompact: CGFloat = 27
            static let playerOverlayTitle: CGFloat = 44
        }

        /// Hero artwork title fallback when there is no clear-logo image.
        static var heroTitle: Font { .system(size: Size.heroTitle, weight: .bold) }
        /// `heroTitle` for the call sites that already use a rounded design.
        static var heroTitleRounded: Font {
            .system(size: Size.heroTitle, weight: .bold, design: .rounded)
        }
        /// The featured item's own title inside a hero (episode name under the logo).
        static var heroSubtitle: Font { .system(size: Size.heroSubtitle, weight: .semibold) }

        /// Top-level screen title ("Settings", "Choose Server", "Who's Watching?").
        static var pageTitle: Font { .system(size: Size.pageTitle, weight: .bold) }
        /// `pageTitle` for the call sites that already use a rounded design.
        static var pageTitleRounded: Font {
            .system(size: Size.pageTitle, weight: .bold, design: .rounded)
        }
        /// Paragraph directly under a `pageTitle`.
        static var pageSubtitle: Font { .system(size: Size.pageSubtitle, weight: .regular) }

        /// Shelf / section header ("Synopsis", "Cast", "Seasons", "Episodes").
        static var sectionHeader: Font { .system(size: Size.sectionHeader, weight: .semibold) }
        /// Settings **section** header — the small, secondary-coloured eyebrow above a group.
        static var groupHeader: Font { .system(size: Size.groupHeader, weight: .semibold) }

        /// Primary text of a list / settings row.
        static var rowTitle: Font { .system(size: Size.rowTitle, weight: .medium) }
        /// Trailing detail or current value of a list / settings row.
        static var rowValue: Font { .system(size: Size.rowValue, weight: .regular) }

        /// Poster / episode / video card title (`DuskPosterMetrics.titleFont`).
        static var cardTitle: Font { .system(size: Size.cardTitle, weight: .semibold) }
        /// Card subtitle, cast name, watched checkmark (`DuskPosterMetrics.subtitleFont`).
        static var cardSubtitle: Font { .system(size: Size.cardSubtitle, weight: .regular) }

        /// Prose: synopses, descriptions, expandable summaries.
        static var body: Font { .system(size: Size.body, weight: .regular) }
        /// `2024 · PG-13 · 2h 10m`, genres, director, studio, air dates, ratings, time readouts.
        static var metadata: Font { .system(size: Size.metadata, weight: .medium) }
        /// Footers, hints, secondary captions, menu subtitles.
        static var caption: Font { .system(size: Size.caption, weight: .regular) }

        /// Play / Resume / Browse / Retry / Sign In / Show More, glass capsules.
        static var buttonLabel: Font { .system(size: Size.buttonLabel, weight: .semibold) }
        /// One- or two-word pill over artwork, player tooltips. Below the prose floor by design.
        static var badge: Font { .system(size: Size.badge, weight: .bold) }

        /// Inline icon beside text.
        static var glyphSmall: Font { .system(size: Size.glyphSmall, weight: .regular) }
        /// Standalone control icon.
        static var glyphMedium: Font { .system(size: Size.glyphMedium, weight: .regular) }
        /// Empty / error state glyph, and artwork placeholders that fill a card.
        static var glyphLarge: Font { .system(size: Size.glyphLarge, weight: .regular) }

        /// Player HUD media title.
        static var playerTitle: Font { .system(size: Size.playerTitle, weight: .semibold) }
        /// Player HUD media title in the compact layout. The secondary (episode)
        /// title under it uses `metadata`, one step down.
        static var playerTitleCompact: Font {
            .system(size: Size.playerTitleCompact, weight: .semibold)
        }
        /// Up-Next full-screen overlay title.
        static var playerOverlayTitle: Font {
            .system(size: Size.playerOverlayTitle, weight: .bold)
        }
    }

    // MARK: - Tokens

    // Each token returns the tvOS value on tvOS and `ios` verbatim everywhere else.
    // See `resolve` below: the iOS branch never constructs a font of its own.

    /// Hero artwork title fallback when there is no clear-logo image.
    static func heroTitle(ios: Font) -> Font { resolve(TV.heroTitle, ios) }
    /// `heroTitle` where the call site already renders a rounded design on tvOS.
    static func heroTitleRounded(ios: Font) -> Font { resolve(TV.heroTitleRounded, ios) }
    /// The featured item's own title inside a hero (episode name under the logo).
    static func heroSubtitle(ios: Font) -> Font { resolve(TV.heroSubtitle, ios) }

    /// Top-level screen title.
    static func pageTitle(ios: Font) -> Font { resolve(TV.pageTitle, ios) }
    /// `pageTitle` where the call site already renders a rounded design on tvOS.
    static func pageTitleRounded(ios: Font) -> Font { resolve(TV.pageTitleRounded, ios) }
    /// Paragraph directly under a `pageTitle`.
    static func pageSubtitle(ios: Font) -> Font { resolve(TV.pageSubtitle, ios) }

    /// Shelf / section header.
    static func sectionHeader(ios: Font) -> Font { resolve(TV.sectionHeader, ios) }
    /// Settings section header (secondary colour, above a group of rows).
    static func groupHeader(ios: Font) -> Font { resolve(TV.groupHeader, ios) }

    /// Primary text of a list / settings row.
    static func rowTitle(ios: Font) -> Font { resolve(TV.rowTitle, ios) }
    /// Trailing detail or current value of a list / settings row.
    static func rowValue(ios: Font) -> Font { resolve(TV.rowValue, ios) }

    /// Poster / episode / video card title.
    static func cardTitle(ios: Font) -> Font { resolve(TV.cardTitle, ios) }
    /// Card subtitle, cast name, watched checkmark.
    static func cardSubtitle(ios: Font) -> Font { resolve(TV.cardSubtitle, ios) }

    /// Prose: synopses, descriptions, expandable summaries.
    static func body(ios: Font) -> Font { resolve(TV.body, ios) }
    /// Metadata taglines, genres, credits, air dates, ratings, time readouts.
    static func metadata(ios: Font) -> Font { resolve(TV.metadata, ios) }
    /// Footers, hints, secondary captions, menu subtitles.
    static func caption(ios: Font) -> Font { resolve(TV.caption, ios) }

    /// Play / Resume / Browse / Retry / Sign In / Show More, glass capsules.
    static func buttonLabel(ios: Font) -> Font { resolve(TV.buttonLabel, ios) }
    /// One- or two-word pill over artwork, player tooltips.
    static func badge(ios: Font) -> Font { resolve(TV.badge, ios) }

    /// Inline icon beside text.
    static func glyphSmall(ios: Font) -> Font { resolve(TV.glyphSmall, ios) }
    /// Standalone control icon.
    static func glyphMedium(ios: Font) -> Font { resolve(TV.glyphMedium, ios) }
    /// Empty / error state glyph.
    static func glyphLarge(ios: Font) -> Font { resolve(TV.glyphLarge, ios) }

    /// Player HUD media title.
    static func playerTitle(ios: Font) -> Font { resolve(TV.playerTitle, ios) }
    /// Player HUD compact media title.
    static func playerTitleCompact(ios: Font) -> Font { resolve(TV.playerTitleCompact, ios) }
    /// Up-Next full-screen overlay title.
    static func playerOverlayTitle(ios: Font) -> Font { resolve(TV.playerOverlayTitle, ios) }

    // MARK: - Resolution

    private static func resolve(_ tv: @autoclosure () -> Font, _ ios: Font) -> Font {
        #if os(tvOS)
        return tv()
        #else
        return ios
        #endif
    }
}

extension View {
    /// Applies a tvOS font and leaves every other platform completely untouched.
    ///
    /// For the handful of call sites where iOS deliberately applies no `.font` at
    /// all and the text inherits from its container. Passing `.font(nil)` there
    /// would *reset* an inherited font instead of keeping it, so this modifier
    /// applies nothing on non-tvOS platforms.
    ///
    /// ```swift
    /// Text(serverName).duskFont(tvOnly: DuskFont.TV.rowValue)
    /// ```
    @ViewBuilder
    func duskFont(tvOnly font: Font) -> some View {
        #if os(tvOS)
        self.font(font)
        #else
        self
        #endif
    }
}
