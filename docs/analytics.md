# Analytics

Dusk reports a short, fixed list of anonymous events to the **self-hosted Rybbit
instance at `stats.marvinvr.ch`** — the same instance getdusk.app already uses,
under a separate Rybbit "site" so app and web numbers never mix.

It exists to answer one class of question — *does this feature actually work for
anyone?* — and nothing else.

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
  AnalyticsEvent.swift    Event vocabulary, pageview/path mapping, property values
  AnalyticsClient.swift   Install identifier, daily gating, Rybbit payload, transport
```

`AnalyticsClient` is constructed in `DuskApp.init` and injected into the
environment. Views read it as an **optional** environment value
(`@Environment(AnalyticsClient.self) private var analytics: AnalyticsClient?`)
so a view rendered without it in scope silently skips reporting instead of
trapping. Keep it optional at every view call site.

`SupporterStore` takes it as an optional initializer dependency, because
purchase outcomes are known there rather than in the view.

## The Rybbit wire format

`POST https://stats.marvinvr.ch/api/track`, site `e76b9d7b1558`. Traps worth
knowing, all of them things Rybbit does differently from a normal JSON API:

- **`properties` is a JSON-encoded *string*, not an object.** Nesting is not
  supported, values may only be strings or numbers (no booleans — hence
  `AnalyticsValue` has no bool case), and the whole bag is capped at 2 KB.
- **Event names cap at 256 characters.**
- **`user_id` is supplied by us.** Left unset, Rybbit derives identity by
  hashing IP + User-Agent; passing our own random install identifier means it
  never has to. `app_version`, `platform` and `language` ride along as
  properties on every event.
- **`user_agent` is sent explicitly** (`Dusk/1.5.1 (iOS 18.0)`) rather than
  letting URLSession's CFNetwork default through, which reads as neither a
  browser nor a known client.
- **An API key is optional.** Rybbit accepts events from any origin without one.
  `Configuration.apiKey` exists for the case where bot detection starts eating
  events — generate one in the Rybbit site's Settings → API Key and it is sent
  as `Authorization: Bearer`.

Rybbit uses the request IP transiently to resolve country/region and does not
store the raw address. That coarse geolocation is the one thing the app reports
without meaning to, and the privacy policy says so.

## Events

`app_opened` is sent as a **pageview** so Rybbit's built-in users, sessions,
retention and countries dashboards are driven by it. Everything else is a
**custom event**. Paths are synthetic — the app has no URLs.

| Event | Type | Path | Properties |
|---|---|---|---|
| `app_opened` | pageview | `/app` | — |
| `supporter_prompt_triggered` | custom | `/supporter` | `milestone` |
| `supporter_sheet_shown` | custom | `/supporter` | `source`, `milestone` |
| `supporter_dismissed` | custom | `/supporter` | `control`, `source` |
| `supporter_purchase_tapped` | custom | `/supporter` | `product`, `source` |
| `supporter_purchase_completed` | custom | `/supporter` | `product` |
| `supporter_purchase_cancelled` | custom | `/supporter` | `product` |
| `supporter_purchase_failed` | custom | `/supporter` | `product` |
| `supporter_restore_tapped` | custom | `/supporter` | `source` |
| `supporter_manage_subscription_tapped` | custom | `/supporter` | `source` |
| `supporter_link_tapped` | custom | `/supporter` | `link`, `source` |
| `supporter_products_unavailable` | custom | `/supporter` | `source` |
| `supporter_products_retry_tapped` | custom | `/supporter` | `source` |
| `supporter_icon_picker_opened` | custom | `/supporter/icons` | — |
| `supporter_icon_applied` | custom | `/supporter/icons` | `icon` |

Every event also carries `app_version`, `platform` (`ios`/`ipados`/`tvos`) and
`language`. Descriptions live as doc comments on the `AnalyticsEventName` cases.

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

1. Add a case to `AnalyticsEventName` with a doc comment explaining it, and give
   it a `path` if `/supporter` is wrong for it.
2. Report it with `analytics?.record(AnalyticsEvent(.case, [...]))`.
3. Check it against the rules above — particularly "nothing Plex-derived".
4. If it reports something the privacy policy does not already cover, update the
   policy and `product-and-scope.md` in the same change.

## Verification

Reporting is compiled out of debug builds, so a simulator run proves only that
the call sites compile. To see real traffic, build for Release, or temporarily
flip `isActive` and watch the Rybbit live view for site `e76b9d7b1558`.
