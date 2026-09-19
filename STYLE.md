# Dusk Design System (v1.0)

## 1. Design Philosophy

Dusk is a **content-first** player. The UI should "recede" to let movie posters and cinematic backdrops lead the experience.

* **Modern Minimal:** Use thin strokes (1pt), large corner radii, and generous whitespace.
* **Glassmorphism:** Use system materials (`ultraThinMaterial`) and native **Liquid Glass** button styles for overlays, navigation bars, and actions.
* **Vibrant Accents:** Use a single brand color (**Sunset Coral**) for accents — progress, ratings, active states, and inline links. Do **not** use it as a primary action button fill (see §3.3); primary actions use neutral, contrasting Liquid Glass.

---

## 2. Color Palettes

### 2.1 Dark Mode (Dusk)

The default experience. Focuses on deep, cool-toned blacks to make OLED screens shine.

| Token | Hex | Usage |
| --- | --- | --- |
| **AppBackground** | `#090A0F` | Main window background. Deep twilight. |
| **AppSurface** | `#161824` | Cards, modals, and secondary backgrounds. |
| **AppAccent** | `#FF6B4A` | **Sunset Coral.** Play buttons, active states, progress. |
| **TextPrimary** | `#F2F2F7` | Titles and primary labels. |
| **TextSecondary** | `#8E95A8` | Metadata, captions, and disabled states. |

### 2.2 Light Mode (Dawn)

A crisp, high-clarity alternative. Avoids "pure" white to reduce eye strain.

| Token | Hex | Usage |
| --- | --- | --- |
| **AppBackground** | `#F5F7FA` | Main window background. Soft morning fog. |
| **AppSurface** | `#FFFFFF` | Cards and elevated surfaces. |
| **AppAccent** | `#FF6B4A` | **Sunset Coral.** Remains consistent for brand identity. |
| **TextPrimary** | `#1C1C1E` | Titles and primary labels. |
| **TextSecondary** | `#636366` | Metadata and secondary descriptions. |

---

## 3. Typography & UI Geometry

### 3.1 Fonts (SF Pro)

All type goes through `DuskFont` (`Dusk/Sources/Shared/DuskTypography.swift`).

**tvOS views go through `DuskFont` — never raw semantic text styles.** SwiftUI's
semantic styles resolve 2.1–2.7× larger on tvOS than on iOS (`.subheadline` = 38pt,
`.title3` = 48pt, `.title` = 76pt) and default to Medium weight, so any `.font(.headline)`
in a tvOS-reachable view is oversized by construction. `DuskFont` gives tvOS explicit
point sizes; iOS keeps the exact style the call site passes via `ios:`, so iOS
rendering is unchanged.

| Token | tvOS pt | tvOS weight | Applied to |
|---|---|---|---|
| `heroTitle` (`heroTitleRounded`) | 56 | Bold | Hero title text fallback (no clear-logo) |
| `glyphLarge` | 52 | Regular | Empty / error state glyphs, artwork placeholders |
| `pageTitle` (`pageTitleRounded`) | 48 | Bold | Top-level screen titles |
| `playerOverlayTitle` | 44 | Bold | Up-Next full-screen overlay title |
| `sectionHeader` | 33 | Semibold | Shelf headers, "Synopsis", "Cast", "Seasons", "Episodes" |
| `playerTitle` | 33 | Semibold | Player HUD media title |
| `heroSubtitle` | 31 | Semibold | Featured item title inside a hero |
| `glyphMedium` | 30 | Regular | Standalone control icons |
| `pageSubtitle` | 29 | Regular | Paragraph under a `pageTitle` |
| `rowTitle` | 29 | Medium | List / settings row primary text |
| `body` | 27 | Regular | Synopses, descriptions, expandable summaries |
| `rowValue` | 27 | Regular | Row detail / current value |
| `buttonLabel` | 27 | Semibold | Play, Resume, Browse, Retry, Sign In, Show More |
| `playerTitleCompact` | 27 | Semibold | Compact player HUD title (its secondary episode title uses `metadata`) |
| `cardTitle` | 25 | Semibold | Poster / episode / video card titles |
| `metadata` | 25 | Medium | `2024 · PG-13 · 2h 10m`, genres, credits, ratings, time readouts |
| `groupHeader` | 25 | Semibold | Settings section headers (secondary colour) |
| `cardSubtitle` | 23 | Regular | Card subtitles, cast names, watched checkmark |
| `caption` | 23 | Regular | Footers, hints, menu subtitles |
| `glyphSmall` | 23 | Regular | Inline icons beside text |
| `badge` | 21 | Bold | Pills over artwork, player tooltips |

Usage — shared views pass the style the site uses today; tvOS-only paths use the
`TV` namespace; sites where iOS deliberately sets no font use the modifier:

```swift
.font(DuskFont.sectionHeader(ios: .title3.bold()))        // shared
.font(DuskFont.metadata(ios: .subheadline).monospacedDigit())  // chained on both platforms
.font(DuskFont.TV.pageTitle)                              // inside #if os(tvOS)
.duskFont(tvOnly: DuskFont.TV.rowValue)                   // iOS keeps inheriting
```

Raw point sizes for layout structs: `DuskFont.TV.Size.heroTitle`. A genuine one-off
(the `plex.tv/link` code, a glyph sized from a layout metric) may stay an explicit
`.system(size:)` inside `#if os(tvOS)`.

iOS conventions that predate the tokens and still hold:

* **Metadata:** Monospaced for technical data like `4K • HEVC`.
* **Body:** line spacing +4pt.

### 3.2 Shapes

* **Poster Corner Radius:** `16pt`
* **Button Corner Radius:** Full Pill (`100pt` / `.capsule`)
* **Card/Sheet Corner Radius:** `28pt`
* **Borders:** `1pt` solid.
* *Dark:* `White.opacity(0.05)`
* *Light:* `Black.opacity(0.05)`

### 3.3 Detail Hero Actions & Layout

The movie / show / season / episode detail heroes are **backdrop-led with no
poster** on every platform. Action buttons use the **native Liquid Glass** styles;
never fill one with the Sunset Coral accent — coral is reserved for progress,
ratings, active states, and inline links.

**Hero layout.**

* **iPhone:** a single **centered** column over the backdrop — title artwork,
  metadata, then the actions, all center-aligned.
* **iPad:** **two columns** — left: title artwork, the primary button, and the
  secondary icon row beneath it; right: the season/episode marker, metadata, and
  the synopsis. The synopsis renders here instead of as a section below the hero.
* **tvOS:** a **left-aligned** column (title artwork, metadata) with a single
  action row beneath it — primary plus the secondary icons to its right.

**Primary action (Play / Resume).**

* **Style:** prominent Liquid Glass — `.buttonStyle(.glassProminent)` (fallback
  `.borderedProminent` below iOS 26), on **all** platforms (tvOS included).
* **Color:** `.tint(Color.duskPrimaryButtonTint)` — a *translucent* `primary` so the
  button keeps a **dark** (Light mode) / **light** (Dark mode) lean for contrast
  while still reading as liquid glass, not a solid black/white fill. Label/icon use
  `Color.duskPrimaryActionLabel` (the inverse of `primary`). Tune the tint's opacity
  (in `DuskApp.swift`) to trade contrast for glassiness.
* **Height:** `.controlSize(.regular)`, `.capsule` — deliberately short (tvOS used
  to be `.large`; it is now `.regular` too).
* **Width:** iPhone → ~60% of the screen, **centered**; iPad → fills the hero's
  left column (`detailHeroRegularActionMaxWidth` cap, ≈460pt); tvOS → a contained
  `minWidth` (~260pt) so it does not hug the short label, leaving space to its right.
* **Label:** keep it simple. Show and Season say just **"Play"** / **"Resume"** on
  every platform — never the specific episode (that is too much information).

**Secondary actions (Download / Mark Watched / Go to Show|Season).**

* **Icon-only everywhere** — use `DetailHeroSecondaryIconLabel` (SF Symbol only)
  plus an `.accessibilityLabel`; no text crowds the row.
* **Style:** neutral Liquid Glass — `.buttonStyle(.glass)` (fallback `.bordered`),
  `.tint(Color.primary)`, `.controlSize(.regular)`. **Shape:** `.capsule` pills on
  iOS, **`.circle`** on tvOS (there is no shared width to match there).
* **Placement:** a compact row **below** the primary on iOS (centered on iPhone,
  leading on iPad); **to the right** of the primary on tvOS. Movie, Show, Season,
  and Episode all expose a watched toggle; Show/Season mark the whole show/season.

**Home cinematic hero button.**

* Same prominent, contrasting Liquid Glass as the detail primary, sized as a
  **wide, short pill** (≈240pt iPhone / ≈300pt iPad).

**Helpers:** `detailHeroNativePrimaryButtonStyle()`,
`detailHeroNativeSecondaryButtonStyle()`, `DetailHeroSecondaryIconLabel`,
`detailHeroActionStackFrame(isCompactPhone:)`, `detailHeroContentAlignment(for:)` /
`detailHeroTextAlignment(for:)`, and `detailShowsSynopsisBelowHero(for:)` (detail
screens); `homeHeroNativeButtonStyle()` + `HomeHeroActionButtonLabel(fillsWidth:)`
(home hero).

---

## 4. Interaction States

* **Hover/Focus (tvOS):** Scale the element to `1.05x` and add a subtle, tight neutral white outer glow.
* **Loading:** Use a custom `ProgressView` tinted with `AppAccent`.
* **Empty States:** Use SF Symbols with a "Dusk Gray" (`#8E95A8`) tint and centered `TextSecondary`.

---

### Implementation Tip for Swift

Current SwiftUI implementation keeps the theme tokens in `Dusk/Sources/App/DuskApp.swift`. The app uses dynamic `Color` values backed by `UIColor { traitCollection in ... }` for light/dark switching, while `AccentColor` remains the existing asset-backed global accent.

#### Asset names currently in use

* `AccentColor` for the `AppAccent` design token. This stays named `AccentColor` so Xcode can use it as the global app tint on iOS.
* `AccentColorTV` is the tvOS target's global accent (`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`). It is the tab bar's label-color tint (`TextPrimary` in Dark mode, black in Light mode), not a brand token: the global accent is the UIKit window tint, and the tvOS tab bar must never inherit coral from it. SwiftUI content on tvOS still gets `AppAccent` from the root `.tint(Color.duskAccent)`.

#### Swift color API currently in use

* `Color.duskBackground`
* `Color.duskSurface`
* `Color.duskTextPrimary`
* `Color.duskTextSecondary`
* `Color.duskAccent`

#### Current application rules

* Apply `Color.duskAccent` as the app-wide `.tint(...)`.
* Keep iOS/iPadOS tab bar selection monochrome by tinting the `TabView` with the native `.primary` color role. Do not hardcode selected tab colors; the floating iPad tab bar must adapt to both artwork and light content backgrounds.
* Use `Color.duskBackground` for root screen backgrounds.
* Use `Color.duskSurface` for list rows, cards, sheets, and elevated surfaces.
* Use `Color.duskTextPrimary` for titles and high-emphasis labels.
* Use `Color.duskTextSecondary` for metadata, captions, placeholders, and empty states.
* Tint `ProgressView` with `Color.duskAccent`.

#### Guardrails

* Do not introduce ad-hoc hardcoded brand colors like `.orange`, `.blue`, `.green`, or `.purple` for primary UI.
* New UI should consume these tokens first and only add new tokens when `STYLE.md` is updated intentionally.

> **Pro-tip:** For the "Dawn" (Light) mode, the **Sunset Coral** actually pops even more against the light blue-gray background. It keeps the app feeling like the same product even when the brightness is cranked up.
