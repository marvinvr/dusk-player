#!/usr/bin/env bash
# P0-03 field vocabulary (docs/jellyfin/05-plan.md §4, 04 §4.2 / §6.2).
#
#   1. 03_vocabulary.pre.patch: explicit CodingKeys for the two
#      synthesized-Codable types holding a swept field (SiriCatalogEntry,
#      the transcode decision's PlannedStream).
#   2. Pin CodingKey/String enum cases, then rename viewOffset, viewCount,
#      lastViewedAt, leafCount, viewedLeafCount, streamType, colorTrc and
#      PlexStreamType (03_vocabulary.table). Keys on disk and on the wire stay.
#   3. 03_vocabulary.post.patch (compiler-driven, by hand): MediaStream.
#      isServerSelected, DolbyVisionInfo, ExternalIDs in place of
#      PlexGuid.value(for:), ContentKey.native + contentAliases (inert), tests,
#      docs.
#
# Run on a clean main that has P0-02 and not yet P0-03. When main moves, reset
# to the new main and run again; a failing guard or patch means regenerate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/scripts/refactor"
cd "$ROOT"

fail() { echo "03_vocabulary: $*" >&2; exit 1; }
swift_files() { git ls-files -z -- 'Dusk/*.swift' 'DuskTests/*.swift' 'DuskTopShelf/*.swift'; }
WORDS=viewOffset,viewCount,lastViewedAt,leafCount,viewedLeafCount,streamType,colorTrc

grep -q 'decodeID(forKey' Dusk/Sources/Domain/MediaDetails.swift || fail "P0-02 is not applied"
grep -q '    let viewOffset: Int?' Dusk/Sources/Domain/MediaItem.swift || fail "already applied?"

# 1.
git apply "$HERE/03_vocabulary.pre.patch" || fail "pre patch does not apply; regenerate it"

# Guard: files where an old name already meets its target name; each was
# checked by hand for bare identifiers that could rebind.
cooccurrence="$(grep -v '^\s*#' "$HERE/03_vocabulary.table" | awk 'NF == 2 { print $1 ":" $2 }' | while read -r pair; do
    old=${pair%%:*}; new=${pair##*:}
    comm -12 <(git grep -lw "$old" -- 'Dusk/*.swift' 'DuskTests/*.swift' 'DuskTopShelf/*.swift' | sort) \
             <(git grep -lw "$new" -- 'Dusk/*.swift' 'DuskTests/*.swift' 'DuskTopShelf/*.swift' | sort) | sed "s|^|$old:$new |"
done)"
[[ "$cooccurrence" == "$(cat "$HERE/03_vocabulary.cooccurrence")" ]] \
    || fail "old and new names now meet in other files; check them for rebinding:"$'\n'"$cooccurrence"

# Guard: the types holding a swept stored property. A Codable one needs
# explicit keys (LenientStream decodes through its own pinned ProbeKeys).
types="$(swift_files | xargs -0 python3 -I "$HERE/lib/swept_types.py" "$WORDS")"
[[ "$types" == "$(cat "$HERE/03_vocabulary.types")" ]] || fail "types with swept fields changed (diff against 03_vocabulary.types):"$'\n'"$types"
if grep 'codable=True keys=False' <<<"$types" | grep -qv ' LenientStream '; then
    fail "a Codable type with a swept field has synthesized keys"
fi

# 2.
pinned="$(swift_files | xargs -0 python3 -I "$HERE/lib/pin_coding_keys.py" "$WORDS" | awk '{ n += $1 } END { print n + 0 }')"
[[ "$pinned" == 23 ]] || fail "pinned $pinned CodingKey cases, expected 23; check the new ones"
swift_files | xargs -0 python3 -I "$HERE/lib/rename.py" "$HERE/03_vocabulary.table" \
    | awk '{ n += $1; f++ } END { print "swift: " n " renames in " f " files" }'
swift_files | xargs -0 python3 -I "$HERE/lib/rename.py" "$HERE/03_vocabulary.table" --check >/dev/null \
    || fail "old field names left in Swift code"

# 3.
git apply "$HERE/03_vocabulary.post.patch" || fail "post patch does not apply; regenerate it"

xcodegen generate --quiet
echo "03_vocabulary: done"
