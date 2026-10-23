# Supporter Tier (In-App Purchases)

Dusk stays fully free; the supporter tier is an optional tip jar with cosmetic
perks. This doc covers the StoreKit flow, the one subscription, the prompt
gating, the alternate app icons, and the App Store Connect setup.

## Product Catalog

Defined in `SupporterProduct` (`Features/Supporter/SupporterStore.swift`) and
mirrored in the local test config `Dusk/Support/Dusk.storekit`. App Store
Connect must define the same IDs (full metadata in
[App Store Connect](#app-store-connect)):

- **Dusk Supporter** subscription: `supporter.monthly` $2.99/month,
  `supporter.yearly` $24.99/year — auto-renewable, both on level 1 of group
  "Dusk Supporter". These are the IDs that shipped in 1.6 (then $1.99 /
  $14.99), so existing subscribers keep working with no migration and get
  every subscription perk; App Store Connect keeps their old price (see
  [Grandfathering](#grandfathering-existing-subscribers)).
- `tip.{coffee,generous,legendary,patron}` — consumables at
  $2.99 / $9.99 / $19.99 / $49.99

Monthly and yearly share one level, so switching between them is a crossgrade
that StoreKit applies at the next renewal. On iOS the switch goes through
Manage Subscription; tvOS lists both plans as rows (the other plan's row
schedules the switch and then shows "Starts <date>").

History: 1.7 development briefly had two levels (Front Row = `supporter.*`,
Director's Cut = `directorscut.*`). That never shipped and is gone; the
`directorscut.*` products are not in the app or `Dusk.storekit`.

Prices are the agreed USD reference prices; App Store Connect is the source of
truth for storefront pricing, and `Dusk.storekit` must mirror it so local
testing matches production.

Tips are deliberately **consumables** so they can be purchased repeatedly
("support again"). Tip display names/descriptions shown in the sheet come from
StoreKit product metadata (fallbacks for empty names only). The iOS
subscription card is app copy ("Dusk Supporter", perks) with StoreKit prices on
its two buttons; tvOS rows use the StoreKit display name.

## Supporter Status Rules

`SupporterStore` (`@MainActor @Observable`, injected in `DuskApp` alongside the
other services) owns all state:

- **Supporter status vs. perks.** `isSupporter` (the "You're a Supporter"
  title) is monotonic: any verified purchase sets
  it, `refreshEntitlements()` only ever upgrades it, and the UserDefaults cache
  is never downgraded by an empty/transient history read. **Perks are not:**
  everything the subscription unlocks is only available while it is active —
  the six classic icons and the three subscriber exclusives alike. **Tips:** Generous, Legendary and Patron
  (`SupporterProduct.isIconTip`) are one-time purchases that unlock the six
  classic icons for good (`hasIconTip`, monotonic and cached like `tipCount`);
  the Coffee tip is a thank-you only and unlocks nothing. No tip ever unlocks
  the subscriber exclusives (Velvet, Emerald, Gilded). "Yours to keep" is fine for those tips (iOS
  tip rows show "Includes the six alternate icons, yours to keep"; tvOS says
  it in the tip section footer) — never write "forever", "for good" or "keep
  after cancelling" for subscription perks anywhere (sheet, picker, StoreKit /
  App Store Connect texts, review notes).
- The **active subscription** (`hasActiveSubscription`, `activeProductID`)
  is *not* monotonic: it comes from `Transaction.currentEntitlements` on every
  read. The pure resolution is `SupporterEntitlements.resolve`
  (`SupporterEntitlements.swift`): ignores revoked, expired and `isUpgraded`
  transactions. `renewalPlan` (from the transaction's `subscriptionStatus`
  renewal info) exposes a scheduled plan switch / cancellation for the status
  line.
- Lifetime evidence (`isSupporter`, `supporterSince`, `tipCount`,
  `hasIconTip`) comes from
  `Transaction.all`.
- **Family Sharing** is off for the subscription (as in 1.6). Turning it on
  later is possible but can't be undone.
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
  Under a "Recurring" heading the subscription is one card (iOS
  `SupporterSubscriptionCard`, modelled on MealMate's): "Dusk Supporter", its
  perks (all nine icons, the three subscriber exclusives shown as thumbnails),
  then two price buttons ("$2.99 / month", "$24.99 / year", the StoreKit
  price, never hardcoded) with "Billed monthly" / "Saves N%" under each.
  While subscribed the card shows an Active badge, the plan status
  (Monthly/Yearly · renews / ends / switches on <date>) and Manage
  Subscription instead of the buttons. tvOS shows a "Recurring" settings
  section with the two plans as rows (current plan marked and disabled);
  plan and tip rows carry a subtitle (`TVSettingsActionRow.subtitle`) with the
  perk, the yearly savings or the tip's description. The header shows the
  same status line.
- iOS layout: one spacing scale in `SupporterLayout` (32pt between sections,
  10pt label-to-card, 16pt text inset inside every card that section labels,
  footnotes and the icon strip share). The close button is a toolbar button
  in the sheet's own `NavigationStack`, so scrolled content passes under the
  bar. Manage Subscription is iOS only (via
  `manageSubscriptionsSheet`; tvOS footer points to the system Settings path).
- App Review 3.1.2 requirements, keep them when restyling: every purchase
  button/row shows price and period (and the card names the subscription); right under the
  plans comes the auto-renewal disclosure and the **Privacy Policy** and
  **Terms of Use (EULA)** links (iOS buttons; tvOS can't open URLs, so its
  Manage footer spells both addresses out).
- Settings entry points: a supporter row at the very top of
  `SettingsIOSView`/`SettingsTVView` (flips to a thank-you state for
  supporters) and an "App Icon" row in the iOS Appearance section that opens
  `AppIconPickerView`. tvOS keeps purchases available from this explicit
  Settings entry point but never presents automatic supporter prompts.
- `SupporterIconShowcase` (in `SupporterView.swift`) previews all icons inside
  the sheet — the classic set, a hairline, then the subscriber exclusives
  (locked unless the subscription is active); on iOS unlocked tiles apply
  directly. tvOS shows the exclusives as a second labeled row. Each row is a
  `.focusSection()` of `.card` buttons (icons still only apply on iPhone and
  iPad) so Up from the purchase rows always has a focusable target and the
  scroll view can bring the icons back on screen. The purchase block and the
  Manage section are focus sections too; the header is not. `AppIconPickerView`
  groups the same way ("Supporter Icons" / "Subscriber Exclusives"); locked
  tiles open the supporter sheet.

## Prompt Schedule

`SupporterPromptSchedule` + `SupporterPromptPresenter`
(`Features/Supporter/SupporterPrompt.swift`), applied in `MainTabView` on iOS
and iPadOS so it only runs for signed-in sessions. Apple TV does not apply the
presenter. All intervals are constants at the top of `SupporterPromptSchedule`:

| Rule | Value |
| ---- | ----- |
| First prompt | ≥ 7 days since first launch and ≥ 3 distinct usage days |
| Gap after prompt 1 / 2 / 3+ (dismissed, nothing bought) | 60 / 120 / 180 days, then every 180 days |
| Usage between prompts | ≥ 5 distinct usage days since the previous prompt |
| After any tip (Coffee included) | snoozed 365 days from that purchase |
| Active subscription | never |
| After a subscription ends | earliest 30 days after its expiry, then the normal gaps |

- The pure rule is `SupporterPromptSchedule.shouldShow(_ State:now:)`
  (`SupporterPromptScheduleTests`). Its subscription and tip inputs are the
  store's cached `lastKnownSubscriptionExpiration` and `lastTipDate`, so an
  active subscriber isn't prompted in the seconds before StoreKit answers at
  launch (an expiry in the future counts as active). StoreKit history syncs per
  Apple ID, so purchases on another device count once entitlements refresh.
- Supporter status (`isSupporter`) no longer silences prompts: a lapsed
  subscriber or a past tipper gets the schedule again once the snooze / grace
  period is over.
- Usage days are distinct calendar days (`UserPreferences.registerUsageDay()`).
  `UserPreferences.firstLaunchDate` is set on first run — for pre-existing
  installs that is the first run after the update, intentionally.
- `UserPreferences.registerSupporterPrompt()` advances `supporterPromptCount`
  and stamps `supporterLastPromptDate` plus the current usage-day count the
  moment a prompt presents; "Maybe Later" (or swiping away) is simply a
  dismissal. Counters from the old three-step ladder carry over unchanged.
- At most one prompt per session falls out of the gaps (weeks at least between
  prompts); calm moments only: never while the player is up, 2s grace delay
  after activation.
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

- Icon Composer bundles `Dusk/Resources/DuskIcon{Dawn,Midnight,Neon,Mono,Aurora,GoldenHour,Velvet,Emerald,Gilded}.icon`,
  registered via `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` in
  `project.yml` (iOS target) and excluded from the tvOS target (tvOS alternates
  would need layered image stacks — out of scope; the Apple TV app only
  showcases them and its copy says they apply on iPhone and iPad).
- Each bundle is two layers: an opaque `background.png` and `mark.png` (the
  primary mark's alpha, recolored), with the shared `icon.json`. Previews are
  flattened 512px `IconPreview*` imagesets in `Assets.xcassets`, shared with tvOS.
- Access (`DuskAppIcon.isUnlocked`): the primary "Dusk" icon is free; the six
  classic alternates need an active subscription or a tip from Generous up
  (`SupporterStore.hasIconAccess`); three jewel-tone icons with a gold accent
  only while the subscription is active (`requiresSubscription`):
  **Velvet** (cinema red, gold tip), **Emerald** (deep green, gold tip) and
  **Gilded** (polished gold on black lacquer).
- **Lapse:** when the subscription is no longer active and the current icon
  isn't otherwise covered (the exclusives never are; the classic alternates are
  by a tip from Generous up), `SupporterStore.enforceIconAccess()` switches
  back to the primary icon after an entitlement read — at launch, on every
  return to the foreground, on transaction updates and one second after the
  period ends while the app is open. No in-app UI (iOS itself shows its standard one-line
  "icon changed" alert; no public API suppresses it). Guard against transient
  empty reads: the store caches the last known subscription expiration
  (`supporterSubscriptionExpiration`) and only reverts once that date has
  passed (`SupporterEntitlements.shouldRevertIcon`); a non-empty history read
  overrides the cache so refunds revert immediately.
  `setAlternateIconName` fails while the app is inactive; the next activation
  retries.
- Velvet/Emerald/Gilded were generated with `scripts/generate_directors_cut_icons.py`
  (Pillow + NumPy; `python3 scripts/generate_directors_cut_icons.py Dusk/Resources <out>`),
  which reuses the primary mark's alpha so they match the other alternates.
- Adding a variant: new `.icon` bundle + preview imageset + `DuskAppIcon` case
  + the two `project.yml` spots + `xcodegen generate`.

## Verification

- Build both targets (compile-only, per `AGENTS.md`).
- `DuskTests` / `DuskTests-tvOS` (unit-test bundles hosted by the apps, wired
  into the `Dusk` / `Dusk-tvOS` schemes' Test action):
  - `SupporterEntitlementsTests` — pure rules: subscription resolution
    (active, a 1.6 subscriber, `isUpgraded`, plan switch at renewal, lapse,
    refund, tips), the icon revert rule (exclusives, classic icons, Coffee vs.
    Generous-and-up tips), icon access, and the store's cache.
  - `SupporterStoreKitTests` — StoreKitTest (`SKTestSession` with
    `Dusk.storekit`, copied into the test bundle): catalog/level/prices/Family
    Sharing, buy monthly → scheduled switch to yearly → forced renewal, lapse
    (auto-renew off + expire; expiring alone leaves an auto-renewing test
    subscription in force) then a Coffee tip (still locked) and a Generous tip
    (classics back, exclusives locked), restore on a fresh install, refund. Serialized: the StoreKit test
    environment is shared state. Trap: the first run right after the app
    is (re)installed on a simulator can still hit the real sandbox (App Store
    Connect products, Apple Account sign-in on purchase) — run it again.
- Runtime purchase flows in the app use the `Dusk.storekit` config attached to
  both schemes' Run action (`project.yml` `schemes:`); Xcode's transaction
  manager can grant/refund/expire test purchases, including testing that a
  refunded-free install still resolves supporter status from history.
- App Store Connect prerequisites before release: the products and group
  level below, and privacy policy (`SettingsSupport.privacyPolicyURL`) and
  terms links resolving — both are App Review requirements for subscriptions.

## App Store Connect

Everything here mirrors `Dusk.storekit`. Prices are USD tier references; let
App Store Connect derive the other storefronts as for the existing products.

### Subscription group "Dusk Supporter" (existing)

One level only:

| Level | Products |
| ----- | -------- |
| 1 | `supporter.monthly`, `supporter.yearly` |

### Subscription products (existing — edit)

| | `supporter.monthly` | `supporter.yearly` |
| --- | --- | --- |
| Level | 1 | 1 |
| Duration | 1 month | 1 year |
| Price (USD) | $2.99 (was $1.99) | $24.99 (was $14.99) |
| Reference name | Dusk Supporter Monthly | Dusk Supporter Yearly |
| Display name EN | Dusk Supporter Monthly | Dusk Supporter Yearly |
| Description EN | Supports Dusk + all 9 alternate app icons. | Supports Dusk + all 9 alternate app icons. |
| Display name DE | Dusk Supporter monatlich | Dusk Supporter jährlich |
| Description DE | Unterstützt Dusk + alle 9 alternativen Icons. | Unterstützt Dusk + alle 9 alternativen Icons. |
| Family Sharing | Off (unchanged) | Off (unchanged) |
| Introductory / promotional offers | None | None |

Display names ≤ 30 and descriptions ≤ 45 characters (App Store Connect
limits).

### Grandfathering existing subscribers

Apple only lets a price rise renew without the subscriber's consent if it is at
most once a year and no more than US$5 **and** 50% (monthly) / US$50 **and**
50% (yearly), and only where local law allows it. $1.99 → $2.99 is +50.3% and
$14.99 → $24.99 is +66.7%, so both would need every subscriber's consent,
and anyone who doesn't agree is cancelled at the next renewal. So: when
scheduling the new prices, choose **"Keep current price for existing
subscribers"** for both products. Existing subscribers keep $1.99 / $14.99
and every perk; only new subscriptions pay $2.99 / $24.99.

### Director's Cut products (never released — remove)

`directorscut.monthly` and `directorscut.yearly` are no longer used. Delete
them if App Store Connect allows it (never approved / never submitted with a
build); otherwise remove them from sale. Their IDs can't be reused either way.

### Review notes (both subscription products)

> Dusk is a free Plex client; all features stay free. The "Dusk Supporter"
> subscription (monthly or yearly) is an optional way to support development.
> While it is active it unlocks nine alternate app icons on iPhone and iPad,
> including three subscriber exclusives (Velvet, Emerald and Gilded); when it
> ends, the app switches back to the default icon. To review: Settings →
> "Support Dusk" (top row) opens the supporter sheet; Settings → Appearance →
> App Icon shows the icons. No Plex account is needed to view the purchase
> sheet after signing in with the demo account provided in the app review
> information. On Apple TV the same sheet is under Settings → Support;
> alternate icons are not available on tvOS.

Screenshot for review: the supporter sheet on iPhone (flatten to JPEG —
App Store Connect rejects Simulator PNGs with an alpha channel).

### Tips (existing consumables)

Descriptions stay as they are (Coffee "A little thank-you.", Generous "A
generous thank-you.", …); the icon perk is app copy on the tip rows. Review
notes for `tip.generous`, `tip.legendary` and `tip.patron` (add by hand):

> A one-time tip. Besides the thank-you, tips from Generous up unlock the six
> standard alternate app icons on iPhone and iPad (Settings → Appearance →
> App Icon). The Coffee tip unlocks nothing.

Review risk: Apple's product types put permanent unlocks under
non-consumables, and these tips are consumables (so they can be given again).
If App Review objects, the fallback is a separate non-consumable for the icons
or dropping the icon perk from tips.
