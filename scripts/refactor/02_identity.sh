#!/usr/bin/env bash
# P0-02 identity sweep (docs/jellyfin/05-plan.md §4, 04 §4.2 / §6.1).
#
#   1. 02_identity.pre.patch: move existing `itemID` names out of the way
#      (download-queue item ids -> queueItemID, the MediaItemID-typed computed
#      `itemID` on download/history records -> mediaItemID) and give the
#      synthesized-Codable types that hold a swept field explicit CodingKeys.
#   2. Pin every CodingKey/String enum case named like a swept field to its
#      old raw value, then rename ratingKey/parentRatingKey/
#      grandparentRatingKey/librarySectionID (02_identity.table) in Swift code.
#      Keys on disk and on the wire stay byte-identical.
#   3. 02_identity.post.patch: version/part/stream/marker ids become String
#      (decoders take Int or String, encoders write numbers back as numbers,
#      Domain/MediaIDCoding.swift), ServerRegistry ("no record = Plex"), tests,
#      docs.
#
# Run on a clean main that has P0-01 and not yet P0-02. When main moves, reset
# to the new main and run again; a guard or a patch that no longer applies
# fails loudly and the patch is regenerated from a fresh run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/scripts/refactor"
cd "$ROOT"

fail() { echo "02_identity: $*" >&2; exit 1; }
swift_files() { git ls-files -z -- 'Dusk/*.swift' 'DuskTests/*.swift' 'DuskTopShelf/*.swift'; }
WORDS=ratingKey,parentRatingKey,grandparentRatingKey,librarySectionID

[[ -d Dusk/Sources/Domain ]] || fail "P0-01 is not applied (no Dusk/Sources/Domain)"
grep -q '    let ratingKey: String' Dusk/Sources/Domain/MediaItemID.swift || fail "already applied?"

# 1.
git apply "$HERE/02_identity.pre.patch" || fail "pre patch does not apply; regenerate it"

# Guard: files that already use a target name next to its old name. Bare
# identifiers there could rebind silently; each was checked by hand.
cooccurrence="$(for pair in ratingKey:itemID parentRatingKey:parentID grandparentRatingKey:grandparentID librarySectionID:libraryID; do
    old=${pair%%:*}; new=${pair##*:}
    comm -12 <(git grep -lw "$old" -- 'Dusk/*.swift' 'DuskTests/*.swift' 'DuskTopShelf/*.swift' | sort) \
             <(git grep -lw "$new" -- 'Dusk/*.swift' 'DuskTests/*.swift' 'DuskTopShelf/*.swift' | sort) | sed "s|^|$old:$new |"
done)"
expected_cooccurrence="ratingKey:itemID Dusk/Sources/Downloads/DownloadModels.swift
ratingKey:itemID Dusk/Sources/Downloads/PlexDownloadQueue.swift
ratingKey:itemID Dusk/Sources/Features/Detail/DetailCollectionShelves.swift
ratingKey:itemID Dusk/Sources/Features/Detail/DetailExtrasShelf.swift
ratingKey:itemID Dusk/Sources/Features/Detail/SeasonDetailView.swift
ratingKey:itemID Dusk/Sources/Features/Detail/SeriesDetailView.swift
ratingKey:itemID Dusk/Sources/Features/Player/PlaybackCoordinator+UpNext.swift
ratingKey:itemID Dusk/Sources/Features/Player/PlaybackPresentationModels.swift
ratingKey:itemID DuskTests/PlaybackQueueTests.swift
librarySectionID:libraryID Dusk/Sources/Features/Home/HomeHubArrangement.swift"
[[ "$cooccurrence" == "$expected_cooccurrence" ]] || fail "old and new names now meet in other files; check them for rebinding:"$'\n'"$cooccurrence"

# Guard: the types holding a swept stored property. Codable ones need CodingKeys.
types="$(swift_files | xargs -0 python3 -I "$HERE/lib/swept_types.py" "$WORDS")"
[[ "$types" == "$(cat "$HERE/02_identity.types")" ]] || fail "types with swept fields changed (diff against 02_identity.types):"$'\n'"$types"
if grep -q 'codable=True keys=False' <<<"$types"; then fail "a Codable type with a swept field has synthesized keys"; fi

# 2.
pinned="$(swift_files | xargs -0 python3 -I "$HERE/lib/pin_coding_keys.py" "$WORDS" | awk '{ n += $1 } END { print n + 0 }')"
[[ "$pinned" == 29 ]] || fail "pinned $pinned CodingKey cases, expected 29; check the new ones"
swift_files | xargs -0 python3 -I "$HERE/lib/rename.py" "$HERE/02_identity.table" \
    | awk '{ n += $1; f++ } END { print "swift: " n " renames in " f " files" }'
swift_files | xargs -0 python3 -I "$HERE/lib/rename.py" "$HERE/02_identity.table" --check >/dev/null \
    || fail "old field names left in Swift code"

# 3.
git apply "$HERE/02_identity.post.patch" || fail "post patch does not apply; regenerate it"

xcodegen generate --quiet
echo "02_identity: done"
