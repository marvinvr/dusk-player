# Supporter Tier (In-App Purchases)

Dusk stays fully free; the supporter tier is an optional tip jar with cosmetic
perks. This doc covers the StoreKit flow, the two subscription levels, the
prompt gating, the alternate app icons, and the App Store Connect setup.

## Product Catalog

Defined in `SupporterProduct` (`Features/Supporter/SupporterStore.swift`) and
mirrored in the local test config `Dusk/Support/Dusk.storekit`. App Store
Connect must define the same IDs (full metadata in
[App Store Connect](#app-store-connect)):

- **Front Row** (lower level): `supporter.monthly` $1.99/month,
  `supporter.yearly` $14.99/year — auto-renewable, group "Dusk Supporter".
  These IDs predate the levels; only display/reference names changed.
- **Director's Cut** (higher level): `directorscut.monthly` $4.99/month,
  `directorscut.yearly` $39.99/year — same group.
- `tip.{coffee,generous,legendary,patron}` — consumables at
  $2.99 / $9.99 / $19.99 / $49.99

Both levels live in **one** subscription group so StoreKit owns level changes:
an upgrade (Front Row → Director's Cut) starts immediately with a prorated
credit, a downgrade starts at the next renewal, and monthly ↔ yearly within a
level is a crossgrade. In the group, App Store levels count down: Director's
Cut = level 1, Front Row = level 2 (`groupNumber` in `Dusk.storekit`). In code,
`SupporterTier` orders the other way (`directorsCut > frontRow`).

Prices are the agreed USD reference prices; App Store Connect is the source of
truth for storefront pricing, and `Dusk.storekit` must mirror it so local
testing matches production.

Tips are deliberately **consumables** so they can be purchased repeatedly
("support again"). Tip display names/descriptions shown in the sheet come from
StoreKit product metadata (fallbacks for empty names only). Subscription rows
sit inside a tier card titled with the level, so on iOS they are labeled
"Monthly"/"Yearly" and the perks per level are app copy; tvOS rows use the
StoreKit display name.

## Supporter Status Rules

`SupporterStore` (`@MainActor @Observable`, injected in `DuskApp` alongside the
other services) owns all state:

- **Any verified purchase ever ⇒ supporter forever.** Status is monotonic:
  `refreshEntitlements()` only ever upgrades, and the UserDefaults cache is
  never downgraded by an empty/transient history read. This holds for both
  levels: a lapsed Director's Cut or Front Row subscriber stays a supporter and
  keeps the six classic icons.
- The **active level** (`activeTier`, `activeProductID`) is *not* monotonic:
  it comes from `Transaction.currentEntitlements` on every read. The pure
  resolution is `SupporterEntitlements.resolve` (`SupporterEntitlements.swift`):
  ignores revoked, expired and `isUpgraded` transactions and picks the highest
  level. A pending downgrade is not a transaction yet, so Director's Cut stays
  in force until it renews into Front Row. `renewalPlan` (from the
  transaction's `subscriptionStatus` renewal info) exposes the pending
  downgrade / cancellation for the sheet's status line.
- Lifetime evidence (`isSupporter`, `supporterSince`, `tipCount`) comes from
  `Transaction.all`.
- **Family Sharing** is on for Director's Cut only. Family members see the
  shared transaction (`ownershipType == .familyShared`) in both reads, so they
  get Director's Cut (incl. the exclusive icons) while it is shared and — like
  any verified transaction — become supporters for good. Leaving the family
  revokes the transaction (`revocationDate`), which drops the level.
- Entitlements are re-read on every transaction update, after purchases and
  restores, when the app becomes active (`sceneDidBecomeActive()` from
  `DuskApp`), and one second after the active period's expiration date if the
  app is still open — expirations produce no transaction update.
- Finished consumables appear in `Transaction.all` only because
  `SKIncludeConsumableInAppPurchaseHistory` is set to true in **both**
  Info.plists (iOS 18+ behavior). Do not remove that key — reinstall/multi-
  device supporter recognition for tips depends on it.
- The transaction-updates listener finishes every verified transaction;
  unfinished ones are swept at startup. Consumables that are never finished
  block future purchases of the same product.

Trap: `AppStore.sync()` (Restore Purchases) can prompt for App Store
credentials — only call it from an explicit user action.

## UI Surfaces

- `SupporterView` (`Features/Supporter/SupporterView.swift`) is the one sheet
  for pitch, thank-you, and the prompts (`SupporterViewContext.prompt(number:)`
  adds a "Maybe Later" glass button and adapts the headline per prompt). iOS renders custom purchase rows; tvOS reuses
  `TVSettingsSection`/`TVSettingsActionRow` so focus behavior matches Settings.
  Subscriptions render as two tier cards (iOS `SupporterTierCard`) / two
  settings sections (tvOS): Front Row and Director's Cut, each with what it
  gets and its monthly/yearly rows. Both stay visible while subscribed: the
  current plan is marked and disabled, the other level's rows become the
  upgrade/downgrade path (with a note on when it applies), and a scheduled
  downgrade shows "Starts <date>" on its row. A status line under the header
  shows level + renews/ends/switches date. Manage Subscription appears while
  a subscription is active (iOS only, via `manageSubscriptionsSheet`; tvOS
  footer points to the system Settings path).
- App Review 3.1.2 requirements, keep them when restyling: every plan row
  shows title (level + Monthly/Yearly), price and period; right under the
  plans comes the auto-renewal disclosure and the **Privacy Policy** and
  **Terms of Use (EULA)** links (iOS buttons; tvOS can't open URLs, so its
  Manage footer spells both addresses out).
- Settings entry points: a supporter row at the very top of
  `SettingsIOSView`/`SettingsTVView` (flips to a thank-you state for
  supporters) and an "App Icon" row in the iOS Appearance section that opens
  `AppIconPickerView`. tvOS keeps purchases available from this explicit
  Settings entry point but never presents automatic supporter prompts.
- `SupporterIconShowcase` (in `SupporterView.swift`) previews all icons inside
  the sheet — the classic set, a hairline, then the Director's Cut exclusives
  (locked unless Director's Cut is active); on iOS unlocked tiles apply
  directly. tvOS can't scroll the non-focusable strip, so it shows the
  exclusives as a second labeled row. `AppIconPickerView` groups the same way ("Supporter Icons" /
  "Director's Cut Exclusives"); locked tiles open the supporter sheet.

## Prompt Ladder

`SupporterPromptGate` + `SupporterPromptPresenter`
(`Features/Supporter/SupporterPrompt.swift`), applied in `MainTabView` on iOS
and iPadOS so it only runs for signed-in sessions. Apple TV does not apply the
presenter. The initial phase has three prompts:

| Prompt | Min days since first launch | Min usage days | Min days since previous |
| ------ | --------------------------- | -------------- | ----------------------- |
| 1      | 7                           | 3              | —                       |
| 2      | 30                          | 10             | 14                      |
| 3      | 90                          | 25             | 30                      |

- Usage days are distinct calendar days (`UserPreferences.registerUsageDay()`).
  The escalating thresholds mean light users stop qualifying instead of being
  re-asked; the gap column keeps a returning heavy user from seeing several
  prompts in quick succession.
- After the initial phase, an annual prompt becomes eligible beginning 365 days
  after first launch. The first annual prompt also requires 180 days since the
  third initial prompt; subsequent annual prompts require 365 days since the
  previous prompt. Every annual prompt requires at least 12 distinct usage days
  since the previous prompt.
- Never for supporters (StoreKit history syncs per Apple ID, so a supporter's
  other devices never prompt); never while the player is up; 2s grace delay
  after activation.
- `UserPreferences.firstLaunchDate` is set on first run — for pre-existing
  installs that is the first run after the update, intentionally.
- `UserPreferences.registerSupporterPrompt()` advances `supporterPromptCount`
  and stamps `supporterLastPromptDate` plus the current usage-day count the
  moment a prompt presents; declining ("Maybe Later") does not reset anything.
- Prompt 2 onward uses the neutral "Still enjoying Dusk?" headline. The sheet
  does not describe the cadence or promise that a prompt is the final ask.

## Reporting

Every surface in this feature reports anonymous events — see `analytics.md` for
the rules and the full list. Two pairs are worth knowing about here because they
exist to catch bugs this feature is prone to:

- `supporter_prompt_triggered` vs `supporter_sheet_shown` (`source=prompt`)
  catches a ladder that advances `supporterPromptCount` without the sheet ever
  reaching the screen — the milestone is burned either way, so a silent
  presentation failure would otherwise be invisible.
- `supporter_products_unavailable` vs `supporter_sheet_shown` catches App Store
  products failing to resolve in production. Local runs cannot catch that: both
  schemes attach `Dusk/Support/Dusk.storekit`, so Xcode always serves products
  from the local file rather than App Store Connect.

## Alternate App Icons (iOS/iPadOS only)

- Icon Composer bundles `Dusk/Resources/DuskIcon{Dawn,Midnight,Neon,Mono,Aurora,GoldenHour,Eclipse,Velvet}.icon`,
  registered via `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` in
  `project.yml` (iOS target) and excluded from the tvOS target (tvOS alternates
  would need layered image stacks — out of scope; the Apple TV app only
  showcases them and its copy says they apply on iPhone and iPad).
- Each bundle is two layers: an opaque `background.png` and `mark.png` (the
  primary mark's alpha, recolored), with the shared `icon.json`. Previews are
  flattened 512px `IconPreview*` imagesets in `Assets.xcassets`, shared with tvOS.
- Access (`DuskAppIcon.isUnlocked`): the primary "Dusk" icon is free; the six
  classic alternates belong to every supporter forever; **Eclipse** (black sun
  with a glowing corona) and **Velvet** (cinema red with a touch of gold) only
  while Director's Cut is active (`requiresDirectorsCut`).
- **Lapse:** when Director's Cut is no longer active and one of its icons is
  set, `SupporterStore` switches back to the primary icon after an entitlement
  read — no in-app UI (iOS itself shows its standard one-line "icon changed"
  alert; no public API suppresses it). Guard against transient empty reads:
  the store caches the last known Director's Cut expiration
  (`supporterDirectorsCutExpiration`) and only reverts once that date has
  passed (`SupporterEntitlements.shouldRevertExclusiveIcon`); a non-empty
  history read overrides the cache so refunds revert immediately.
  `setAlternateIconName` fails while the app is inactive; the next activation
  retries.
- Eclipse/Velvet were generated with `scripts/generate_directors_cut_icons.py`
  (Pillow + NumPy; `python3 scripts/generate_directors_cut_icons.py Dusk/Resources <out>`),
  which reuses the primary mark's alpha so they match the other alternates.
- Adding a variant: new `.icon` bundle + preview imageset + `DuskAppIcon` case
  + the two `project.yml` spots + `xcodegen generate`.

## Verification

- Build both targets (compile-only, per `AGENTS.md`).
- `DuskTests` / `DuskTests-tvOS` (unit-test bundles hosted by the apps, wired
  into the `Dusk` / `Dusk-tvOS` schemes' Test action):
  - `SupporterEntitlementsTests` — pure rules: level resolution (active,
    upgrade with `isUpgraded`, pending downgrade, renewal into Front Row,
    lapse, refund, tips), the exclusive-icon revert rule, icon access, and the
    store's monotonic cache.
  - `SupporterStoreKitTests` — StoreKitTest (`SKTestSession` with
    `Dusk.storekit`, copied into the test bundle): catalog/levels/Family
    Sharing, buy → upgrade → scheduled downgrade → forced renewal into Front
    Row, Director's Cut lapse (auto-renew off + expire; expiring alone leaves
    an auto-renewing test subscription in force), restore on a fresh install,
    refund. Serialized: the StoreKit test
    environment is shared state. Trap: the first run right after the app
    is (re)installed on a simulator can still hit the real sandbox (App Store
    Connect products, Apple Account sign-in on purchase) — run it again.
- Runtime purchase flows in the app use the `Dusk.storekit` config attached to
  both schemes' Run action (`project.yml` `schemes:`); Xcode's transaction
  manager can grant/refund/expire test purchases, including testing that a
  refunded-free install still resolves supporter status from history.
- App Store Connect prerequisites before release: the products and group
  levels below, and privacy policy (`SettingsSupport.privacyPolicyURL`) and
  terms links resolving — both are App Review requirements for subscriptions.

## App Store Connect

Everything here mirrors `Dusk.storekit`. Prices are USD tier references; let
App Store Connect derive the other storefronts as for the existing products.

### Subscription group "Dusk Supporter" (existing)

Reorder the levels so Director's Cut sits above Front Row:

| Level | Products |
| ----- | -------- |
| 1 (highest) | `directorscut.monthly`, `directorscut.yearly` |
| 2 | `supporter.monthly`, `supporter.yearly` |

Products on the same level crossgrade (monthly ↔ yearly); moving to level 1 is
an upgrade (immediate, prorated refund of the remaining period), to level 2 a
downgrade (at the next renewal).

### Existing products — rename only (IDs, prices, everything else unchanged)

| Product ID | Reference name | Display name EN | Display name DE |
| ---------- | -------------- | --------------- | --------------- |
| `supporter.monthly` | Front Row Monthly | Front Row Monthly | Front Row monatlich |
| `supporter.yearly` | Front Row Yearly | Front Row Yearly | Front Row jährlich |

Descriptions: EN stays "Ongoing support, cancel anytime." (or the current
App Store Connect text); DE "Laufende Unterstützung, jederzeit kündbar."

### New products

| | `directorscut.monthly` | `directorscut.yearly` |
| --- | --- | --- |
| Type | Auto-renewable subscription | Auto-renewable subscription |
| Group / level | Dusk Supporter / level 1 | Dusk Supporter / level 1 |
| Duration | 1 month | 1 year |
| Price (USD) | $4.99 | $39.99 |
| Reference name | Director's Cut Monthly | Director's Cut Yearly |
| Display name EN | Director's Cut Monthly | Director's Cut Yearly |
| Description EN | Top-tier support + 2 exclusive app icons. | Top-tier support + 2 exclusive app icons. |
| Display name DE | Director's Cut monatlich | Director's Cut jährlich |
| Description DE | Größte Unterstützung + 2 exklusive Icons. | Größte Unterstützung + 2 exklusive Icons. |
| Family Sharing | **On** | **On** |
| Introductory / promotional offers | None | None |

Display names ≤ 30 and descriptions ≤ 45 characters (App Store Connect
limits). Availability: all storefronts where the app is sold, same as Front Row.
Both Director's Cut products are final in App Store Connect. Family Sharing is
on for Director's Cut and stays **off** for Front Row (`supporter.*`);
`Dusk.storekit` mirrors that (`familyShareable`). Note that Family Sharing can't
be switched off again once enabled for a product.

### Review notes (for both new products)

> Dusk is a free Plex client; all features stay free. Subscriptions are an
> optional way to support development. "Director's Cut" is the higher level of
> the existing "Dusk Supporter" group (above "Front Row"). It unlocks two
> additional, exclusive alternate app icons (Eclipse and Velvet) on iPhone and
> iPad while active; every purchase also permanently unlocks the six standard
> alternate icons. To review: Settings → "Support Dusk" (top row) opens the
> supporter sheet; Settings → Appearance → App Icon shows the icons. No Plex
> account is needed to view the purchase sheet after signing in with the demo
> account provided in the app review information. On Apple TV the same sheet
> is under Settings → Support; alternate icons are not available on tvOS.

Screenshot for review: the supporter sheet on iPhone (flatten to JPEG —
App Store Connect rejects Simulator PNGs with an alpha channel).
