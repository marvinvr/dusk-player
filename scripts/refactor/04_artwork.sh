#!/usr/bin/env bash
# P0-04 ArtworkRef sweep (docs/jellyfin/05-plan.md §4, 04 §10).
#
#   1. lib/artwork_calls.py rewrites every call of PlexService's path-based
#      `imageURL(for: path, serverID:, width:, height:)` into
#      `imageURL(for: ArtworkRef(serverID:, path:), size: ImageSize(...))`.
#      The server stays the one the call site passed, so URLs are unchanged.
#   2. 04_artwork.post.patch: Domain/Artwork.swift (ArtworkRef, ArtworkSet,
#      ImageSize), the ref-based PlexService.imageURL(for:size:), the poster/
#      landscape fallback helpers moved from MediaItem onto ArtworkSet
#      (MediaItem.artwork/preferredPoster/fallbackPoster/preferredLandscape),
#      tests, docs.
#
# Deferred to P0-08 (images facet): removing imageServerConnection(for: URL).
# The image loader still decides authentication by matching a URL's host to a
# connected server; replacing that needs the ref to travel with every image
# URL through the views (an ImageRequest), which is the facet's job.
#
# Run on a clean main that has P0-03 and not yet P0-04. When main moves, reset
# to the new main and run again; a patch that does not apply means regenerate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/scripts/refactor"
cd "$ROOT"

fail() { echo "04_artwork: $*" >&2; exit 1; }

grep -q 'struct DolbyVisionInfo' Dusk/Sources/Domain/MediaDetails.swift || fail "P0-03 is not applied"
[[ ! -e Dusk/Sources/Domain/Artwork.swift ]] || fail "already applied?"

# 1.
calls="$(git ls-files -z -- 'Dusk/*.swift' | xargs -0 python3 -I "$HERE/lib/artwork_calls.py" | awk '{ n += $1 } END { print n + 0 }')"
[[ "$calls" == 44 ]] || fail "rewrote $calls imageURL calls, expected 44; check the new ones"

# 2.
git apply "$HERE/04_artwork.post.patch" || fail "post patch does not apply; regenerate it"
if git grep -nE 'imageURL\(for: [^A)]*, serverID:' -- 'Dusk/*.swift' >/dev/null; then
    fail "path-based imageURL calls left"
fi

xcodegen generate --quiet
echo "04_artwork: done"
