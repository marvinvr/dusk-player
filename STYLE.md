# Dusk Design System (v1.0)

## 1. Design Philosophy

Dusk is a **content-first** player. The UI should "recede" to let movie posters and cinematic backdrops lead the experience.

* **Modern Minimal:** Use thin strokes (1pt), large corner radii, and generous whitespace.
* **Glassmorphism:** Use system materials (`ultraThinMaterial`) for overlays and navigation bars.
* **Vibrant Accents:** Use a single brand color (**Sunset Coral**) for all primary actions.

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
* **Button Corner Radius:** Full Pill (`100pt`)
* **Card/Sheet Corner Radius:** `28pt`
* **Borders:** `1pt` solid.
* *Dark:* `White.opacity(0.05)`
* *Light:* `Black.opacity(0.05)`



---

## 4. Interaction States

* **Hover/Focus (tvOS):** Scale the element to `1.05x` and add a subtle outer glow using the `AppAccent` color at 30% opacity.
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
* Use `Color.duskBackground` for root screen backgrounds.
* Use `Color.duskSurface` for list rows, cards, sheets, and elevated surfaces.
* Use `Color.duskTextPrimary` for titles and high-emphasis labels.
* Use `Color.duskTextSecondary` for metadata, captions, placeholders, and empty states.
* Tint `ProgressView` with `Color.duskAccent`.

#### Guardrails

* Do not introduce ad-hoc hardcoded brand colors like `.orange`, `.blue`, `.green`, or `.purple` for primary UI.
* New UI should consume these tokens first and only add new tokens when `STYLE.md` is updated intentionally.

> **Pro-tip:** For the "Dawn" (Light) mode, the **Sunset Coral** actually pops even more against the light blue-gray background. It keeps the app feeling like the same product even when the brightness is cranked up.
