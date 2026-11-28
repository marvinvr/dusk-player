#!/usr/bin/env bash
# P0-01 type rename sweep (docs/jellyfin/05-plan.md §4): rename the domain types
# per 04 §4.1 (table in 01_types.table) and move Models/ to Domain/. Type and
# file names only; string literals are never touched.
#
# Run from a clean checkout of main that has not had the sweep yet:
#   scripts/refactor/01_types.sh
# When main moves, reset to the new main and run it again instead of merging.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/scripts/refactor"
TABLE="$HERE/01_types.table"
RENAME=(python3 -I "$HERE/lib/rename.py" "$TABLE")
cd "$ROOT"

fail() { echo "01_types: $*" >&2; exit 1; }

[[ -d Dusk/Sources/Models ]] || fail "Dusk/Sources/Models is missing (sweep already applied?)"
[[ ! -e Dusk/Sources/Domain ]] || fail "Dusk/Sources/Domain already exists"

swift_files() { git ls-files -- 'Dusk/*.swift' 'DuskTests/*.swift' 'DuskTopShelf/*.swift'; }
doc_files() { git ls-files -- 'docs/*.md' ':!:docs/jellyfin/*'; }

# Guard: no target name may already be declared as a top-level type. (Nested
# `Episode` types exist in SmartDownloadPlanner and SiriNextEpisodePicker; no
# code in those scopes names PlexEpisode.)
targets="$(grep -v '^\s*#' "$TABLE" | awk 'NF == 2 { print $2 }' | paste -sd '|' -)"
if clash="$(swift_files | xargs grep -nE "^(public |internal |private |fileprivate )?(final )?(struct|enum|class|actor|protocol|typealias)[[:space:]]+($targets)\b")"; then
    fail "target names are already declared:"$'\n'"$clash"
fi

# 1. Files: Models/ -> Domain/, Plex-named files of renamed types follow the type.
git mv Dusk/Sources/Models Dusk/Sources/Domain
move() { git mv "Dusk/Sources/$1" "Dusk/Sources/$2"; }
while read -r from to; do
    move "Domain/$from.swift" "Domain/$to.swift"
done <<'EOF'
PlexContentKey ContentKey
PlexEpisode Episode
PlexExtra Extra
PlexHub HomeRow
PlexItem MediaItem
PlexLibrary Library
PlexLibraryCollection MediaCollection
PlexLiveTV LiveTV
PlexMediaDetails MediaDetails
PlexMediaType MediaKind
PlexPhoto PhotoItem
PlexPlaybackHistoryEntry PlaybackHistoryEntry
PlexPlaylist Playlist
PlexRating Rating
PlexSearchResult SearchSection
PlexSeason Season
PlexServerScoped MediaItemID
PlexSubtitleSearchResult SubtitleSearchResult
PlexWatchlist Watchlist
EOF
move Shared/PlexItemPager.swift Shared/MediaItemPager.swift
move Shared/PlexItemPosterCollections.swift Shared/MediaItemPosterCollections.swift
move Shared/PlexItemPresentation.swift Shared/MediaItemPresentation.swift
move PlexService/MultiServer/PlexItemMerge.swift PlexService/MultiServer/MediaItemMerge.swift

# 2. Identifiers in Swift code and comments (string literals stay byte-identical).
swift_files | xargs "${RENAME[@]}" | awk '{ n += $1; f++ } END { print "swift: " n " renames in " f " files" }'

# 3. Docs (not docs/jellyfin, whose tables describe the rename itself).
doc_files | xargs "${RENAME[@]}" --text | awk '{ n += $1; f++ } END { print "docs: " n " renames in " f " files" }'
doc_files | xargs perl -pi -e '
    s{Sources/Models/}{Sources/Domain/}g;
    s{(?<![A-Za-z/])Models/}{Domain/}g;
    s{\bPlexPhoto\.swift\b}{PhotoItem.swift}g;
    s{\bPlexLiveTV\.swift\b}{LiveTV.swift}g;
    s{\bPlexServerScoped\.swift\b}{MediaItemID.swift}g;
    s{\bPlexWatchlist\.swift\b}{Watchlist.swift}g;
    s{\bPlexItemPosterCollections\.swift\b}{MediaItemPosterCollections.swift}g;
    s{\bPlexItemPresentation\.swift\b}{MediaItemPresentation.swift}g;
'

# 4. Guards: nothing old left in code, no stale paths.
swift_files | xargs "${RENAME[@]}" --check >/dev/null || fail "old type names left in Swift code"
if stale="$(git grep -nE '(Sources/|`)Models/' -- docs project.yml ':!:docs/jellyfin/*')"; then
    fail "stale Models/ paths:"$'\n'"$stale"
fi

# 5. Project file.
xcodegen generate --quiet
echo "01_types: done"
