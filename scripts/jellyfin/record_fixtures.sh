#!/usr/bin/env bash
# Records the Jellyfin JSON fixtures the DTO decoding tests run on
# (DuskTests/Fixtures/Jellyfin/jellyfin-*.json).
#
#   scripts/jellyfin/record_fixtures.sh
#
# Environment (all optional):
#   JELLYFIN_URL            server base URL           (default http://jellyfin-demo)
#   JELLYFIN_USER           user name                 (default duskcompare)
#   JELLYFIN_PASSWORD_FILE  file holding the password (default ~/.config/jellyfin-demo/compare-password)
#   OUT                     fixture directory         (default DuskTests/Fixtures/Jellyfin)
#
# Rules this script keeps, because the demo server is shared and the repo is public:
# - Its own DeviceId. Signing in with a DeviceId revokes the previous token for
#   it (03 §10.2), so sharing one with another agent or the app logs it out.
# - Read-only calls, PlaybackInfo (no stream is ever fetched, no playback is
#   reported) and one temporary playlist that is deleted again on exit.
# - Tokens, ApiKey query values, play-session ids, Quick Connect secrets and
#   client IP addresses are scrubbed before anything is written. The script
#   fails and deletes its output when the live token or the password still
#   appears in a fixture.
# - The session is logged out on exit, whatever happens.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
JF=${JELLYFIN_URL:-http://jellyfin-demo}
JF=${JF%/}
USER_NAME=${JELLYFIN_USER:-duskcompare}
PASSWORD_FILE=${JELLYFIN_PASSWORD_FILE:-$HOME/.config/jellyfin-demo/compare-password}
OUT=${OUT:-$ROOT/DuskTests/Fixtures/Jellyfin}
DEVICE_ID=dusk-fixture-recorder
IDENTITY='MediaBrowser Client="Dusk", Device="Dusk%20Fixture%20Recorder", DeviceId="'"$DEVICE_ID"'", Version="1.0"'

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
[[ -r "$PASSWORD_FILE" ]] || { echo "Password file not readable: $PASSWORD_FILE" >&2; exit 1; }

TOKEN=""
USER_ID=""
PLAYLIST_ID=""
WORK=$(mktemp -d)

cleanup() {
    if [[ -n "$PLAYLIST_ID" && -n "$TOKEN" ]]; then
        curl -sS -o /dev/null -X DELETE -H "Authorization: $IDENTITY, Token=\"$TOKEN\"" "$JF/Items/$PLAYLIST_ID" || true
    fi
    if [[ -n "$TOKEN" ]]; then
        curl -sS -o /dev/null -X POST -H "Authorization: $IDENTITY, Token=\"$TOKEN\"" "$JF/Sessions/Logout" || true
    fi
    [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf -- "$WORK"
}
trap cleanup EXIT

# --- Sign in --------------------------------------------------------------
jq -n --arg u "$USER_NAME" --rawfile p "$PASSWORD_FILE" '{Username: $u, Pw: ($p | rtrimstr("\n"))}' \
    | curl -sS -f -X POST -H "Authorization: $IDENTITY" -H 'Content-Type: application/json' \
        --data-binary @- "$JF/Users/AuthenticateByName" > "$WORK/auth.json"
TOKEN=$(jq -r .AccessToken "$WORK/auth.json")
USER_ID=$(jq -r .User.Id "$WORK/auth.json")
[[ -n "$TOKEN" && "$TOKEN" != null ]] || { echo "Sign-in returned no token" >&2; exit 1; }
AUTH="$IDENTITY, Token=\"$TOKEN\""

mkdir -p "$OUT"
rm -f -- "${OUT:?}"/jellyfin-*.json

# Scrubs secrets and volatile values, sorts keys so re-records diff cleanly.
SCRUB='
def scrub_string:
    gsub($token; "REDACTED_TOKEN")
    | gsub("(?<k>[Aa][Pp][Ii][Kk][Ee][Yy]|api_key)=[^&\"]*"; "\(.k)=REDACTED_TOKEN")
    | gsub("(?<k>PlaySessionId|playSessionId)=[^&\"]*"; "\(.k)=REDACTED_PLAY_SESSION");
walk(
    if type == "object" then
        with_entries(
            if .key == "AccessToken" then .value = "REDACTED_TOKEN"
            elif .key == "PlaySessionId" and (.value | type) == "string" then .value = "REDACTED_PLAY_SESSION"
            elif .key == "Secret" then .value = "REDACTED_SECRET"
            elif .key == "Code" and (.value | type) == "string" then .value = "000000"
            elif .key == "RemoteEndPoint" then .value = "0.0.0.0"
            elif (.key | IN("LastActivityDate", "LastLoginDate", "LastPlaybackCheckIn", "DateAdded"))
                and (.value | type) == "string" then .value = "2026-01-01T00:00:00.0000000Z"
            else . end)
    elif type == "string" then scrub_string
    else . end)'

save() { # name < json
    jq -S --arg token "$TOKEN" "$SCRUB" > "$OUT/jellyfin-$1.json"
}
call() { # method path [body]
    if [[ $# -ge 3 ]]; then
        curl -sS -f -X "$1" -H "Authorization: $AUTH" -H 'Content-Type: application/json' --data-binary "$3" "$JF$2"
    else
        curl -sS -f -X "$1" -H "Authorization: $AUTH" "$JF$2"
    fi
}
get() { call GET "$2" | save "$1"; }
slug() { tr '[:upper:]' '[:lower:]' <<< "$1" | sed -E 's/[^a-z0-9]+/-/g; s/^-//; s/-$//'; }
id_named() { # list.json name
    jq -r --arg n "$2" 'first(.Items[] | select(.Name == $n) | .Id) // empty' "$1"
}

U="userId=$USER_ID"
LIST_FIELDS="fields=Overview,Genres,ProviderIds,ChildCount,RecursiveItemCount,DateCreated,MediaSourceCount,PrimaryImageAspectRatio"

# --- System, sign-in, users ------------------------------------------------
curl -sS -f "$JF/System/Info/Public" | save system-info-public
curl -sS -f "$JF/QuickConnect/Enabled" | save quickconnect-enabled
curl -sS -f "$JF/Users/Public" | save users-public
curl -sS -f -X POST -H "Authorization: $IDENTITY" "$JF/QuickConnect/Initiate" | save quickconnect-initiate
save authenticate-by-name < "$WORK/auth.json"
get users-me "/Users/Me"
get system-endpoint "/System/Endpoint"

# --- Libraries and browse --------------------------------------------------
call GET "/UserViews?$U" > "$WORK/views.json"
save user-views < "$WORK/views.json"
MOVIES_VIEW=$(id_named "$WORK/views.json" "Movies")
REAL_MOVIES_VIEW=$(id_named "$WORK/views.json" "Real Movies")
REAL_TV_VIEW=$(id_named "$WORK/views.json" "Real TV")
PHOTOS_VIEW=$(id_named "$WORK/views.json" "Photos")
HOME_VIDEOS_VIEW=$(id_named "$WORK/views.json" "Home Videos")

get items-movies-browse "/Items?$U&parentId=$REAL_MOVIES_VIEW&recursive=true&includeItemTypes=Movie&sortBy=SortName&sortOrder=Ascending&limit=10&$LIST_FIELDS"
get items-series-unplayed "/Items?$U&parentId=$REAL_TV_VIEW&recursive=true&includeItemTypes=Series&filters=IsUnplayed&limit=10&$LIST_FIELDS"
get items-count-only "/Items?$U&parentId=$REAL_MOVIES_VIEW&recursive=true&includeItemTypes=Movie&limit=0"
get items-filters "/Items/Filters?$U&parentId=$REAL_MOVIES_VIEW"
get items-counts "/Items/Counts?$U"
get genres "/Genres?$U&parentId=$REAL_MOVIES_VIEW"
get items-photo-albums "/Items?$U&parentId=$PHOTOS_VIEW&fields=ChildCount,RecursiveItemCount"
get items-photo-timeline "/Items?$U&parentId=$PHOTOS_VIEW&recursive=true&includeItemTypes=Photo,Video&sortBy=PremiereDate,DateCreated&sortOrder=Descending&limit=10&fields=Width,Height,DateCreated"
get items-home-videos "/Items?$U&parentId=$HOME_VIDEOS_VIEW&recursive=true&includeItemTypes=Video&limit=10&fields=MediaSources,DateCreated"
get items-boxsets "/Items?$U&includeItemTypes=BoxSet&recursive=true"

# --- Home rows ---------------------------------------------------------------
get resume "/UserItems/Resume?$U&mediaTypes=Video&limit=10&fields=PrimaryImageAspectRatio"
get next-up "/Shows/NextUp?$U&limit=10&enableResumable=false&enableRewatching=false"
get latest-movies "/Items/Latest?$U&parentId=$REAL_MOVIES_VIEW&limit=10&groupItems=true"
get latest-tv "/Items/Latest?$U&parentId=$REAL_TV_VIEW&limit=10&groupItems=true"
get suggestions "/Items/Suggestions?$U&limit=5"

# --- Search ------------------------------------------------------------------
get items-search "/Items?$U&searchTerm=office&recursive=true&includeItemTypes=Movie,Series,Episode,BoxSet,Playlist&limit=10"
get search-hints "/Search/Hints?$U&searchTerm=office&limit=10"

# --- Details: every torture file in "Movies" plus the real films -----------
call GET "/Items?$U&parentId=$MOVIES_VIEW&recursive=true&includeItemTypes=Movie" > "$WORK/movies.json"
call GET "/Items?$U&parentId=$REAL_MOVIES_VIEW&recursive=true&includeItemTypes=Movie" > "$WORK/real-movies.json"
for list in "$WORK/movies.json" "$WORK/real-movies.json"; do
    jq -r '.Items[] | [.Id, .Name] | @tsv' "$list" | while IFS=$'\t' read -r id name; do
        get "item-$(slug "$name")" "/Items/$id?$U"
    done
done
KNIVES_OUT=$(id_named "$WORK/real-movies.json" "Knives Out")
DUNE=$(id_named "$WORK/real-movies.json" "Dune: Part Two")
PADDINGTON=$(id_named "$WORK/real-movies.json" "Paddington 2")
AV1_SDR=$(id_named "$WORK/movies.json" "AV1 SDR Test (2026)")

get user-data-knives-out "/UserItems/$KNIVES_OUT/UserData?$U"
get special-features-knives-out "/Items/$KNIVES_OUT/SpecialFeatures?$U"
get local-trailers-knives-out "/Items/$KNIVES_OUT/LocalTrailers?$U"
get similar-knives-out "/Items/$KNIVES_OUT/Similar?$U&limit=5"
get intros-knives-out "/Items/$KNIVES_OUT/Intros?$U"
get media-segments-knives-out "/MediaSegments/$KNIVES_OUT"
get item-images-knives-out "/Items/$KNIVES_OUT/Images"
PERSON=$(jq -r '.People[0].Id' "$OUT/jellyfin-item-knives-out.json")
get item-person "/Items/$PERSON?$U"

# --- A show: series, seasons, episodes, The Office S01E01 -------------------
call GET "/Items?$U&parentId=$REAL_TV_VIEW&recursive=true&includeItemTypes=Series" > "$WORK/series.json"
OFFICE=$(id_named "$WORK/series.json" "The Office")
get item-series-the-office "/Items/$OFFICE?$U"
call GET "/Shows/$OFFICE/Seasons?$U" > "$WORK/seasons.json"
save shows-seasons-the-office < "$WORK/seasons.json"
SEASON1=$(jq -r 'first(.Items[] | select(.IndexNumber == 1) | .Id)' "$WORK/seasons.json")
get item-season-the-office-s01 "/Items/$SEASON1?$U"
call GET "/Shows/$OFFICE/Episodes?$U&seasonId=$SEASON1&fields=Overview,MediaSources,Chapters,Trickplay,ProviderIds" > "$WORK/episodes.json"
save shows-episodes-the-office-s01 < "$WORK/episodes.json"
S01E01=$(jq -r 'first(.Items[] | select(.IndexNumber == 1) | .Id)' "$WORK/episodes.json")
get item-the-office-s01e01 "/Items/$S01E01?$U"
get media-segments-the-office-s01e01 "/MediaSegments/$S01E01"
get ancestors-the-office-s01e01 "/Items/$S01E01/Ancestors?$U"
get next-up-the-office "/Shows/NextUp?$U&seriesId=$OFFICE&limit=1"

# --- Playback decisions (no stream is fetched) -------------------------------
PROFILE_VLC='{"DirectPlayProfiles":[{"Type":"Video"},{"Type":"Audio"}],"TranscodingProfiles":[],"CodecProfiles":[],
  "SubtitleProfiles":[{"Format":"srt","Method":"Embed"},{"Format":"subrip","Method":"Embed"},{"Format":"ass","Method":"Embed"},
  {"Format":"ssa","Method":"Embed"},{"Format":"pgssub","Method":"Embed"},{"Format":"dvdsub","Method":"Embed"},
  {"Format":"srt","Method":"External"},{"Format":"ass","Method":"External"},{"Format":"vtt","Method":"External"}]}'
PROFILE_AVPLAYER='{"DirectPlayProfiles":[{"Type":"Video","Container":"mp4,m4v,mov","VideoCodec":"h264,hevc,av1","AudioCodec":"aac,ac3,eac3,alac,flac,mp3"}],
  "TranscodingProfiles":[{"Type":"Video","Protocol":"hls","Container":"mp4","VideoCodec":"hevc,h264","AudioCodec":"eac3,ac3,aac",
    "MaxAudioChannels":"8","MinSegments":2,"BreakOnNonKeyFrames":true,"Context":"Streaming"}],
  "CodecProfiles":[{"Type":"Video","Codec":"hevc","Conditions":[{"Condition":"EqualsAny","Property":"VideoRangeType",
    "Value":"SDR|HDR10|HDR10Plus|HLG|DOVI|DOVIWithHDR10|DOVIWithHLG|DOVIWithSDR","IsRequired":false}]}],
  "SubtitleProfiles":[{"Format":"vtt","Method":"External"}]}'
playback_info() { # name itemId profile audioIndex subtitleIndex
    local body
    body=$(jq -n --arg u "$USER_ID" --arg ms "$2" --argjson p "$3" --argjson a "$4" --argjson s "$5" \
        '{UserId: $u, MediaSourceId: $ms, DeviceProfile: $p, AudioStreamIndex: $a, SubtitleStreamIndex: $s,
          MaxStreamingBitrate: 400000000, EnableDirectPlay: true, EnableDirectStream: true, EnableTranscoding: true,
          AllowVideoStreamCopy: true, AllowAudioStreamCopy: true, AutoOpenLiveStream: false}')
    call POST "/Items/$2/PlaybackInfo?$U" "$body" | save "$1"
}
playback_info playback-info-knives-out-avplayer "$KNIVES_OUT" "$PROFILE_AVPLAYER" 1 -1
playback_info playback-info-knives-out-avplayer-srt "$KNIVES_OUT" "$PROFILE_AVPLAYER" 1 13
playback_info playback-info-knives-out-vlc "$KNIVES_OUT" "$PROFILE_VLC" 1 -1
playback_info playback-info-dune-avplayer "$DUNE" "$PROFILE_AVPLAYER" 1 -1
playback_info playback-info-paddington-avplayer-dts "$PADDINGTON" "$PROFILE_AVPLAYER" 2 -1
playback_info playback-info-av1-sdr-vlc "$AV1_SDR" "$PROFILE_VLC" 2 0
get sessions "/Sessions?deviceId=$DEVICE_ID"

# --- Playlists (one temporary playlist, deleted on exit) --------------------
CREATE=$(jq -n --arg u "$USER_ID" --arg a "$KNIVES_OUT" --arg b "$PADDINGTON" \
    '{Name: "Dusk Fixture Recorder", Ids: [$a, $b], UserId: $u, MediaType: "Video", IsPublic: false}')
call POST "/Playlists" "$CREATE" > "$WORK/playlist.json"
PLAYLIST_ID=$(jq -r .Id "$WORK/playlist.json")
save playlist-create < "$WORK/playlist.json"
get items-playlists "/Items?$U&includeItemTypes=Playlist&recursive=true&fields=ChildCount"
get playlist-items "/Playlists/$PLAYLIST_ID/Items?$U"
get playlist "/Playlists/$PLAYLIST_ID"

# --- Live TV (no tuner on the demo server: empty lists) ---------------------
get livetv-info "/LiveTv/Info"
get livetv-guide-info "/LiveTv/GuideInfo"
get livetv-channels "/LiveTv/Channels?$U&addCurrentProgram=true&limit=10"

# --- Leak check -------------------------------------------------------------
PASSWORD=$(tr -d '\n' < "$PASSWORD_FILE")
if grep -rlF -e "$TOKEN" "$OUT" >/dev/null || { [[ -n "$PASSWORD" ]] && grep -rlF -e "$PASSWORD" "$OUT" >/dev/null; }; then
    rm -f -- "${OUT:?}"/jellyfin-*.json
    echo "A secret survived scrubbing; fixtures deleted." >&2
    exit 1
fi
unset PASSWORD
echo "Recorded $(ls "$OUT"/jellyfin-*.json | wc -l | tr -d ' ') fixtures into $OUT"
