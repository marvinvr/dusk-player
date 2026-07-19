# Dusk Agent Docs

This directory is the working map for future agents. It sits between the short
root-level overview files and the source itself:

- `product-and-scope.md` explains product intent and long-lived constraints.
- `codebase-map.md` gives the quick source tree map.
- `STYLE.md` is the visual source of truth.
- `docs/` explains how the current implementation is wired and where to make
  changes safely.

## Reading Order

Agents must read the repo-local `AGENTS.md` before planning, editing,
committing, or pushing. It is the source of truth for workflow expectations,
verification, and multi-agent git hygiene.

1. `AGENTS.md`
2. `AGENTS.local.md` when present
3. `codebase-map.md`
4. `STYLE.md` when touching UI
5. The relevant file in this directory
6. The source files referenced by that doc

For most feature work, start with `codebase-map.md`, then jump to the topic file
that owns the behavior you are changing.

## Files

- `codebase-map.md`: source layout, ownership boundaries, and where new code goes.
- `product-and-scope.md`: product intent, platform targets, non-goals, and
  long-lived project constraints.
- `data-and-plex.md`: `PlexService`, Plex models, requests, images, and API shape.
- `playback.md`: playback coordinator, resolver, engines, player UI, timeline,
  scrobble, and up next.
- `audio-silence-postmortem.md`: the 2026-07 VLCKit silent-audio saga — the
  real bugs, the false leads, the audio revive mitigation, and the on-device
  diagnostic tooling. MANDATORY reading before touching VLCKit audio,
  playback recovery, or anything gated on "steady playback".
- `ui-features.md`: app shell, shared SwiftUI primitives, home, libraries, detail,
  search, settings, and platform UI rules.
- `supporter.md`: supporter tier — StoreKit products and status rules, the
  one-time prompt gating, and alternate app icons.
- `downloads-and-offline.md`: download queue, local file storage, metadata cache,
  offline playback, and delayed watch-state sync.
- `development-workflow.md`: setup, project generation, verification, git, and doc
  maintenance workflow.

## Depth And Style

Docs should be concise but operational. Prefer:

- the responsibility of a component;
- the important data/control flow;
- extension points and where to edit;
- invariants and traps that are easy to break;
- verification steps for the area.

Avoid:

- restating every method or property;
- duplicating code comments;
- stale TODO lists without a concrete owner;
- giant files that try to document the whole app.

When a meaningful code change alters a flow, boundary, reusable component,
preference, or setup/verification step, update the matching doc in the same
change.
