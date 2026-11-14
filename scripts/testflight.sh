#!/bin/bash
# testflight.sh: build a commit, sign it for the App Store and upload it to TestFlight.
#
#   scripts/testflight.sh [ref] [--platform <p>|all] [--dry-run] [--no-wait]
#
#   ref         commit or ref to build (default: origin/main, fetched first). Built from
#               `git archive`, so uncommitted changes never end up in a build.
#   --platform  one of the platforms in SCHEMES below, or `all` (default: all, built in parallel)
#   --dry-run   archive, sign and export the .ipa (macOS: .pkg) locally, no upload
#   --no-wait   upload, but don't wait for App Store Connect processing
#
# Platforms run in parallel, each in its own DerivedData, so their App Store Connect processing
# waits overlap. Progress lines are prefixed `[testflight <platform>]`; the result lines come at
# the end, one per platform, OKs first, so the last line of output is always one of:
#   TESTFLIGHT OK platform=<p> build=<n> state=VALID id=<build id> commit=<sha> [external=<beta review state|error>]
#   TESTFLIGHT OK platform=<p> build=dry-run state=EXPORTED ipa=<path> commit=<sha>   (macos: pkg=<path>)
#   TESTFLIGHT FAIL platform=<p> code=<n> reason=<text> log=<dir>
# Exit codes: 0 ok · 1 unexpected · 2 usage · 3 signing (profile missing / expired / invalid,
# capability mismatch) · 4 archive (compile) · 5 export/upload · 6 processing INVALID ·
# 7 processing timeout · 8 source (ref, xcodegen, prepare, stock macOS VLCKit) · 9 already running · 10 credentials.
# A failing platform does not stop the others; the exit code is the one of the last line.
#
# Nothing secret or machine specific lives here. Credentials come from the environment or
# from an env file (ASC_ENV_FILE, default ~/.config/testflight/env):
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH   App Store Connect API key (.p8)
#   ASC_TEAM_ID                              team id, if the project doesn't set DEVELOPMENT_TEAM
#   SIGNING_KEYCHAIN                         optional keychain holding the "Apple Distribution" identity
#   SIGNING_KEYCHAIN_PASSWORD_FILE           optional, unlocks SIGNING_KEYCHAIN
# Signing is manual with an installed App Store provisioning profile per bundle id and platform
# (the newest matching one in ~/Library/Developer/Xcode/UserData/Provisioning Profiles or
# ~/Library/MobileDevice/Provisioning Profiles). Apple assigns the build number; versions in
# the repo are never touched.
# macOS additionally needs a Mac App Store profile (.provisionprofile, App Store Connect type
# MAC_APP_STORE), the "Apple Distribution" identity and a "3rd Party Mac Developer Installer"
# (Mac Installer Distribution) identity for the .pkg; it is archived with the hardened runtime
# on. A missing one fails that platform with code 3 naming the asset.
set -uo pipefail

# --- per-repo config ---------------------------------------------------------------------
PROJECT_SUBDIR=""          # directory with project.yml / the .xcodeproj, relative to the repo root
SCHEMES="ios:Dusk tvos:Dusk-tvOS macos:Dusk-macOS"  # space separated <platform>:<scheme>, platform ios, tvos or macos
EXTERNAL_GROUPS="External" # optional comma separated external TestFlight groups: a VALID build is added to them and
                           # submitted for Beta App Review (internal groups with "all builds" get it automatically)
                           # (external=PENDING_OTHER_BUILD_IN_REVIEW: an older build of the same version is still in
                           # beta review, Apple allows one per version; submit this one once that review is done)
export EXTERNAL_SKIP_VERSIONS=""  # space separated version globs kept internal-only (Marvin 2026-11-07: 1.8 goes external too)
# optional shell line run in the project dir before building ($REPO = checkout). VLCKit is not in git:
# reuse the checkout's copy, then the Xcode Cloud post-clone step verifies it (or downloads the pinned
# version) and makes sure the Metal toolchain is installed. Release builds must carry Dusk's VLCKit
# (TrueHD), so the stock-VLCKit fallback is an error here (needs gh access to marvinvr/dusk-vlckit).
# Build-time API keys (Trakt) are not in git either: the git-ignored Dusk/Support/Secrets.xcconfig is
# filtered to public client ID / redirect settings; never copy a legacy secret (docs/trakt.md).
PREPARE='mkdir -p Frameworks && cp -R "$REPO"/Frameworks/*.xcframework Frameworks/ 2>/dev/null; { awk '\''/^[[:space:]]*TRAKT_(CLIENT_ID|REDIRECT_URI)[[:space:]]*=/ { print }'\'' "$REPO"/Dusk/Support/Secrets.xcconfig > Dusk/Support/Secrets.xcconfig 2>/dev/null || echo "[testflight] WARNING: no Dusk/Support/Secrets.xcconfig, Trakt is hidden in this build" >&2; }; DUSK_VLCKIT_REQUIRE_DUSK=1 ci_scripts/ci_post_clone.sh'
# -------------------------------------------------------------------------------------------

REPO=$(cd "$(dirname "$0")" && git rev-parse --show-toplevel) || { echo "TESTFLIGHT FAIL code=8 reason=not in a git repo log=-"; exit 8; }
export REPO
REF=origin/main; DRY=0; WAIT=1; WANT=all; PLAT=-
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;; --no-wait) WAIT=0 ;;
    --platform) WANT="${2:-}"; shift ;; --platform=*) WANT="${1#*=}" ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    -*) echo "TESTFLIGHT FAIL platform=- code=2 reason=unknown option $1 log=-"; exit 2 ;;
    *) REF="$1" ;;
  esac
  shift
done

WORK=""; LOCK=""; RESULT=""  # RESULT: the platform's result file, set inside its background job
fail() {
  local line="TESTFLIGHT FAIL platform=$PLAT code=$1 reason=$2 log=${WORK:--}"
  if [ -n "$RESULT" ]; then echo "$line" >"$RESULT"; else echo "$line"; fi
  exit "$1"
}
ok() { echo "TESTFLIGHT OK platform=$PLAT $*" >"$RESULT"; }
say() { if [ "$PLAT" = - ]; then echo "[testflight] $*"; else echo "[testflight $PLAT] $*"; fi; }

SELECTED=""
for pair in $SCHEMES; do
  case "$WANT" in all|"${pair%%:*}") SELECTED="$SELECTED $pair" ;; esac
done
[ -n "$SELECTED" ] || fail 2 "unknown platform '$WANT' (have: all $(for p in $SCHEMES; do printf '%s ' "${p%%:*}"; done))"

# --- credentials ---
ENV_FILE=${ASC_ENV_FILE:-$HOME/.config/testflight/env}
if [ -f "$ENV_FILE" ]; then
  PERM=$(stat -f %Lp "$ENV_FILE"); [ "${PERM: -2}" = "00" ] || fail 10 "$ENV_FILE must be private (chmod 600)"
  set -a; . "$ENV_FILE"; set +a
fi
for v in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH; do [ -n "${!v:-}" ] || fail 10 "$v not set (env or $ENV_FILE)"; done
ASC_KEY_PATH="${ASC_KEY_PATH/#\~/$HOME}"; export ASC_KEY_PATH
[ -f "$ASC_KEY_PATH" ] || fail 10 "ASC_KEY_PATH does not exist"

# --- lock + work dir ---
NAME=$(basename "$REPO")
LOCK="${TMPDIR:-/tmp}/testflight-$NAME.lock"
mkdir "$LOCK" 2>/dev/null || fail 9 "another TestFlight build of $NAME is running (stale? remove $LOCK)"
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
WORK=$(mktemp -d "${TMPDIR:-/tmp}/testflight-$NAME-XXXXXX")
LOG="$WORK/build.log"

# --- source ---
git -C "$REPO" fetch -q origin >>"$LOG" 2>&1 || say "git fetch failed, building from local refs"
SHA=$(git -C "$REPO" rev-parse --verify -q "$REF^{commit}") || fail 8 "unknown ref $REF"
mkdir "$WORK/src"
git -C "$REPO" archive -o "$WORK/src.tar" "$SHA" >>"$LOG" 2>&1 && tar -x -f "$WORK/src.tar" -C "$WORK/src" >>"$LOG" 2>&1 || fail 8 "git archive failed (see build.log)"
rm -f "$WORK/src.tar"
PROJ="$WORK/src/$PROJECT_SUBDIR"
say "$NAME @ ${SHA:0:7} ($REF), platforms:$SELECTED, work dir $WORK"
cd "$PROJ" || fail 8 "project dir $PROJECT_SUBDIR missing"
if [ -n "$PREPARE" ]; then
  say "preparing ..."
  bash -c "$PREPARE" >>"$LOG" 2>&1 || fail 8 "prepare step failed (see build.log)"
fi
if [ -f project.yml ]; then
  command -v xcodegen >/dev/null || fail 8 "xcodegen not installed"
  xcodegen generate >>"$LOG" 2>&1 || fail 8 "xcodegen failed (see build.log)"
fi
XCPROJ=$(ls -d *.xcodeproj 2>/dev/null | head -1); [ -n "$XCPROJ" ] || fail 8 "no .xcodeproj"
# Once for all platforms: all targets (extensions are build dependencies, not scheme members);
# plan() keeps the platform's apps + extensions.
xcodebuild -project "$XCPROJ" -alltargets -configuration Release \
  -showBuildSettings -json >"$WORK/settings.json" 2>>"$LOG" || fail 8 "could not read build settings (see build.log)"

# --- the API + signing helper (python3 stdlib) ---
cat >"$WORK/tf.py" <<'PY'
import base64, fnmatch, glob, json, os, plistlib, re, subprocess, sys, time, urllib.parse, urllib.request

PLATFORMS = {"ios": ("iOS", "IOS", "iphoneos"), "tvos": ("tvOS", "TV_OS", "appletvos"),
             "macos": ("OSX", "MAC_OS", "macosx")}  # profile Platform, ASC platform, SDK
MAC_INSTALLER = ("3rd Party Mac Developer Installer", "Mac Installer Distribution")  # same certificate, old and new name

def b64(b): return base64.urlsafe_b64encode(b).rstrip(b"=").decode()

def jwt():
    now = int(time.time())
    h = b64(json.dumps({"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}).encode())
    p = b64(json.dumps({"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 1100, "aud": "appstoreconnect-v1"}).encode())
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", os.environ["ASC_KEY_PATH"]], input=f"{h}.{p}".encode(),
                         capture_output=True, check=True).stdout
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F); raw = b""
    for _ in range(2):
        n = der[i + 1]; raw += der[i + 2:i + 2 + n].lstrip(b"\x00").rjust(32, b"\x00"); i += 2 + n
    return f"{h}.{p}.{b64(raw)}"

def api(path):
    last = None
    for _ in range(3):
        try:
            req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, headers={"Authorization": "Bearer " + jwt()})
            with urllib.request.urlopen(req, timeout=60) as r: return json.load(r)
        except Exception as e:
            last = e
            if getattr(e, "code", 0) in (401, 403): break
            time.sleep(5)
    print(f"ASC API {path.split('?')[0]}: {last}"); sys.exit(10)

def call(method, path, body):
    req = urllib.request.Request("https://api.appstoreconnect.apple.com" + path, method=method, data=json.dumps(body).encode(),
                                 headers={"Authorization": "Bearer " + jwt(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r: return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try: err = json.load(e)["errors"][0]; msg = err.get("detail") or err.get("title")
        except Exception: msg = str(e)
        return {"error": f"{e.code} {msg}"}

def external(app_id, build_id, names):
    ver = api(f"/v1/builds/{build_id}/preReleaseVersion")["data"]["attributes"]["version"]
    if any(fnmatch.fnmatch(ver, g) for g in os.environ.get("EXTERNAL_SKIP_VERSIONS", "").split()):
        print(f"skipped-{ver}-internal-only"); return
    groups = {g["attributes"]["name"]: g["id"] for g in api(f"/v1/apps/{app_id}/betaGroups?limit=200")["data"]
              if not g["attributes"]["isInternalGroup"]}
    missing = [n for n in names.split(",") if n.strip() and n.strip() not in groups]
    if missing: print("error:no-group-" + "+".join(m.strip().replace(" ", "_") for m in missing)); return
    for n in names.split(","):
        if not n.strip(): continue
        for _ in range(10):  # right after VALID the build can still 404 here for a minute
            r = call("POST", f"/v1/betaGroups/{groups[n.strip()]}/relationships/builds", {"data": [{"type": "builds", "id": build_id}]})
            if not r.get("error", "").startswith("404"): break
            time.sleep(15)
        if "error" in r: print("error:add-group:" + r["error"].replace(" ", "_")[:120]); return
    r = call("POST", "/v1/betaAppReviewSubmissions",
             {"data": {"type": "betaAppReviewSubmissions", "relationships": {"build": {"data": {"type": "builds", "id": build_id}}}}})
    if "error" in r:  # already submitted / approved is fine, report the current state instead
        if "same train" in r["error"]:  # an older build of this version is still in Beta App Review: submit later
            print("PENDING_OTHER_BUILD_IN_REVIEW"); return
        d = api(f"/v1/builds/{build_id}/betaAppReviewSubmission").get("data")
        print(d["attributes"]["betaReviewState"] if d else "error:submit:" + r["error"].replace(" ", "_")[:120]); return
    print(r["data"]["attributes"]["betaReviewState"])

def out(code, msg): print(msg); sys.exit(code)

def expand(s, env):
    for _ in range(5): s = re.sub(r"\$\((\w+)\)|\$\{(\w+)\}", lambda m: env.get(m.group(1) or m.group(2), ""), s)
    return s

def profiles():
    found = []
    for d in ("~/Library/Developer/Xcode/UserData/Provisioning Profiles", "~/Library/MobileDevice/Provisioning Profiles"):
        for f in glob.glob(os.path.join(os.path.expanduser(d), "*.mobileprovision")) + \
                 glob.glob(os.path.join(os.path.expanduser(d), "*.provisionprofile")):  # macOS profiles
            p = subprocess.run(["security", "cms", "-D", "-i", f], capture_output=True)
            try: found.append(plistlib.loads(p.stdout))
            except Exception: pass
    return found

def plan(settings_json, out_dir, platform):
    pplat = PLATFORMS[platform][0]
    targets = [(t["target"], t["buildSettings"]) for t in {t["target"]: t for t in json.load(open(settings_json))}.values()
               if t["buildSettings"].get("WRAPPER_EXTENSION") in ("app", "appex") and t["buildSettings"].get("PRODUCT_BUNDLE_IDENTIFIER")
               and t["buildSettings"].get("PLATFORM_NAME", t["buildSettings"].get("SDKROOT", "")).startswith(PLATFORMS[platform][2])]
    if not targets: out(8, "no app targets in scheme")
    team = targets[0][1].get("DEVELOPMENT_TEAM") or os.environ.get("ASC_TEAM_ID", "")
    if not team: out(3, "no team: set DEVELOPMENT_TEAM in the project or ASC_TEAM_ID")
    mac = platform == "macos"
    if mac: check_mac_identities(team)
    # Mac App Store profiles carry no beta-reports-active; a Developer ID profile (also device-less)
    # is told apart by its App Store Connect profile type below.
    profs = [p for p in profiles() if (mac or p.get("Entitlements", {}).get("beta-reports-active")) and not p.get("ProvisionedDevices")
             and not p.get("ProvisionsAllDevices") and team in p.get("TeamIdentifier", []) and pplat in p.get("Platform", [])]
    lines, mapping, app_bundle = [], {}, None
    for name, s in targets:
        bundle = s["PRODUCT_BUNDLE_IDENTIFIER"]
        if s.get("WRAPPER_EXTENSION") == "app": app_bundle = bundle
        cand = [p for p in profs if (p["Entitlements"].get("application-identifier")
                                     or p["Entitlements"].get("com.apple.application-identifier")) == f"{team}.{bundle}"
                and p["ExpirationDate"].timestamp() > time.time() + 3600]
        kind = "Mac App Store" if mac else "App Store"
        if not cand: out(3, f"profile missing for {bundle} ({pplat}): no valid {kind} provisioning profile installed")
        p, st = None, None
        for c in sorted(cand, key=lambda x: x["CreationDate"], reverse=True):
            d = api("/v1/profiles?filter[name]=" + urllib.parse.quote(c["Name"]) + "&fields[profiles]=profileState,profileType,uuid")["data"]
            hit = next((x["attributes"] for x in d if x["attributes"]["uuid"] == c["UUID"]), None)
            if mac and hit and hit.get("profileType") != "MAC_APP_STORE": continue  # Developer ID / development
            p, st = c, hit and hit["profileState"]
            break
        if not p: out(3, f"profile missing for {bundle} ({pplat}): no Mac App Store provisioning profile installed (only other types)")
        if st != "ACTIVE": out(3, f"profile '{p['Name']}' for {bundle} is {st or 'unknown to App Store Connect'} (capabilities changed? regenerate it)")
        ent_path = expand(s.get("CODE_SIGN_ENTITLEMENTS", ""), s)
        if ent_path:
            full = ent_path if os.path.isabs(ent_path) else os.path.join(s.get("PROJECT_DIR", "."), ent_path)
            want, have = plistlib.load(open(full, "rb")), p["Entitlements"]
            # App Sandbox and hardened-runtime keys are not provisioned (never in a profile); app groups are checked below.
            miss = [k for k in want if k not in have and not (mac and k.startswith("com.apple.security."))]
            if miss: out(3, f"capability mismatch for {bundle}: profile '{p['Name']}' lacks {', '.join(miss)}")
            for key in ("com.apple.security.application-groups", "com.apple.developer.associated-domains"):
                vals = [expand(v, s) for v in want.get(key, []) if isinstance(v, str)]
                lack = [v for v in vals if v and v not in have.get(key, []) and "*" not in have.get(key, [])]
                if lack: out(3, f"capability mismatch for {bundle}: {key.split('.')[-1]} {', '.join(lack)} not in profile '{p['Name']}'")
        lines.append("TF_PROFILE_" + re.sub(r"[^A-Za-z0-9]", "_", bundle) + f" = {p['Name']}")
        mapping[bundle] = p["Name"]
    lines += ["CODE_SIGN_STYLE = Manual", "CODE_SIGN_IDENTITY = Apple Distribution", f"DEVELOPMENT_TEAM = {team}",
              "PROVISIONING_PROFILE_SPECIFIER = $(TF_PROFILE_$(PRODUCT_BUNDLE_IDENTIFIER:c99extidentifier))"]
    if mac: lines.append("ENABLE_HARDENED_RUNTIME = YES")  # local ad-hoc builds keep it off (no Team ID for library validation)
    open(os.path.join(out_dir, "signing.xcconfig"), "w").write("\n".join(lines) + "\n")
    export = {"method": "app-store-connect", "destination": "upload", "teamID": team, "signingStyle": "manual",
              "signingCertificate": "Apple Distribution", "provisioningProfiles": mapping, "uploadSymbols": True,
              "manageAppVersionAndBuildNumber": True}
    if mac: export["installerSigningCertificate"] = MAC_INSTALLER[0]
    plistlib.dump(export, open(os.path.join(out_dir, "ExportOptions.plist"), "wb"))
    apps = api("/v1/apps?filter[bundleId]=" + urllib.parse.quote(app_bundle) + "&fields[apps]=bundleId")["data"]
    app_id = next((a["id"] for a in apps if a["attributes"]["bundleId"] == app_bundle), None)
    if not app_id: out(3, f"no App Store Connect app for {app_bundle}")
    open(os.path.join(out_dir, "app_id"), "w").write(app_id)
    print(f"{pplat}: {len(mapping)} bundle(s) with active App Store profiles: " + ", ".join(f"{b} ({n})" for b, n in mapping.items()))

def identities(policy):
    cmd = ["security", "find-identity", "-v", "-p", policy]
    kc = os.environ.get("SIGNING_KEYCHAIN", "")
    if kc: cmd.append(os.path.expanduser(kc))
    return subprocess.run(cmd, capture_output=True, text=True).stdout

def check_mac_identities(team):
    if not re.search(rf'"Apple Distribution: [^"]*\({team}\)"', identities("codesigning")):
        out(3, f"signing identity missing: Apple Distribution certificate for team {team} not in the keychain")
    if not re.search(rf'"(?:{"|".join(MAC_INSTALLER)}): [^"]*\({team}\)"', identities("basic")):
        out(3, f"installer identity missing: 3rd Party Mac Developer Installer (Mac Installer Distribution) certificate for team {team} not in the keychain")

def latest(app_id, platform):
    d = api(f"/v1/builds?filter[app]={app_id}&filter[preReleaseVersion.platform]={PLATFORMS[platform][1]}"
            "&sort=-uploadedDate&limit=1&fields[builds]=version,processingState")["data"]
    print(f"{d[0]['id']} {d[0]['attributes']['version']} {d[0]['attributes']['processingState']}" if d else "- - -")

if __name__ == "__main__":
    if sys.argv[1] == "plan": plan(*sys.argv[2:5])
    elif sys.argv[1] == "latest": latest(*sys.argv[2:4])
    elif sys.argv[1] == "external": external(*sys.argv[2:5])
PY
TF="python3 -I $WORK/tf.py"

errors() { grep -E 'error:|error -|Error Domain|failed' "$1" | grep -v -i warning | awk '!seen[$0]++' | head -4 | tr '\n' ' ' | cut -c1-500; }
is_signing() { grep -qiE 'provisioning profile|signing certificate|entitlement|code ?sign|no profiles? for' <<<"$1"; }

# Unlocked once, before the platforms fork; it stays unlocked for 2 h of inactivity.
if [ -n "${SIGNING_KEYCHAIN:-}" ]; then
  KC="${SIGNING_KEYCHAIN/#\~/$HOME}"
  if [ -n "${SIGNING_KEYCHAIN_PASSWORD_FILE:-}" ]; then
    security unlock-keychain -p "$(cat "${SIGNING_KEYCHAIN_PASSWORD_FILE/#\~/$HOME}")" "$KC" || fail 3 "could not unlock $KC"
  fi
  security set-keychain-settings -t 7200 -l "$KC" 2>/dev/null
fi

build_one() {  # <platform> <scheme>, run as a background job with RESULT set
  PLAT=$1; local scheme=$2 dir="$WORK/$1" dest
  case "$PLAT" in
    ios) dest='generic/platform=iOS' ;; tvos) dest='generic/platform=tvOS' ;; macos) dest='generic/platform=macOS' ;;
    *) fail 2 "unknown platform $PLAT" ;;
  esac
  mkdir -p "$dir"

  if [ "$PLAT" = macos ]; then
    # Like iOS/tvOS (DUSK_VLCKIT_REQUIRE_DUSK in PREPARE), the Mac ships Dusk's own VLCKit (TrueHD). It
    # is checked here, not in PREPARE, so a stock fallback fails only this platform. Install it in the
    # checkout first: DUSK_VLCKIT_CACHE_DIR=<dir with VLCKit-<version>.tar.xz> ci_scripts/install_vlckit.sh
    local vlc; vlc=$(/usr/libexec/PlistBuddy -c "Print :DuskVLCKitBuild" \
      Frameworks/VLCKit.xcframework/macos-arm64_x86_64/VLCKit.framework/Resources/Info.plist 2>/dev/null)
    [ -n "$vlc" ] || [ "${DUSK_MACOS_ALLOW_STOCK_VLCKIT:-0}" = 1 ] ||
      fail 8 "macOS VLCKit is VideoLAN's stock build, not Dusk's (no TrueHD); install Dusk's (see docs/macos.md) or set DUSK_MACOS_ALLOW_STOCK_VLCKIT=1"
  fi

  say "checking signing ..."
  local msg rc
  msg=$($TF plan "$WORK/settings.json" "$dir" "$PLAT" 2>&1); rc=$?
  [ $rc -eq 0 ] || fail "$rc" "$msg"
  say "$msg"
  local app_id; app_id=$(cat "$dir/app_id")

  say "archiving $scheme ..."
  xcodebuild -project "$XCPROJ" -scheme "$scheme" -configuration Release -destination "$dest" \
    -archivePath "$dir/App.xcarchive" -derivedDataPath "$dir/DerivedData" -xcconfig "$dir/signing.xcconfig" \
    archive >"$dir/archive.log" 2>&1 || {
    local e; e=$(errors "$dir/archive.log"); is_signing "$e" && fail 3 "archive signing failed: $e"; fail 4 "archive failed: $e"; }

  local prev; prev=$($TF latest "$app_id" "$PLAT" | cut -d' ' -f1)
  [ $DRY -eq 1 ] && plutil -replace destination -string export "$dir/ExportOptions.plist"
  say "$([ $DRY -eq 1 ] && echo 'exporting (dry run, no upload)' || echo 'exporting + uploading') ..."
  xcodebuild -exportArchive -archivePath "$dir/App.xcarchive" -exportOptionsPlist "$dir/ExportOptions.plist" \
    -exportPath "$dir/export" -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" >"$dir/export.log" 2>&1 || {
    local e; e=$(errors "$dir/export.log"); is_signing "$e" && fail 3 "export signing failed: $e"; fail 5 "export/upload failed: $e"; }

  if [ $DRY -eq 1 ]; then
    if [ "$PLAT" = macos ]; then ok "build=dry-run state=EXPORTED pkg=$(ls "$dir"/export/*.pkg 2>/dev/null | head -1) commit=${SHA:0:7}"
    else ok "build=dry-run state=EXPORTED ipa=$(ls "$dir"/export/*.ipa 2>/dev/null | head -1) commit=${SHA:0:7}"; fi
    return
  fi
  if [ $WAIT -eq 0 ]; then ok "build=? state=UPLOADED id=? commit=${SHA:0:7}"; return; fi

  say "uploaded, waiting for App Store Connect processing ..."
  local id num state
  for _ in $(seq 1 135); do
    sleep 20
    read -r id num state <<<"$($TF latest "$app_id" "$PLAT")"
    if [ "$id" != "$prev" ] && [ "$id" != "-" ]; then
      case "$state" in
        VALID)
          local ext=""
          if [ -n "$EXTERNAL_GROUPS" ]; then
            say "build $num VALID, adding to external groups ($EXTERNAL_GROUPS) + Beta App Review ..."
            ext=" external=$($TF external "$app_id" "$id" "$EXTERNAL_GROUPS" 2>&1 | tail -1 | tr ' ' '_')"
          fi
          ok "build=$num state=VALID id=$id commit=${SHA:0:7}$ext"; return ;;
        INVALID|FAILED) fail 6 "build $num is $state (App Store Connect mails the details)" ;;
      esac
    fi
  done
  fail 7 "processing not finished after 45 min (last: build ${num:-?} ${state:-?})"
}

# Background jobs ignore SIGINT, so Ctrl-C / a stop has to take their xcodebuilds down explicitly.
kill_tree() { local c; for c in $(pgrep -P "$1"); do kill_tree "$c"; done; kill "$1" 2>/dev/null; }
trap 'for j in $(jobs -p); do kill_tree "$j"; done; echo "TESTFLIGHT FAIL platform=- code=1 reason=interrupted log=$WORK"; exit 1' INT TERM
for pair in $SELECTED; do
  ( RESULT="$WORK/${pair%%:*}.result"; build_one "${pair%%:*}" "${pair#*:}" ) &
done
wait

OKS=""; FAILS=""; CODE=0
for pair in $SELECTED; do
  p=${pair%%:*}
  line=$(cat "$WORK/$p.result" 2>/dev/null) || line="TESTFLIGHT FAIL platform=$p code=1 reason=no result (job died) log=$WORK"
  case "$line" in
    "TESTFLIGHT OK "*) OKS="$OKS$line"$'\n' ;;
    *) FAILS="$FAILS$line"$'\n'; CODE=${line#*code=}; CODE=${CODE%% *} ;;
  esac
done
printf '%s' "$OKS$FAILS"
[ "$CODE" -eq 0 ] && rm -rf "${WORK:?}"/*/DerivedData "${WORK:?}/src"   # keeps archives, logs and (dry run) the .ipa
exit "$CODE"
