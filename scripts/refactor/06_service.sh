#!/usr/bin/env bash
# P0-06 service skeleton (docs/jellyfin/05-plan.md §4 P0-06, 04 §2, §3, §8, §12).
#
#   1. 06_service.pre.patch: move existing `media` names out of the way where
#      they share a scope with `plexService`, so the rename cannot rebind them.
#   2. Folders and files: PlexService/ -> MediaService/, PlexService+X.swift ->
#      MediaService+X.swift, PlexServerConnection.swift -> ServerSession.swift,
#      PlexTransportSecurity.swift -> Providers/Plex/.
#   3. Identifiers (06_service.table): PlexService -> MediaService, plexService
#      -> media, PlexServerConnection -> ServerSession, in Swift code and
#      comments (string literals stay byte-identical) and in the docs.
#   4. 06_service.post.patch, the hand-written part:
#      - Providers/Core: the provider and facet protocols, ProviderRegistry,
#        ServerPermissions, PlaybackTraits, CredentialTransportPolicy and the
#        §12 request types, as declarations (one file per facet, so each
#        wave-4 package owns its own);
#      - PlexClient (sessions, headers, request execution, decode and URL
#        helpers) extracted from +Networking; request routing, token refresh
#        and self-healing stay in MediaService+Networking unchanged;
#      - PlexAccountProvider / PlexServerProvider shells that own the client,
#        one empty Plex facet per file; the pool stores the provider on each
#        ServerSession;
#      - pure moves: +Playback -> +Streams / +WatchState, hub fetching out of
#        +Library into +Hubs;
#      - fetchHubs / HubResponse / HubItemsResponse removed (unused since P0-05a);
#      - tests and docs.
#
# Run on a clean main that has P0-05 and not yet P0-06. When main moves, reset
# to the new main and run again; a guard or a patch that no longer applies
# fails loudly and the patch is regenerated from a fresh run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/scripts/refactor"
TABLE="$HERE/06_service.table"
RENAME=(python3 -I "$HERE/lib/rename.py" "$TABLE")
cd "$ROOT"

fail() { echo "06_service: $*" >&2; exit 1; }

swift_files() { git ls-files -z -- 'Dusk/*.swift' 'DuskTests/*.swift' 'DuskTopShelf/*.swift'; }
doc_files() { git ls-files -z -- 'docs/*.md' AGENTS.md ':!:docs/jellyfin/*'; }

[[ -d Dusk/Sources/PlexService ]] || fail "Dusk/Sources/PlexService is missing (already applied?)"
[[ -e Dusk/Sources/Providers/Plex/Mappers/PlexItemMapper.swift ]] || fail "P0-05 is not applied"

# 1.
git apply "$HERE/06_service.pre.patch" || fail "pre patch does not apply; regenerate it"

# Guard: files where `media` already appears next to `plexService`. Each one
# was checked by hand (and cleared by the pre patch where a bare `media`
# shared a scope with the service); a new one needs the same check.
cooccurrence="$(comm -12 <(git grep -lw plexService -- 'Dusk/*.swift' 'DuskTests/*.swift' 'DuskTopShelf/*.swift' | sort) \
                          <(git grep -lw media -- 'Dusk/*.swift' 'DuskTests/*.swift' 'DuskTopShelf/*.swift' | sort))"
[[ "$cooccurrence" == "$(cat "$HERE/06_service.cooccurrence")" ]] \
    || fail "plexService and media now meet in other files; check them for rebinding (diff against 06_service.cooccurrence):"$'\n'"$cooccurrence"

# 2.
git mv Dusk/Sources/PlexService Dusk/Sources/MediaService
for f in $(git ls-files -- 'Dusk/Sources/MediaService' 'Dusk/Sources/Shared' | grep -E '/PlexService(\+[A-Za-z]+)?\.swift$'); do
    git mv "$f" "${f%/*}/$(basename "$f" | sed 's/^PlexService/MediaService/')"
done
git mv Dusk/Sources/MediaService/PlexServerConnection.swift Dusk/Sources/MediaService/ServerSession.swift
git mv Dusk/Sources/MediaService/PlexTransportSecurity.swift Dusk/Sources/Providers/Plex/PlexTransportSecurity.swift

# 3.
swift_files | xargs -0 "${RENAME[@]}" | awk '{ n += $1; f++ } END { print "swift: " n " renames in " f " files" }'
doc_files | xargs -0 "${RENAME[@]}" --text | awk '{ n += $1; f++ } END { print "docs: " n " renames in " f " files" }'
swift_files | xargs -0 "${RENAME[@]}" --check >/dev/null || fail "old names left in Swift code"

# 4.
git apply "$HERE/06_service.post.patch" || fail "post patch does not apply; regenerate it"
if stale="$(git grep -nE 'PlexService/|PlexService\+|PlexServerConnection|fetchHubs|HubItemsResponse' -- docs AGENTS.md project.yml scripts/parity ':!:docs/jellyfin/*')"; then
    fail "stale names or paths:"$'\n'"$stale"
fi

xcodegen generate --quiet
echo "06_service: done"
