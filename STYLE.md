# Dusk Design System (v1.0)

## 1. Design Philosophy: native vibes, not orange

Dusk is a **content-first** player. The UI recedes so posters and backdrops lead,
and it should feel like an Apple app, not a themed one.

**The rules (read these even if you read nothing else):**

1. **System first.** Use system controls and styles as they ship: Liquid Glass
   (`.glass` / `.glassProminent`), standard tvOS focus, `Toggle`, `Picker`,
   `ProgressView`, `List`, toolbar and navigation buttons. Don't restyle them.
2. **Neutral palette.** Colour comes from the Dusk tokens below and semantic
   colours (`.primary`, `.secondary`, `Color.duskTextPrimary/Secondary`). Use
   system colours only where they already carry meaning: red for destructive or
   errors, yellow for the star rating, green for the system switch.
3. **No accent colour for UI state.** Selection, focus, progress, active
   filters, checkmarks, links, loading and badges are shown with weight, opacity,
   fill (`TextPrimary` on `Background`), or the system's own treatment, never a
   brand colour.
4. **No app-wide tint.** The global `AccentColor` asset is the label colour, and
   nothing sets a root `.tint`. Never add `.tint(Color.duskAccent)` or any other
   colour tint to make something "pop".
5. **Coral is the brand, not the UI.** Sunset Coral (`Color.duskAccent`,
   `#FF6B4A`) appears only in the app logo/icon, the Supporter page and the
   App Icon picker. Anywhere else it is a bug.

* **Modern Minimal:** thin strokes (1pt), large corner radii, generous whitespace.
* **Glass:** system materials (`ultraThinMaterial`) and native Liquid Glass for
  overlays, navigation and actions.

---

## 2. Color Palettes

### 2.1 Dark Mode (Dusk)

The default experience. Deep, cool-toned blacks so OLED screens shine.

| Token | Hex | Usage |
| --- | --- | --- |
| **AppBackground** | `#090A0F` | Main window background. Deep twilight. |
| **AppSurface** | `#161824` | Cards, modals, and secondary backgrounds. |
| **TextPrimary** | `#F2F2F7` | Titles, primary labels, selected/active state. |
| **TextSecondary** | `#8E95A8` | Metadata, captions, icons, disabled states. |

### 2.2 Light Mode (Dawn)

A crisp, high-clarity alternative. Avoids "pure" white to reduce eye strain.

| Token | Hex | Usage |
| --- | --- | --- |
| **AppBackground** | `#F5F7FA` | Main window background. Soft morning fog. |
| **AppSurface** | `#FFFFFF` | Cards and elevated surfaces. |
| **TextPrimary** | `#1C1C1E` | Titles, primary labels, selected/active state. |
| **TextSecondary** | `#636366` | Metadata, secondary descriptions, icons. |

### 2.3 Brand (not a UI colour)

| Token | Hex | Usage |
| --- | --- | --- |
| **Brand / Sunset Coral** | `#FF6B4A` | App logo/icon, Supporter page, App Icon picker. Nothing else. |

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
| `cardSubtitle` | 23 | Regular | Card subtitles (incl. their watched checkmark), cast names |
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
poster** on every platform. Action buttons use the **native Liquid Glass** styles.

**Hero layout.**

* **iPhone:** a single **centered** column over the backdrop — title artwork,
  metadata, then the actions, all center-aligned.
* **iPad:** **two columns** — left: title artwork, the primary button, and the
  secondary icon row beneath it; right: the season/episode marker, metadata, and
  the synopsis. The synopsis renders here instead of as a section below the hero.
* **tvOS:** a **left-aligned** column (title artwork, metadata) with a single
  action row beneath it — primary plus the secondary icons to its right.

**Primary action (Play / Resume).**

* **Style:** prominent Liquid Glass on iOS — `.buttonStyle(.glassProminent)`
  (fallback `.borderedProminent` below iOS 26). **tvOS** uses the plain system
  `.glass` with **no tint**, like the TV app: a dark platter that lifts to white
  with a dark label on focus. Never give a tvOS system button an explicit tint:
  any colour (even `.primary`) recolours the label, so the focused state goes
  white-on-white. The tvOS tab shell clears its bar tint off the tab content
  (`MainTabTVShell`), so buttons need no `.tint(nil)` of their own.
* **Color (iOS):** `.tint(Color.duskPrimaryButtonTint)` — a *translucent* `primary` so the
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
  `.tint(Color.primary)` on iOS / no tint on tvOS, `.controlSize(.regular)`. **Shape:** `.capsule` pills on
  iOS, **`.circle`** on tvOS (there is no shared width to match there).
* **Placement:** a compact row **below** the primary on iOS (centered on iPhone,
  leading on iPad); **to the right** of the primary on tvOS. Movie, Show, Season,
  and Episode all expose a watched toggle; Show/Season mark the whole show/season.

**Watched state is quiet everywhere.** A small checkmark in the card's subtitle
colour (no filled badge), the neutral white-on-dark progress bar of
`PosterArtwork` for partially watched items, nothing for unwatched. "Show More"
is a `.glass` button on tvOS and plain `primary` text on iOS.

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

* **Focus (tvOS):** the system focus effect for system controls. Library poster
  cells use the system card focus (lift, scale, parallax, shadow). Other custom
  cards scale slightly with a subtle neutral glow; custom rows lift with a
  `TextPrimary`-at-low-opacity band. No coloured outlines.
* **Selected / active:** bold or full-opacity `TextPrimary` against dimmer
  siblings, or an inverted `TextPrimary` fill with a `Background` label (Live TV
  date pill). Never a brand colour.
* **Progress:** white on a dark track over artwork (`PosterArtwork`); elsewhere
  `TextPrimary` on a `TextSecondary` track (`CircularProgressView`).
* **Loading:** plain `ProgressView()`, no tint.
* **Toggles:** plain `Toggle`, no tint (system green).
* **Empty / error states:** SF Symbol and text in `TextSecondary`; the single
  action is `FeaturePrimaryButton` (the same neutral glass as Play).

---

## 5. Implementation

Theme tokens live in `Dusk/Sources/App/DuskApp.swift` as dynamic `Color`s backed
by `UIColor { traitCollection in ... }`.

* `Color.duskBackground`: root screen backgrounds.
* `Color.duskSurface`: list rows, cards, sheets, elevated surfaces.
* `Color.duskTextPrimary`: titles, high-emphasis labels, selected state.
* `Color.duskTextSecondary`: metadata, captions, icons, placeholders.
* `Color.duskPrimaryButtonTint` / `Color.duskPrimaryActionLabel`: the iOS
  prominent-glass primary action and its label.
* `Color.duskAccent`: **brand only** (Supporter page, App Icon picker).

**Tint.** `AccentColor` is the global accent for both targets
(`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`) and is the label colour:
black in Light mode, `TextPrimary` in Dark mode. It is the UIKit window tint, so
alerts, navigation buttons, pickers and the text cursor are neutral without any
code. There is no root SwiftUI `.tint`. The tvOS tab bar is additionally pinned to
the same colour (`Color.duskTVTabBarTint`) because SwiftUI's `TabView` tint is not
sticky there.

**Guardrails.**

* No `Color.duskAccent`, `.orange`, `.blue`, `.purple` or other hues for UI
  outside the brand spots above. A new colour needs a deliberate `STYLE.md`
  change first.
* No colour tint on system controls. If a control looks wrong, fix it with the
  system style (`.glass`, `.glassProminent`, `.bordered`), not a tint.
* Verify UI changes with a screenshot in both appearances; "monochrome now" in
  code is not proof.
