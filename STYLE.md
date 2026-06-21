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

* **Header:** Title 2, Bold.
* **Metadata:** Subheadline, Monospaced (for technical data like `4K • HEVC`).
* **Body:** Body, Regular, line spacing +4pt.

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
* **Color:** `.tint(Color.primary)` for built-in contrast — a **dark** glass pill
  in Light mode, a **light** one in Dark mode; label/icon use
  `Color.duskPrimaryActionLabel` (the inverse of `primary`).
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

* `AccentColor` for the `AppAccent` design token. This stays named `AccentColor` so Xcode can use it as the global app tint.

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
