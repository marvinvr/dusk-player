#!/usr/bin/env python3
"""Apply the T-0 server-side test data to plex-demo and jellyfin-demo.

    python3 scripts/demo-testdata/apply.py <step> [<step> ...]
    python3 scripts/demo-testdata/apply.py verify-<step>

There is no "all": several steps wait for asynchronous server work (scans,
analysis), and plex-analysis must be followed by plex-analysis-restore. See
README.md for the order. Every step looks up what exists and only adds what
is missing. Items are matched across the two servers by their /data/... path.
Media files must already be on the share (make_media.py).
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import demo_api as api  # noqa: E402

D = "/data"
MOVIES = f"{D}/Movies"
REAL_M = f"{D}/Real/Movies"
REAL_TV = f"{D}/Real/TV"


def movie(folder, file=None):
    return f"{MOVIES}/{folder}/{file or folder}"


BBB = movie("Big Buck Bunny (2008)", "Big Buck Bunny (2008).mp4")
COSMOS = movie("Cosmos Laundromat (2015)", "Cosmos Laundromat (2015).mp4")
ELEPHANTS = movie("Elephants Dream (2006)", "Elephants Dream (2006).mp4")
SINTEL = movie("Sintel (2010)", "Sintel (2010).mkv")
TEARS = movie("Tears of Steel (2012)", "Tears of Steel (2012).mov")
WEEKEND = f"{D}/Shorts/Weekend Projects"
KNIVES = f"{REAL_M}/Knives Out (2019)/Knives Out (2019) - 1080p.mkv"
PADDINGTON = f"{REAL_M}/Paddington 2 (2017)/Paddington 2 (2017) - 1080p.mkv"
DUNE = f"{REAL_M}/Dune Part Two (2024)/Dune Part Two (2024) - 4k.mkv"

COLLECTIONS = {
    # one collection inside Movies
    "Blender Open Movies": [BBB, COSMOS, ELEPHANTS, SINTEL, TEARS],
    # one collection spanning a movie library and a TV library (Movies + Shorts).
    # Plex collections are per library section, so plex-demo gets one
    # same-named collection in each section.
    "Weekend Watch": [BBB, SINTEL, WEEKEND],
}


def log(*a):
    print(*a, flush=True)


# ----------------------------------------------------------- path mapping
class PlexIndex:
    """/data path -> (section key, ratingKey, type) for the whole server."""

    def __init__(self, plex):
        self.plex = plex
        self.by_path = {}
        for d in plex.mc("/library/sections").get("Directory", []):
            if d["type"] not in ("movie", "show"):
                continue
            for it in plex.items(d["key"]):
                if d["type"] == "movie":
                    for m in it.get("Media", []):
                        for p in m.get("Part", []):
                            self.by_path[p["file"]] = (d["key"], it["ratingKey"], 1)
                else:
                    meta = plex.mc(f"/library/metadata/{it['ratingKey']}")["Metadata"][0]
                    for loc in meta.get("Location", []):
                        self.by_path[loc["path"]] = (d["key"], it["ratingKey"], 2)
                    for ep in plex.mc(f"/library/metadata/{it['ratingKey']}/allLeaves").get("Metadata", []):
                        for m in ep.get("Media", []):
                            for p in m.get("Part", []):
                                self.by_path[p["file"]] = (d["key"], ep["ratingKey"], 4)

    def __getitem__(self, path):
        if path not in self.by_path:
            raise RuntimeError(f"plex-demo has no item at {path}")
        return self.by_path[path]


class JFIndex:
    def __init__(self, jf):
        self.by_path = {}
        for it in jf.items(includeItemTypes="Movie,Episode,Series,Video"):
            if it.get("Path"):
                self.by_path[it["Path"]] = it

    def __getitem__(self, path):
        if path not in self.by_path:
            raise RuntimeError(f"jellyfin-demo has no item at {path}")
        return self.by_path[path]


# ------------------------------------------------------------ collections
def step_collections():
    plex, jf = api.plex_owner(), api.jf_admin()
    pidx, jidx = PlexIndex(plex), JFIndex(jf)
    for title, paths in COLLECTIONS.items():
        # Plex: one collection per section
        per_section = {}
        for p in paths:
            sec, rk, typ = pidx[p]
            per_section.setdefault((sec, typ), []).append(rk)
        for (sec, typ), rks in per_section.items():
            existing = [c for c in plex.mc(f"/library/sections/{sec}/collections").get("Metadata", [])
                        if c["title"] == title]
            if existing:
                crk = existing[0]["ratingKey"]
                have = {c["ratingKey"] for c in plex.mc(f"/library/collections/{crk}/children").get("Metadata", [])}
                missing = [k for k in rks if k not in have]
                if missing:
                    plex.req("PUT", f"/library/collections/{crk}/items", {"uri": plex.uri(missing)})
                log(f"plex: collection '{title}' in section {sec} exists (+{len(missing)})")
            else:
                plex.req("POST", "/library/collections", {
                    "type": typ, "title": title, "smart": 0, "sectionId": sec, "uri": plex.uri(rks)})
                log(f"plex: created collection '{title}' in section {sec}")
        # Jellyfin: one BoxSet spanning libraries, created by the admin
        ids = [jidx[p]["Id"] for p in paths]
        existing = [b for b in jf.items(includeItemTypes="BoxSet") if b["Name"] == title]
        if existing:
            bid = existing[0]["Id"]
            have = {i["Id"] for i in jf.items(parentId=bid, recursive="false")}
            missing = [i for i in ids if i not in have]
            if missing:
                jf.post(f"/Collections/{bid}/Items", ids=",".join(missing))
            log(f"jellyfin: collection '{title}' exists (+{len(missing)})")
        else:
            jf.post("/Collections", name=title, ids=",".join(ids))
            log(f"jellyfin: created collection '{title}'")


def verify_collections():
    plex, jf = api.plex_owner(), api.jf_admin()
    for title, paths in COLLECTIONS.items():
        n_plex = 0
        for d in plex.mc("/library/sections").get("Directory", []):
            for c in plex.mc(f"/library/sections/{d['key']}/collections").get("Metadata", []):
                if c["title"] == title:
                    n_plex += int(c.get("childCount", 0))
        box = [b for b in jf.items(includeItemTypes="BoxSet") if b["Name"] == title]
        n_jf = len(jf.items(parentId=box[0]["Id"], recursive="false")) if box else 0
        log(f"verify collection '{title}': expected {len(paths)}, plex {n_plex}, jellyfin {n_jf}")


# ------------------------------------------------------------------ media
NEW_FOLDERS = [
    f"{MOVIES}/Dusk Two Versions (2026)",
    f"{MOVIES}/Dusk Two Parts (2026)",
    f"{MOVIES}/Dusk Subtitles ASS (2026)",
    f"{MOVIES}/Dusk Subtitles VobSub Forced (2026)",
    f"{MOVIES}/Big Buck Bunny (2008)",
    WEEKEND,
    f"{D}/Photos/Metadata Test",
]
VERSIONS = movie("Dusk Two Versions (2026)", "Dusk Two Versions (2026) - 1080p.mkv")
VERSIONS_4K = movie("Dusk Two Versions (2026)", "Dusk Two Versions (2026) - 2160p.mkv")
PARTS = movie("Dusk Two Parts (2026)", "Dusk Two Parts (2026) - cd1.mkv")
SUB_ASS = movie("Dusk Subtitles ASS (2026)", "Dusk Subtitles ASS (2026).mkv")
SUB_VOB = movie("Dusk Subtitles VobSub Forced (2026)", "Dusk Subtitles VobSub Forced (2026).mkv")
WEEKEND_E1 = f"{WEEKEND}/Season 01/Weekend Projects - S01E01 - Building the Treehouse.mp4"


def plex_section_for(plex, path):
    for d in plex.mc("/library/sections").get("Directory", []):
        for loc in d.get("Location", []):
            if path == loc["path"] or path.startswith(loc["path"] + "/"):
                return d["key"]
    raise RuntimeError(f"no plex section holds {path}")


def scan(paths):
    plex, jf = api.plex_owner(), api.jf_admin()
    for p in paths:
        plex.req("GET", f"/library/sections/{plex_section_for(plex, p)}/refresh", {"path": p})
    jf.post("/Library/Media/Updated", {"Updates": [{"Path": p, "UpdateType": "Created"} for p in paths]})
    log(f"scan requested for {len(paths)} folders on both servers")


def step_media():
    scan(NEW_FOLDERS)


def step_merge_versions():
    """Plex does not group local (unmatched) files into versions by name: merge them."""
    plex = api.plex_owner()
    pidx = PlexIndex(plex)
    a, b = pidx[VERSIONS][1], pidx[VERSIONS_4K][1]
    if a != b:
        plex.req("PUT", f"/library/metadata/{a}/merge", {"ids": b})
        log(f"plex: merged {b} into {a}")
    else:
        log("plex: versions already one item")


def plex_meta(plex, rk):
    return plex.mc(f"/library/metadata/{rk}")["Metadata"][0]


def _plex_subs(meta):
    out = []
    for s in meta["Media"][0]["Part"][0].get("Stream", []):
        if s["streamType"] == 3:
            out.append(f"{s.get('codec')}/{s.get('languageCode', '-')}"
                       f"{'/forced' if s.get('forced') else ''}{'/ext' if s.get('key') else ''}")
    return sorted(out)


def _jf_subs(src):
    return sorted(f"{s.get('Codec')}/{s.get('Language', '-')}{'/forced' if s.get('IsForced') else ''}"
                  f"{'/ext' if s.get('IsExternal') else ''}"
                  for s in src["MediaStreams"] if s["Type"] == "Subtitle")


def verify_media():
    plex, jf = api.plex_owner(), api.jf_admin()
    pidx, jidx = PlexIndex(plex), JFIndex(jf)

    def jfull(path):
        return jf.get(f"/Items/{jidx[path]['Id']}", userId=jf.user_id)

    # versions
    pm = plex_meta(plex, pidx[VERSIONS][1])
    jv = jfull(VERSIONS_4K)
    log(f"verify versions: plex media={[m.get('videoResolution') for m in pm['Media']]} "
        f"(same item for both files: {pidx[VERSIONS][1] == pidx[VERSIONS_4K][1]}), "
        f"jellyfin sources={[s['Name'] for s in jv['MediaSources']]}")
    # multipart
    pm = plex_meta(plex, pidx[PARTS][1])
    jp = jfull(PARTS)
    extra = jf.get(f"/Videos/{jp['Id']}/AdditionalParts", userId=jf.user_id)["Items"]
    log(f"verify multipart: plex parts={len(pm['Media'][0]['Part'])}, "
        f"jellyfin PartCount={jp.get('PartCount')} additional={len(extra)}")
    # subtitles
    for path in (SUB_ASS, SUB_VOB):
        pm = plex_meta(plex, pidx[path][1])
        jm = jfull(path)
        att = [a.get("FileName") for a in jm["MediaSources"][0].get("MediaAttachments", [])]
        log(f"verify subs {Path(path).stem}:\n  plex     {_plex_subs(pm)}\n"
            f"  jellyfin {_jf_subs(jm['MediaSources'][0])} attachments={att}")
    # extras
    bbb = pidx[BBB][1]
    pe = [f"{e.get('subtype') or e.get('extraType')}:{e['title']}" for e in
          plex.mc(f"/library/metadata/{bbb}/extras").get("Metadata", [])]
    jb = jidx[BBB]["Id"]
    je = [f"{e.get('ExtraType')}:{e['Name']}" for e in jf.get(f"/Items/{jb}/SpecialFeatures", userId=jf.user_id)]
    jt = [t["Name"] for t in jf.get(f"/Items/{jb}/LocalTrailers", userId=jf.user_id)]
    log(f"verify extras movie BBB:\n  plex     {sorted(pe)}\n  jellyfin {sorted(je)} trailers={jt}")
    show_rk = pidx[WEEKEND][1]
    season_rk = next(s["ratingKey"] for s in plex.mc(f"/library/metadata/{show_rk}/children")["Metadata"]
                     if s.get("index") == 1)
    js = jidx[WEEKEND]["Id"]
    jseason = next(s["Id"] for s in jf.get(f"/Shows/{js}/Seasons", userId=jf.user_id)["Items"]
                   if s.get("IndexNumber") == 1)
    for label, prk, jid in (("show", show_rk, js), ("season 1", season_rk, jseason),
                            ("episode 1", pidx[WEEKEND_E1][1], jidx[WEEKEND_E1]["Id"])):
        pe = [e["title"] for e in plex.mc(f"/library/metadata/{prk}/extras").get("Metadata", [])]
        je = [f"{e.get('ExtraType')}:{e['Name']}" for e in jf.get(f"/Items/{jid}/SpecialFeatures", userId=jf.user_id)]
        jt = [t["Name"] for t in jf.get(f"/Items/{jid}/LocalTrailers", userId=jf.user_id)]
        log(f"verify extras {label}: plex {pe} | jellyfin {je} trailers={jt}")
    eps = plex.mc(f"/library/metadata/{season_rk}/children")["Metadata"]
    log(f"  plex season 1 episodes: {[(e['index'], len(e['Media'])) for e in eps]} (index, versions)")
    jeps = jf.get("/Shows/{}/Episodes".format(js), userId=jf.user_id, seasonId=jseason)["Items"]
    log(f"  jellyfin season 1 episodes: {[e.get('IndexNumber') for e in jeps]}")
    # unmatched
    bad = [p for p in (VERSIONS, PARTS, SUB_ASS, SUB_VOB) if not plex_meta(plex, pidx[p][1])["guid"].startswith("local://")]
    bad += [p for p in (VERSIONS_4K, PARTS, SUB_ASS, SUB_VOB) if jidx[p].get("ProviderIds")]
    log(f"verify unmatched (local only): {'ok' if not bad else bad}")
    verify_photos(plex, jf)


def verify_photos(plex, jf):
    sec = plex.section("Photos")["key"]
    album = next(a for a in plex.mc(f"/library/sections/{sec}/all").get("Metadata", []) if a["title"] == "Metadata Test")
    pp = {m["title"]: (m.get("originallyAvailableAt"), m["Media"][0]["Part"][0].get("orientation"))
          for m in plex.mc(f"/library/metadata/{album['ratingKey']}/children").get("Metadata", [])}
    jalbum = next(a for a in jf.items(includeItemTypes="PhotoAlbum") if a["Name"] == "Metadata Test")
    jp = {i["Name"]: (i.get("PremiereDate", "")[:10], i.get("Type"))
          for i in jf.items(parentId=jalbum["Id"], recursive="false", fields="Path")}
    log(f"verify photos: plex {len(pp)} items, jellyfin {len(jp)} items (generated 9)")
    for name in sorted(set(pp) | set(jp)):
        log(f"  {name}: plex {pp.get(name)} | jellyfin {jp.get(name)}")


# --------------------------------------------------------------- playlists
OFFICE_S1E1 = f"{REAL_TV}/The Office (US)/Season 1/The Office (US) - S01E01 - Pilot Bluray-1080p Remux.mkv"
SHORT_PLAYLIST = ("T-0 Short Mix", [BBB, SINTEL, TEARS, OFFICE_S1E1, KNIVES])
LONG_PLAYLIST_SHOWS = ["The Office (US)", "Severance", "Ted Lasso"]  # > 200 entries (Dusk page size)


def long_playlist_paths(pidx):
    out = []
    for show in LONG_PLAYLIST_SHOWS:
        pre = f"{REAL_TV}/{show}/"
        out += sorted(p for p, v in pidx.by_path.items() if p.startswith(pre) and v[2] == 4)
    return out


def plex_compare():
    return api.Plex(api.plex_user_server_token("compare-plex-token"))


def step_playlists():
    owner = api.plex_owner()
    pidx = PlexIndex(owner)
    plex = plex_compare()
    jf = api.jf_compare()
    jidx = JFIndex(jf)
    lists = [SHORT_PLAYLIST, ("T-0 Long Watch", long_playlist_paths(pidx))]
    for title, paths in lists:
        rks = [pidx[p][1] for p in paths]
        have = [p for p in plex.mc("/playlists", playlistType="video").get("Metadata", []) if p["title"] == title]
        if not have:
            plex.req("POST", "/playlists", {"type": "video", "title": title, "smart": 0,
                                            "uri": owner.uri(rks)})
            log(f"plex: created playlist '{title}' ({len(rks)}) for duskcompare")
        else:
            prk = have[0]["ratingKey"]
            cur = [i["ratingKey"] for i in plex.mc(f"/playlists/{prk}/items").get("Metadata", [])]
            missing = [k for k in rks if k not in cur]
            if missing:  # appended in order; entries are never removed or reordered
                plex.req("PUT", f"/playlists/{prk}/items", {"uri": owner.uri(missing)})
            log(f"plex: playlist '{title}' exists (+{len(missing)})")
        ids = [jidx[p]["Id"] for p in paths]
        jhave = [p for p in jf.items(includeItemTypes="Playlist") if p["Name"] == title]
        if not jhave:
            jf.post("/Playlists", {"Name": title, "Ids": ids, "UserId": jf.user_id,
                                   "MediaType": "Video", "IsPublic": False})
            log(f"jellyfin: created playlist '{title}' ({len(ids)}) for duskcompare")
        else:
            jid = jhave[0]["Id"]
            cur = {i["Id"] for i in jf.get(f"/Playlists/{jid}/Items", userId=jf.user_id)["Items"]}
            missing = [i for i in ids if i not in cur]
            if missing:
                jf.post(f"/Playlists/{jid}/Items", ids=",".join(missing), userId=jf.user_id)
            log(f"jellyfin: playlist '{title}' exists (+{len(missing)})")


def verify_playlists():
    owner = api.plex_owner()
    pidx = PlexIndex(owner)
    plex, jf = plex_compare(), api.jf_compare()
    for title, paths in [SHORT_PLAYLIST, ("T-0 Long Watch", long_playlist_paths(pidx))]:
        pl = [p for p in plex.mc("/playlists", playlistType="video").get("Metadata", []) if p["title"] == title]
        pfiles = []
        if pl:
            for it in plex.mc(f"/playlists/{pl[0]['ratingKey']}/items").get("Metadata", []):
                pfiles.append(it["Media"][0]["Part"][0]["file"])
        jl = [p for p in jf.items(includeItemTypes="Playlist") if p["Name"] == title]
        jfiles, public = [], None
        if jl:
            jfiles = [i.get("Path") for i in jf.get(f"/Playlists/{jl[0]['Id']}/Items", userId=jf.user_id,
                                                     fields="Path")["Items"]]
            public = jf.get(f"/Playlists/{jl[0]['Id']}").get("OpenAccess")
        log(f"verify playlist '{title}': expected {len(paths)}, plex {len(pfiles)} "
            f"(order ok: {pfiles == paths}), jellyfin {len(jfiles)} (order ok: {jfiles == paths}, "
            f"OpenAccess={public})")


# ------------------------------------------------------------- watch state
SEVERANCE_S1 = f"{REAL_TV}/Severance/Season 1"
RESUME_FILMS = [DUNE, PADDINGTON]  # set before T-0 on both servers; Dune is past 5 %


def severance_first_three(pidx):
    eps = sorted(p for p in pidx.by_path if p.startswith(SEVERANCE_S1 + "/"))
    assert len(eps) >= 4, eps
    return eps[:3]


def step_watch_state():
    pidx = PlexIndex(api.plex_owner())
    plex, jf = plex_compare(), api.jf_compare()
    jidx = JFIndex(jf)
    for p in severance_first_three(pidx):
        if not plex_meta(plex, pidx[p][1]).get("viewCount"):
            plex.req("GET", "/:/scrobble", {"key": pidx[p][1], "identifier": "com.plexapp.plugins.library"})
            log(f"plex: watched {Path(p).name}")
        jd = jf.get(f"/Items/{jidx[p]['Id']}", userId=jf.user_id)["UserData"]
        if not jd.get("Played"):
            jf.post(f"/UserPlayedItems/{jidx[p]['Id']}", userId=jf.user_id)
            log(f"jellyfin: watched {Path(p).name}")
    # keep the resume points equal: copy the Plex position to Jellyfin when they differ
    for p in RESUME_FILMS:
        off = plex_meta(plex, pidx[p][1]).get("viewOffset")
        jd = jidx[p].get("UserData") or jf.get(f"/Items/{jidx[p]['Id']}", userId=jf.user_id)["UserData"]
        if off and abs(jd.get("PlaybackPositionTicks", 0) // 10000 - off) > 1000:
            jf.post(f"/UserItems/{jidx[p]['Id']}/UserData", {"PlaybackPositionTicks": off * 10000},
                    userId=jf.user_id)
            log(f"jellyfin resume of {Path(p).name} set to {off} ms")


def verify_watch_state():
    pidx = PlexIndex(api.plex_owner())
    plex, jf = plex_compare(), api.jf_compare()
    deck = [f"{m.get('grandparentTitle', '')} {m['title']}".strip()
            for m in plex.mc("/library/onDeck").get("Metadata", [])]
    cw = [(m.get("grandparentTitle") or m["title"], m.get("viewOffset")) for m in
          (plex.mc("/hubs/continueWatching").get("Hub") or [{}])[0].get("Metadata", [])]
    nu = [f"{i.get('SeriesName')} {i['Name']}" for i in jf.get("/Shows/NextUp", userId=jf.user_id)["Items"]]
    res = [(i["Name"], i["UserData"]["PlaybackPositionTicks"] // 10000)
           for i in jf.get("/UserItems/Resume", userId=jf.user_id, mediaTypes="Video")["Items"]]
    log(f"verify state plex: onDeck={deck}\n  continueWatching={cw}")
    log(f"verify state jellyfin: nextUp={nu}\n  resume={res}")
    for p in severance_first_three(pidx):
        log(f"  {Path(p).name[:40]}: plex viewCount={plex_meta(plex, pidx[p][1]).get('viewCount')}")


# ----------------------------------------------------------- jellyfin users
DEMO_LIBRARIES = ["Movies", "Shorts", "Photos", "Home Videos"]  # what tester sees
JF_USERS = [
    # name, password file (None = no password), policy overrides
    ("Dusk Family", "user-dusk-family-password", {"IsHidden": False}),
    ("Dusk Guest", None, {"IsHidden": False}),
    ("Dusk No Downloads", "user-dusk-no-downloads-password",
     {"IsHidden": True, "EnableContentDownloading": False}),
]


def step_jf_users():
    import secrets
    jf = api.jf_admin()
    folders = [jf.library(n)["ItemId"] for n in DEMO_LIBRARIES]
    for name, pw_file, overrides in JF_USERS:
        u = jf.user(name)
        if not u:
            pw = ""
            if pw_file:
                f = api.CFG / pw_file
                if not f.exists():
                    f.write_text(secrets.token_urlsafe(12))
                    f.chmod(0o600)
                pw = f.read_text().strip()
            u = jf.post("/Users/New", {"Name": name, "Password": pw})
            log(f"jellyfin: created user '{name}' ({'password in ' + pw_file if pw_file else 'no password'})")
        policy = jf.get(f"/Users/{u['Id']}")["Policy"]
        policy.update({"IsAdministrator": False, "EnableAllFolders": False, "EnabledFolders": folders,
                       "EnableCollectionManagement": False, "EnableContentDeletion": False,
                       "EnableLiveTvManagement": False, "EnablePublicSharing": False, **overrides})
        jf.post(f"/Users/{u['Id']}/Policy", policy)


def verify_jf_users():
    jf = api.jf_admin()
    public = [u["Name"] for u in api._request("GET", api.JF_URL + "/Users/Public", {})]
    log(f"verify users: login screen shows {public}")
    for name, pw_file, _ in JF_USERS:
        u = jf.user(name)
        p = u["Policy"]
        views = [v["Name"] for v in jf.get("/UserViews", userId=u["Id"])["Items"]]
        log(f"  {name}: empty-password sign-in={pw_file is None} hidden={p['IsHidden']} "
            f"downloads={p['EnableContentDownloading']} views={views}")
        if pw_file:  # the stored password works
            api.Jellyfin(name, api.secret(pw_file))
        else:
            api.Jellyfin(name, "")
    log("  sign-in with the stored passwords: ok")


# ----------------------------------------------------------- paging library
PAGING = "Paging Test"
PAGING_PATH = f"{D}/Paging Test"


def _plex_shares(owner_token):
    import xml.etree.ElementTree as ET
    mid = api.plex_owner().machine_id()
    _, body = api.plex_tv("GET", f"/api/servers/{mid}/shared_servers", owner_token, accept="application/xml")
    return mid, ET.fromstring(body).findall("SharedServer")


def step_paging():
    plex, jf = api.plex_owner(), api.jf_admin()
    # Plex: personal-media agent (no online matching), no BIF / markers
    sec = plex.section(PAGING)
    if not sec:
        plex.req("POST", "/library/sections", {
            "name": PAGING, "type": "movie", "agent": "tv.plex.agents.none", "scanner": "Plex Movie",
            "language": "xn", "location": PAGING_PATH})
        sec = plex.section(PAGING)
        log(f"plex: created library '{PAGING}' (key {sec['key']})")
    plex.req("PUT", f"/library/sections/{sec['key']}/prefs", {
        "enableBIFGeneration": 0, "enableCreditsMarkerGeneration": 0, "enableAdMarkerGeneration": 0,
        "enableLoudnessAnalysis": 0, "enableVoiceActivityGeneration": 0})
    # the personal-media agent keeps "Title (Year)" as the title and no year; Jellyfin
    # parses both, so write title + year (locked) to make the two servers identical
    import re
    fixed = 0
    for it in plex.items(sec["key"]):
        m = re.fullmatch(r"(.*) \((\d{4})\)", it["title"])
        if m:
            plex.req("PUT", f"/library/sections/{sec['key']}/all", {
                "type": 1, "id": it["ratingKey"], "title.value": m.group(1), "title.locked": 1,
                "year.value": m.group(2), "year.locked": 1})
            fixed += 1
    if fixed:
        log(f"plex: set title/year on {fixed} Paging Test items")
    # Plex sharing: add the section to duskcompare's share only (never tester's)
    token = api.secret("plex-token")
    mid, shares = _plex_shares(token)
    for s in shares:
        if s.get("username") != "duskcompare":
            continue
        ids = [x.get("id") for x in s.findall("Section") if x.get("shared") == "1"]
        new = [x.get("id") for x in s.findall("Section") if x.get("title") == PAGING and x.get("shared") != "1"]
        if new:
            api.plex_tv("PUT", f"/api/servers/{mid}/shared_servers/{s.get('id')}", token,
                        body={"server_id": mid, "shared_server": {"library_section_ids": [int(i) for i in ids + new]}},
                        accept="application/xml")
            log("plex: shared Paging Test with duskcompare")
    # Jellyfin: no metadata or image fetchers, no trickplay / chapter images
    if not jf.library(PAGING):
        opts = {
            "Enabled": True, "EnableRealtimeMonitor": False, "EnablePhotos": False,
            "EnableChapterImageExtraction": False, "ExtractChapterImagesDuringLibraryScan": False,
            "EnableTrickplayImageExtraction": False, "ExtractTrickplayImagesDuringLibraryScan": False,
            "EnableLUFSScan": False, "SaveLocalMetadata": False, "EnableInternetProviders": False,
            "EnableEmbeddedTitles": False, "AutomaticallyAddToCollection": False,
            "PathInfos": [{"Path": PAGING_PATH}],
            "TypeOptions": [{"Type": "Movie", "MetadataFetchers": [], "MetadataFetcherOrder": [],
                             "ImageFetchers": [], "ImageFetcherOrder": [], "ImageOptions": []}],
        }
        jf.req("POST", "/Library/VirtualFolders",
               {"name": PAGING, "collectionType": "movies", "refreshLibrary": "true"},
               body={"LibraryOptions": opts})
        log(f"jellyfin: created library '{PAGING}'")
    # tester keeps an explicit folder list, so a new library stays invisible to it
    t = jf.user("tester")["Policy"]
    assert not t["EnableAllFolders"], "tester must not have EnableAllFolders"


def verify_paging():
    plex, jf = api.plex_owner(), api.jf_admin()
    sec = plex.section(PAGING)
    n_plex = plex.mc(f"/library/sections/{sec['key']}/all", **{"X-Plex-Container-Start": 0, "X-Plex-Container-Size": 0}).get("totalSize")
    lib = jf.library(PAGING)
    n_jf = jf.get("/Items", userId=jf.user_id, parentId=lib["ItemId"], recursive="true",
                  includeItemTypes="Movie", limit=0)["TotalRecordCount"]
    letters = [d.get("title") for d in plex.mc(f"/library/sections/{sec['key']}/firstCharacter").get("Directory", [])]
    log(f"verify paging: plex {n_plex} titles, jellyfin {n_jf} titles; plex first characters {letters}")
    _, shares = _plex_shares(api.secret("plex-token"))
    for s in shares:
        shared = sorted(x.get("title") for x in s.findall("Section") if x.get("shared") == "1")
        log(f"  plex share {s.get('username')}: {shared}")
    tester = jf.user("tester")
    compare = jf.user("duskcompare")
    for u in (tester, compare):
        views = [v["Name"] for v in jf.get("/UserViews", userId=u["Id"])["Items"]]
        log(f"  jellyfin {u['Name']} views: {views}")


# ------------------------------------------------- plex markers + previews
OFFICE_S1 = f"{REAL_TV}/The Office (US)/Season 1"
BIF_FILMS = [KNIVES, PADDINGTON]  # the two films with Jellyfin trickplay


def step_plex_analysis():
    """Intro/credits markers for The Office S1 and BIF previews for two films.

    plex-demo has GenerateBIFBehavior=never and the BIF butler task disabled.
    GenerateIndexFilesDuringAnalysis alone does nothing while the behaviour is
    "never"; with GenerateBIFBehavior=asap an item analysis also writes the BIF.
    So the run flips it to asap, analyses only the two films, and
    `plex-analysis-restore` puts "never" back once both BIFs exist (the butler
    task stays disabled, so nothing else gets previews). Films that already
    have a BIF are skipped, and nothing changes when both have one.
    """
    plex = api.plex_owner()
    pidx = PlexIndex(plex)
    todo = [p for p in BIF_FILMS if not plex_meta(plex, pidx[p][1])["Media"][0]["Part"][0].get("indexes")]
    if not todo:
        log("plex: both films already have BIFs")
        return
    plex.req("PUT", "/:/prefs", {"GenerateBIFBehavior": "asap"})
    for p in todo:
        plex.req("PUT", f"/library/metadata/{pidx[p][1]}/analyze")
    log(f"plex: BIF analysis queued for {len(todo)} films; run plex-analysis-restore when both have BIFs")


def step_plex_markers():
    """Intro + credits markers on The Office S1.

    Run before plex-analysis: an analysis while BIFs are switched on would also
    make episode BIFs. Credits come from item analysis; intros from the intro
    butler task (every show missing intros; plex-demo runs it nightly anyway).
    Episodes that already have both marker types are skipped.
    """
    plex = api.plex_owner()
    pidx = PlexIndex(plex)
    season = sorted({pidx[p][1] for p in pidx.by_path if p.startswith(OFFICE_S1 + "/")})
    todo = []
    for rk in season:
        kinds = {m["type"] for m in plex.mc(f"/library/metadata/{rk}", includeMarkers=1)["Metadata"][0].get("Marker", [])}
        if not {"intro", "credits"} <= kinds:
            todo.append(rk)
    if not todo:
        log("plex: The Office S1 already has intro and credits markers")
        return
    for rk in todo:
        plex.req("PUT", f"/library/metadata/{rk}/analyze")  # credits detection
    plex.req("POST", "/butler/ButlerTaskGenerateIntroMarkers")
    log(f"plex: analysis queued for {len(todo)} Office S1 episodes, intro butler started")


def step_plex_analysis_restore():
    api.plex_owner().req("PUT", "/:/prefs", {"GenerateBIFBehavior": "never",
                                             "GenerateIndexFilesDuringAnalysis": 0})
    log("plex: GenerateBIFBehavior restored to never (GenerateIndexFilesDuringAnalysis off)")


def verify_plex_analysis():
    plex = api.plex_owner()
    pidx = PlexIndex(plex)
    for p in sorted(x for x in pidx.by_path if x.startswith(OFFICE_S1 + "/")):
        m = plex.mc(f"/library/metadata/{pidx[p][1]}", includeMarkers=1)["Metadata"][0]
        marks = [f"{k['type']} {k['startTimeOffset'] / 1000:.1f}-{k['endTimeOffset'] / 1000:.1f}s"
                 for k in m.get("Marker", [])]
        log(f"verify markers S01E{m['index']:02d}: {marks or 'none yet'}")
    for p in BIF_FILMS:
        part = plex_meta(plex, pidx[p][1])["Media"][0]["Part"][0]
        status, _ = plex.req("GET", f"/library/parts/{part['id']}/indexes/sd", {"offset": 0}, raw=True) \
            if part.get("indexes") else (None, None)
        log(f"verify BIF {Path(p).stem}: indexes={part.get('indexes')} /indexes/sd -> {status}")
    pref = {x["id"]: x["value"] for x in plex.mc("/:/prefs")["Setting"]
            if x["id"] in ("GenerateIndexFilesDuringAnalysis", "GenerateBIFBehavior")}
    log(f"  prefs {pref}")


# ---------------------------------------------------------------- pre-roll
PREROLL = f"{D}/Prerolls/Dusk Preroll.mp4"
LOCAL_INTROS = "07d8679501f24d22b174cdc6056c3e7c"
JF_REPO = "https://repo.jellyfin.org/files/plugin/manifest.json"


def step_preroll():
    plex, jf = api.plex_owner(), api.jf_admin()
    plex.req("PUT", "/:/prefs", {"CinemaTrailersPrerollID": PREROLL})
    plugins = {x["Id"]: x for x in jf.get("/Plugins")}
    if LOCAL_INTROS not in plugins:
        jf.post("/Packages/Installed/Local Intros", assemblyGuid=LOCAL_INTROS, version="5.0.0.0",
                repositoryUrl=JF_REPO)
        plugins[LOCAL_INTROS] = {"Status": "Restart"}
    if plugins[LOCAL_INTROS]["Status"] != "Active":
        log("jellyfin: restarting once to load Local Intros")
        jf.post("/System/Restart")
        for _ in range(60):
            time.sleep(5)
            try:
                jf = api.jf_admin()
                if any(x["Id"] == LOCAL_INTROS and x["Status"] == "Active" for x in jf.get("/Plugins")):
                    break
            except Exception:
                pass
    cfg = jf.get(f"/Plugins/{LOCAL_INTROS}/Configuration")
    cfg.update({"Local": f"{D}/Prerolls", "IntrosForMoviesOnly": True})
    jf.post(f"/Plugins/{LOCAL_INTROS}/Configuration", cfg)
    jf.post("/LocalIntros/LoadIntros", {})
    log("jellyfin: Local Intros pointed at /data/Prerolls (movies only)")


def verify_preroll():
    plex = plex_compare()
    pidx = PlexIndex(api.plex_owner())
    pref = [x["value"] for x in api.plex_owner().mc("/:/prefs")["Setting"] if x["id"] == "CinemaTrailersPrerollID"]
    q = plex.req("POST", "/playQueues", {"type": "video", "uri": api.plex_owner().uri([pidx[BBB][1]]),
                                         "extrasPrefixCount": 0, "continuous": 0})["MediaContainer"]
    first = [(m.get("type"), m.get("title"), m["Media"][0]["Part"][0].get("file")) for m in q["Metadata"][:2]]
    log(f"verify preroll plex: pref={pref} playQueue(BBB)={first}")
    jf = api.jf_compare()
    jidx = JFIndex(jf)
    for p in (BBB, OFFICE_S1E1):
        intros = [i.get("Path") for i in jf.get(f"/Items/{jidx[p]['Id']}/Intros", userId=jf.user_id)["Items"]]
        log(f"verify preroll jellyfin {Path(p).stem[:30]}: {intros}")


# ---------------------------------------------------------------- tester
def verify_tester():
    """What the App Review account can see; must stay the four demo libraries."""
    jf = api.jf_admin()
    t = jf.user("tester")
    views = [v["Name"] for v in jf.get("/UserViews", userId=t["Id"])["Items"]]
    lists = [i["Name"] for i in jf.items(user_id=t["Id"], includeItemTypes="BoxSet,Playlist")]
    total = jf.get("/Items", userId=t["Id"], recursive="true", limit=0)["TotalRecordCount"]
    paths = [i.get("Path", "") for i in jf.items(user_id=t["Id"], includeItemTypes="Movie,Episode,Video,Photo")]
    outside = [p for p in paths if not any(p.startswith(f"{D}/{lib}/") for lib in DEMO_LIBRARIES)]
    log(f"verify tester jellyfin: views={views} boxsets/playlists={lists} items={total} outside-demo={outside[:5]}")
    _, shares = _plex_shares(api.secret("plex-token"))
    for s in shares:
        if s.get("username") != "duskcompare":
            shared = sorted(x.get("title") for x in s.findall("Section") if x.get("shared") == "1")
            log(f"verify tester plex ({s.get('username')}): allLibraries={s.get('allLibraries')} sections={shared}")


# extra file -> title (same as the embedded title tag make_media.py writes)
EXTRA_TITLES = {
    f"{MOVIES}/Big Buck Bunny (2008)/Deleted Scenes/Alternate Ending.mp4": "Alternate Ending",
    f"{WEEKEND}/Featurettes/Meet the Builders.mp4": "Meet the Builders",
    f"{WEEKEND}/Trailers/Weekend Projects Trailer.mp4": "Weekend Projects Trailer",
    f"{WEEKEND}/Season 01/Behind The Scenes/Season One Bloopers.mp4": "Season One Bloopers",
    f"{WEEKEND}/Season 01/Weekend Projects - S01E01 - Building the Treehouse-behindthescenes.mp4":
        "Building the Treehouse: Behind the Scenes",
}


def step_extra_titles():
    """Plex keeps an extra's first title even after the file is replaced: lock the intended one."""
    plex = api.plex_owner()
    pidx = PlexIndex(plex)
    show = pidx[WEEKEND][1]
    season = next(s["ratingKey"] for s in plex.mc(f"/library/metadata/{show}/children")["Metadata"]
                  if s.get("index") == 1)
    for parent in (pidx[BBB][1], show, season, pidx[WEEKEND_E1][1]):
        for e in plex.mc(f"/library/metadata/{parent}/extras").get("Metadata", []):
            want = EXTRA_TITLES.get(e["Media"][0]["Part"][0].get("file"))
            if want and e["title"] != want:
                plex.req("PUT", f"/library/metadata/{e['ratingKey']}", {"title.value": want, "title.locked": 1})
                log(f"plex: extra '{e['title']}' -> '{want}'")


def step_jf_titles():
    """Jellyfin leaves "Name (Year)" as the name of unmatched folder movies: use Plex's title."""
    plex, jf = api.plex_owner(), api.jf_admin()
    pidx, jidx = PlexIndex(plex), JFIndex(jf)
    for path in (VERSIONS_4K, PARTS, SUB_ASS, SUB_VOB):
        want = plex_meta(plex, pidx[path][1])["title"]
        item = jf.get(f"/Items/{jidx[path]['Id']}", userId=jf.user_id)
        if item["Name"] != want:
            item["Name"] = want
            item["LockedFields"] = sorted(set(item.get("LockedFields") or []) | {"Name"})
            jf.post(f"/Items/{item['Id']}", item)
            log(f"jellyfin: renamed to '{want}'")


STEPS = {
    # in the order of 05-plan.md section 7 as asked for T-0
    "collections": (step_collections, verify_collections, True),
    # scans are asynchronous: run `verify-media` once both servers settled
    "media": (step_media, verify_media, False),
    "merge-versions": (step_merge_versions, verify_media, False),
    "extra-titles": (step_extra_titles, None, False),
    "jf-titles": (step_jf_titles, None, False),
    "playlists": (step_playlists, verify_playlists, True),
    "watch-state": (step_watch_state, verify_watch_state, True),
    "jf-users": (step_jf_users, verify_jf_users, True),
    "paging": (step_paging, verify_paging, False),
    "plex-markers": (step_plex_markers, verify_plex_analysis, False),
    "plex-analysis": (step_plex_analysis, verify_plex_analysis, False),
    "preroll": (step_preroll, verify_preroll, True),
    "tester": (lambda: None, verify_tester, True),
}
# not part of `all`: run after the analysis finished
EXTRA_STEPS = {"plex-analysis-restore": (step_plex_analysis_restore, verify_plex_analysis, True)}


def main(argv):
    names = argv
    if not names or names == ["all"]:
        print(__doc__)
        print("steps:", ", ".join(STEPS))
        return 2
    for n in names:
        table = {**STEPS, **EXTRA_STEPS}
        if n.startswith("verify-"):
            table[n[len("verify-"):]][1]()
            continue
        do, verify, auto_verify = table[n]
        log(f"== {n}")
        do()
        if verify and auto_verify:
            time.sleep(2)
            verify()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
