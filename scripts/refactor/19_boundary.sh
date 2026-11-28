#!/usr/bin/env bash
# P0-19 boundary sweep, mechanical part (docs/jellyfin/05-plan.md P0-19,
# 04 §5.4): neutral names for the types neutral code uses, and the Plex-only
# shapes and facade files moved under Providers/Plex.
#
#   1. Identifiers (19_boundary.table) in Swift code and comments (string
#      literals stay byte-identical) and in the docs.
#   2. Files:
#      - renamed with their type: MediaServiceError, AccountServer, ManagedHub;
#      - plex.tv account shapes to Providers/Plex/Models/: PlexHomeUser,
#        PlexUser, PlexPin;
#      - facade extensions that are Plex Home / plex.tv orchestration to
#        Providers/Plex/Facade/: MediaService+Home, MediaService+History.
#
# The hand-written part (the MediaServiceError domain pin, TransportSecurity,
# the facade's Plex glue, the boundary check itself) is separate commits.
# Run on a clean tree at the commit before the sweep; a rename that would
# leave an old name fails loudly.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/scripts/refactor"
TABLE="$HERE/19_boundary.table"
RENAME=(python3 -I "$HERE/lib/rename.py" "$TABLE")
cd "$ROOT"
fail() { echo "19_boundary: $*" >&2; exit 1; }
swift_files() { git ls-files -z -- 'Dusk/*.swift' 'DuskTests/*.swift' 'DuskTopShelf/*.swift'; }
doc_files() { git ls-files -z -- 'docs/*.md' AGENTS.md ':!:docs/jellyfin/*'; }
S=Dusk/Sources
[[ -e $S/MediaService/PlexServiceError.swift ]] || fail "$S/MediaService/PlexServiceError.swift is missing (already applied?)"
[[ -z "$(git status --porcelain -- Dusk DuskTests docs AGENTS.md)" ]] || fail "work tree not clean"

# 1.
swift_files | xargs -0 "${RENAME[@]}" | awk '{ n += $1; f++ } END { print "swift: " n " renames in " f " files" }'
doc_files | xargs -0 "${RENAME[@]}" --text | awk '{ n += $1; f++ } END { print "docs: " n " renames in " f " files" }'
swift_files | xargs -0 "${RENAME[@]}" --check >/dev/null || fail "old names left in Swift code"

# 2.
git mv $S/MediaService/PlexServiceError.swift $S/MediaService/MediaServiceError.swift
git mv $S/Domain/PlexServer.swift $S/Domain/AccountServer.swift
git mv $S/Domain/PlexManagedHub.swift $S/Domain/ManagedHub.swift
mkdir -p $S/Providers/Plex/Models $S/Providers/Plex/Facade
for f in PlexHomeUser PlexUser PlexPin; do
    git mv $S/Domain/$f.swift $S/Providers/Plex/Models/$f.swift
done
for f in MediaService+Home MediaService+History; do
    git mv $S/MediaService/$f.swift $S/Providers/Plex/Facade/$f.swift
done

xcodegen generate --quiet
echo "19_boundary: done"
