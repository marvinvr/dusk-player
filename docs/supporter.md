# Supporter Tier (In-App Purchases)

Dusk stays fully free; the supporter tier is an optional tip jar with cosmetic
perks. This doc covers the StoreKit flow, the prompt gating, and the alternate
app icons.

## Product Catalog

Defined in `SupporterProduct` (`Features/Supporter/SupporterStore.swift`) and
mirrored in the local test config `Dusk/Support/Dusk.storekit`. App Store
Connect must define the same IDs:

- `supporter.monthly` — auto-renewable, group "Dusk Supporter", $1.99/month
- `supporter.yearly` — auto-renewable, same group, $14.99/year
- `tip.{coffee,generous,legendary,patron}` — consumables at
  $2.99 / $9.99 / $19.99 / $49.99

Prices are the agreed USD reference prices; App Store Connect is the source of
truth for storefront pricing, and `Dusk.storekit` must mirror it so local
testing matches production.

Tips are deliberately **consumables** so they can be purchased repeatedly
("support again"). Display names/descriptions shown in the sheet come from
StoreKit product metadata, not hardcoded strings (there are fallbacks for
empty names only).

## Supporter Status Rules

`SupporterStore` (`@MainActor @Observable`, injected in `DuskApp` alongside the
other services) owns all state:

- **Any verified purchase ever ⇒ supporter forever.** Status is monotonic:
  `refreshEntitlements()` only ever upgrades, and the UserDefaults cache is
  never downgraded by an empty/transient history read.
- Active-subscription state (`hasActiveSubscription`) comes from
  `Transaction.currentEntitlements`; lifetime evidence (`isSupporter`,
  `supporterSince`, `tipCount`) from `Transaction.all`.
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
  for pitch, thank-you, and the prompt (`SupporterViewContext.prompt` adds a
  "Maybe Later" glass button). iOS renders custom purchase rows; tvOS reuses
  `TVSettingsSection`/`TVSettingsActionRow` so focus behavior matches Settings.
  Recurring vs one-time options are labeled sections; the recurring section
  hides while a subscription is active (Manage Subscription appears instead,
  iOS only via `manageSubscriptionsSheet`).
- Settings entry points: a supporter row at the very top of
  `SettingsIOSView`/`SettingsTVView` (flips to a thank-you state for
  supporters) and an "App Icon" row in the iOS Appearance section that opens
  `AppIconPickerView`.
- `SupporterIconShowcase` (in `SupporterView.swift`) previews all icons inside
  the sheet; for supporters on iOS it applies icons directly.

## One-Time Prompt

`SupporterPromptGate` + `SupporterPromptPresenter`
(`Features/Supporter/SupporterPrompt.swift`), applied in `MainTabView` so it
only runs for signed-in sessions. Fires when ALL hold:

- ≥ 7 days since `UserPreferences.firstLaunchDate` (set on first run — for
  pre-existing installs that is the first run after the update, intentionally),
- ≥ 3 distinct usage days (`UserPreferences.registerUsageDay()`),
- not already a supporter (StoreKit history syncs per Apple ID, so other
  devices of a supporter never prompt),
- player not presented; 2s grace delay after activation.

It sets `supporterPromptShown` the moment it presents and never shows again on
that device. Do not add more prompts or re-ask logic without an explicit
product decision — the non-pushy posture is deliberate.

## Alternate App Icons (iOS/iPadOS only)

- Icon Composer bundles `Dusk/Resources/DuskIcon{Dawn,Midnight,Neon,Mono,Aurora,GoldenHour}.icon`,
  registered via `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` in
  `project.yml` (iOS target) and excluded from the tvOS target (tvOS alternates
  would need layered image stacks — out of scope).
- `DuskAppIcon` maps variants to alternate-icon names and bundled preview
  imagesets (`IconPreview*` in `Assets.xcassets`, shared with tvOS for the
  showcase). Switching uses `UIApplication.setAlternateIconName`; only the
  primary "Dusk" icon is free.
- Adding a variant: new `.icon` bundle + preview imageset + `DuskAppIcon` case
  + the two `project.yml` spots + `xcodegen generate`.

## Verification

- Build both targets (compile-only, per `AGENTS.md`).
- Runtime purchase flows use the `Dusk.storekit` config attached to both
  schemes' Run action (`project.yml` `schemes:`); Xcode's transaction manager
  can grant/refund test purchases, including testing that a refunded-free
  install still resolves supporter status from history.
- App Store Connect prerequisites before release: create the six products, the
  subscription group, and ensure privacy policy (`SettingsSupport.privacyPolicyURL`)
  and terms links resolve — both are App Review requirements for subscriptions.
