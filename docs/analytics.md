# Analytics

Dusk reports a short, fixed list of anonymous events to **Tally**, a
self-hosted collector kept in a separate private repository. It exists to
answer one class of question — *does this feature actually work for anyone?* —
and nothing else.

The published privacy policy at getdusk.app/privacy describes this behaviour to
users. Anything in this document that changes needs the policy changed with it.

## Rules

These are not style preferences. Each one is load-bearing for a claim the
privacy policy makes:

- **Closed vocabulary.** Only `AnalyticsEventName` cases can be reported.
  `AnalyticsEvent` cannot be constructed from a free-form string, so the set of
  things Dusk *can* say is reviewable in one file.
- **Nothing Plex-derived, ever.** No titles, ratings keys, library names, server
  identifiers, search terms, playback positions, or download state. This is the
  rule most likely to be broken by accident when adding an event.
- **No IP retention.** The collector uses IPs only for in-memory rate limiting.
- **No retry, no queue, no disk buffer.** A failed send is dropped. A persistent
  outbox would gradually become a device history on disk.
- **Nothing is ever shown to the user.** No error state, no spinner, no toast,
  no log. A failure to report is invisible by design.
- **Debug builds report nothing**, so development never pollutes counters.
- **Opt-out is real.** With the Settings toggle off, nothing is sent at all, and
  the install identifier is deleted.

## Where things live

```text
Dusk/Sources/Analytics/
  AnalyticsEvent.swift    Event vocabulary, property values, supporter source
  AnalyticsClient.swift   Install identifier, daily gating, encoding, transport
```

`AnalyticsClient` is constructed in `DuskApp.init` and injected into the
environment. Views read it as an **optional** environment value
(`@Environment(AnalyticsClient.self) private var analytics: AnalyticsClient?`)
so a view rendered without it in scope silently skips reporting instead of
trapping. Keep it optional at every view call site.

`SupporterStore` takes it as an optional initializer dependency, because
purchase outcomes are known there rather than in the view.

## Configuration

`AnalyticsClient.Configuration` holds the endpoint and the project write key.
**While the write key is empty the client reports nothing at all** — an
unconfigured build is silent rather than pointed at a placeholder host. Fill in
both before shipping a release build.

## Identifier

A random UUID generated on first send, stored in `UserDefaults` — deliberately
not the Keychain, so deleting the app genuinely resets it. Turning the Settings
toggle off deletes it, so re-enabling later starts a new one that cannot be
joined to anything sent before. `DuskApp` wires that through
`reportingPreferenceDidChange()` on a `.onChange` of the preference.

## Events

| Event | Fires from | Properties |
|---|---|---|
| `app_opened` | `DuskApp` task + foreground, max once per calendar day | — |
| `supporter_prompt_triggered` | `SupporterPromptPresenter`, when the gate passes | `milestone` |
| `supporter_sheet_shown` | `SupporterView.task` | `source`, `milestone` |
| `supporter_dismissed` | Close button, Maybe Later | `control`, `source` |
| `supporter_purchase_tapped` | Product rows, both platforms | `product`, `source` |
| `supporter_purchase_completed` | `SupporterStore.purchase` | `product` |
| `supporter_purchase_cancelled` | `SupporterStore.purchase` | `product` |
| `supporter_purchase_failed` | `SupporterStore.purchase` | `product` |
| `supporter_restore_tapped` | Restore Purchases | `source` |
| `supporter_manage_subscription_tapped` | Manage Subscription (iOS) | `source` |
| `supporter_link_tapped` | Privacy, Terms, About Me, GitHub | `link`, `source` |
| `supporter_products_unavailable` | Sheet rendered with nothing to buy | `source` |
| `supporter_products_retry_tapped` | Try Again | `source` |
| `supporter_icon_picker_opened` | `AppIconPickerView` | — |
| `supporter_icon_applied` | Icon applied | `icon` |

Descriptions for each event live as doc comments on the `AnalyticsEventName`
cases. They are **not** sent over the wire — the Tally console is where an event
gets its stored description, so context learned later can be added without an
app release. When adding an event here, add its description in the console too.

### The two questions this set was built to answer

1. **Is the supporter prompt reaching anyone?** `supporter_prompt_triggered` vs
   `supporter_sheet_shown` with `source=prompt`. A gap means the ladder is
   burning milestones without the sheet ever appearing.
2. **Can people actually buy?** `supporter_products_unavailable` against
   `supporter_sheet_shown`. A steady stream means the App Store products are
   not resolving in production — which local Xcode runs cannot catch, because
   both schemes attach `Dusk/Support/Dusk.storekit` and serve products from that
   file instead of App Store Connect.

Conversion is `App Store Connect units ÷ supporter_sheet_shown`. Revenue itself
is never reported; ASC is the source of truth for that.

## Adding an event

1. Add a case to `AnalyticsEventName` with a doc comment explaining it.
2. Report it with `analytics?.record(AnalyticsEvent(.case, [...]))`.
3. Check it against the rules above — particularly "nothing Plex-derived".
4. Add the description in the Tally console once it appears there.
5. If it reports something the privacy policy does not already cover, update
   the policy and `product-and-scope.md` in the same change.

## Verification

Reporting is compiled out of debug builds, so a simulator run proves only that
the call sites compile. To check the wire format, temporarily point
`Configuration.endpoint` at a local listener and build for Release.
