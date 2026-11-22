#!/usr/bin/env python3
"""Mock plex.tv + one Plex Media Server with a very large library.

Movies (default 60 000) and TV shows (default 12 000) are synthesised
deterministically. Every PMS response is delayed by a latency model that
mimics how a real PMS on a NAS behaves at that size:

  * every request pays a base round trip (--rtt ms)
  * DB-bound endpoints (/all, counts, hubs, filter values, history) pay a
    scan cost proportional to the section size (--scan-us per row), because a
    sorted/filtered SQLite query walks the whole section even when only one
    page is returned
  * DB work is serialised through a small pool (--db-workers), like PMS's
    SQLite access under load
  * returned items cost --item-us each (serialisation)

Every request is logged with its arrival time (relative to the first
request), duration and path, so the client's critical path can be read off.

Movies and TV Shows carry a few Plex collections (manual ones tag their
titles with `Collection`, smart ones do not; one smart movie collection holds
thousands of titles so collection paging can be measured). --collection-mode
sets the sections' "Collections" pref (0 disabled, 1 hide items in
collections, 2 show both); with 1, `/all?includeCollections=1` folds a manual
collection's titles into the collection like PMS does.

With --photos N it also serves a photo library (section 3): year albums with
month sub-albums, a few trip albums, loose root photos and ~5% video clips,
answering the type=14 / type=13,12 / parent= / clusterZoomLevel=1 queries the
app sends. Images come from /photo/:/transcode as generated plasma JPEGs
(ImageMagick, cached under --image-cache) so grids look like photos.

Local extras (/library/metadata/{rk}/extras): every movie whose rating key is
divisible by 4 has 2-5 (trailer, featurette, deleted scene, ...), and the
first TV show gets a real season/episode tree (2 seasons x 4 episodes) with
extras on the show, season 1 and episode S1E1. Extra rating keys start at
700000 and resolve through /library/metadata/{rk} like any clip.

Usage (see docs/development-workflow.md -> "Large-library reproduction"):
  python3 scripts/mock_large_plex.py [--movies 60000] [--scan-us 25] [--photos 5000]
then launch a Debug build in DEBUG screenshot mode:
  xcrun simctl launch <device> com.dusk-player.app -DuskScreenshotMode YES \
    -DuskScreenshotPlexTV http://127.0.0.1:47600 -DuskScreenshotScreen movies
The request log (arrival time, duration, path) is the measurement.
"""
import argparse
import json
import os
import random
import re
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

GENRES = ["Action", "Adventure", "Animation", "Biography", "Comedy", "Crime", "Documentary",
          "Drama", "Family", "Fantasy", "History", "Horror", "Music", "Musical", "Mystery",
          "Romance", "Science Fiction", "Sport", "Thriller", "War", "Western", "Short",
          "Reality", "Talk Show", "Game Show"]
WORDS = ["Night", "Shadow", "River", "Last", "Silent", "Golden", "Broken", "Lost", "Iron", "Paper",
         "Winter", "Summer", "Red", "Blue", "City", "House", "Dream", "Storm", "Glass", "Wild",
         "Echo", "Signal", "Harbor", "Empire", "Garden", "Machine", "Ghost", "Stone", "Fire", "Ocean",
         "Hunter", "Secret", "Midnight", "Velvet", "Crown", "Desert", "Northern", "Electric", "Hidden", "Final"]
NOW = int(time.time())
SERVER_ID = "bigplexserver000000000000000000000000001"
T0 = None
T0_LOCK = threading.Lock()


def log(msg):
    print(msg, flush=True)


class Library:
    def __init__(self, movies, shows):
        rnd = random.Random(42)
        self.items = {}
        self.sections = {"1": {"key": "1", "type": "movie", "title": "Movies", "rks": []},
                         "2": {"key": "2", "type": "show", "title": "TV Shows", "rks": []}}
        rk = 1000
        for sec_key, count, kind in (("1", movies, "movie"), ("2", shows, "show")):
            for i in range(count):
                rk += 1
                title = f"{rnd.choice(WORDS)} {rnd.choice(WORDS)}" + (f" {i % 97}" if i % 3 else "")
                genres = rnd.sample(GENRES, rnd.randint(1, 3))
                it = {"rk": str(rk), "kind": kind, "sec": sec_key, "title": title,
                      "year": rnd.randint(1950, 2026), "genres": genres,
                      "addedAt": NOW - rnd.randint(0, 86400 * 3000),
                      "rating": round(rnd.uniform(3, 9.5), 1),
                      "duration": rnd.randint(70, 180) * 60000,
                      "watched": rnd.random() < 0.25}
                if kind == "show":
                    it["leafCount"] = rnd.randint(6, 120)
                    it["viewedLeafCount"] = it["leafCount"] if it["watched"] else 0
                self.items[str(rk)] = it
                self.sections[sec_key]["rks"].append(str(rk))
        # A heavy user: 80 titles watched in the last 30 days, a few in progress.
        self.history = []
        for sec_key in ("1", "2"):
            for rk in rnd.sample(self.sections[sec_key]["rks"], 80):
                self.items[rk]["watched"] = True
                self.items[rk]["lastViewedAt"] = NOW - rnd.randint(0, 86400 * 29)
                self.history.append(rk)
            for rk in rnd.sample(self.sections[sec_key]["rks"], 8):
                self.items[rk]["viewOffset"] = 1800000
        self.genre_ids = {g: str(100 + i) for i, g in enumerate(GENRES)}
        self.build_collections(rnd)
        self.build_series_tree()
        self.build_extras(rnd)

    # -- extras ----------------------------------------------------------------

    EXTRA_KINDS = [(1, "trailer", "Trailer"), (10, "featurette", "Featurette"),
                   (2, "deletedScene", "Deleted Scene"), (5, "behindTheScenes", "Making Of"),
                   (3, "interview", "Cast Interview"), (11, "short", "Short Film")]

    def build_series_tree(self):
        """Seasons and episodes for the first show only; the rest stay leafless."""
        self.tree = {}
        self.tree_children = {}
        shows = self.sections["2"]["rks"]
        if not shows:
            return
        show = shows[0]
        self.items[show]["leafCount"], self.items[show]["viewedLeafCount"] = 8, 0
        rk = 750000
        for season in (1, 2):
            rk += 1
            srk = str(rk)
            self.tree[srk] = {"kind": "season", "index": season, "parent": show,
                              "title": f"Season {season}"}
            self.tree_children.setdefault(show, []).append(srk)
            for episode in range(1, 5):
                rk += 1
                erk = str(rk)
                self.tree[erk] = {"kind": "episode", "index": episode, "parent": srk, "show": show,
                                  "season": season, "title": f"Episode {episode}"}
                self.tree_children.setdefault(srk, []).append(erk)

    def build_extras(self, rnd):
        self.extras = {}
        self.extra_items = {}
        rk = 700000
        owners = [m for m in self.sections["1"]["rks"] if int(m) % 4 == 0]
        if self.sections["2"]["rks"]:
            show = self.sections["2"]["rks"][0]
            seasons = self.tree_children.get(show, [])
            owners += [show] + seasons[:1] + self.tree_children.get(seasons[0], [])[:1] if seasons else [show]
        for owner in owners:
            kinds = self.EXTRA_KINDS[:rnd.randint(2, 5)]
            for code, subtype, title in kinds:
                rk += 1
                self.extra_items[str(rk)] = {"owner": owner, "extraType": code, "subtype": subtype,
                                             "title": title, "duration": rnd.randint(60, 1500) * 1000}
                self.extras.setdefault(owner, []).append(str(rk))

    def extra_metadata(self, rk):
        x = self.extra_items[rk]
        return {"ratingKey": rk, "key": f"/library/metadata/{rk}", "guid": f"local://{rk}",
                "type": "clip", "subtype": x["subtype"], "extraType": x["extraType"],
                "title": x["title"], "duration": x["duration"], "index": 1,
                "thumb": f"/library/metadata/{rk}/thumb/{NOW}", "art": f"/library/metadata/{rk}/art/{NOW}",
                "addedAt": NOW, "updatedAt": NOW,
                "Media": [{"id": int(rk), "duration": x["duration"], "videoCodec": "h264", "audioCodec": "aac",
                           "audioChannels": 2, "container": "mp4", "width": 1920, "height": 1080,
                           "videoResolution": "1080",
                           "Part": [{"id": int(rk), "key": f"/library/parts/{rk}/1/file.mp4",
                                     "duration": x["duration"], "file": f"/data/extras/{rk}-{x['subtype']}.mp4",
                                     "size": 50_000_000, "container": "mp4"}]}]}

    def tree_metadata(self, rk):
        t = self.tree[rk]
        if t["kind"] == "season":
            show = self.items[t["parent"]]
            return {"ratingKey": rk, "key": f"/library/metadata/{rk}/children", "type": "season",
                    "title": t["title"], "index": t["index"], "parentRatingKey": t["parent"],
                    "parentKey": f"/library/metadata/{t['parent']}", "parentTitle": show["title"],
                    "parentThumb": f"/library/metadata/{t['parent']}/thumb/{NOW}",
                    "thumb": f"/library/metadata/{t['parent']}/thumb/{NOW}",
                    "art": f"/library/metadata/{t['parent']}/art/{NOW}", "librarySectionID": 2,
                    "summary": "A synthetic season.", "leafCount": 4, "viewedLeafCount": 0, "addedAt": NOW}
        show_rk = t["show"]
        show = self.items[show_rk]
        duration = 42 * 60000
        return {"ratingKey": rk, "key": f"/library/metadata/{rk}", "type": "episode", "title": t["title"],
                "index": t["index"], "parentIndex": t["season"], "parentRatingKey": t["parent"],
                "parentTitle": f"Season {t['season']}", "grandparentRatingKey": show_rk,
                "grandparentTitle": show["title"], "grandparentKey": f"/library/metadata/{show_rk}",
                "grandparentThumb": f"/library/metadata/{show_rk}/thumb/{NOW}",
                "grandparentArt": f"/library/metadata/{show_rk}/art/{NOW}",
                "thumb": f"/library/metadata/{rk}/thumb/{NOW}", "librarySectionID": 2,
                "summary": "A synthetic episode. " * 4, "duration": duration, "addedAt": NOW,
                "originallyAvailableAt": f"{show['year']}-0{t['season']}-0{t['index']}",
                "Media": [{"id": int(rk), "duration": duration, "videoCodec": "h264", "audioCodec": "aac",
                           "audioChannels": 2, "container": "mp4", "width": 1920, "height": 1080,
                           "videoResolution": "1080",
                           "Part": [{"id": int(rk), "key": f"/library/parts/{rk}/1/file.mp4", "duration": duration,
                                     "file": f"/data/{rk}.mp4", "size": 1_000_000_000, "container": "mp4"}]}]}

    # -- collections ---------------------------------------------------------

    def build_collections(self, rnd):
        """Collection rating keys start at 800000; `index` is the tag id an
        item's `Collection` tag carries."""
        self.collections = {}
        self.item_collections = {}
        movies, shows = self.sections["1"]["rks"], self.sections["2"]["rks"]
        specs = [
            ("1", "The Night Saga", False, lambda: [rk for rk in movies if "Night" in self.items[rk]["title"]][:9]),
            ("1", "Golden Classics", False, lambda: sorted(movies, key=lambda r: self.items[r]["year"])[:24]),
            ("1", "Storm Trilogy", False, lambda: [rk for rk in movies if self.items[rk]["title"].startswith("Storm")][:3]),
            ("1", "Weekend Picks", False, lambda: rnd.sample(movies, min(60, len(movies)))),
            ("1", "Top Rated Thrillers", True,
             lambda: [rk for rk in movies if "Thriller" in self.items[rk]["genres"] and self.items[rk]["rating"] >= 8.5]),
            ("1", "Everything Electric", True, lambda: [rk for rk in movies if "Electric" in self.items[rk]["title"]]),
            ("2", "Crime Nights", False, lambda: [rk for rk in shows if "Crime" in self.items[rk]["genres"]][:14]),
            ("2", "Short Runs", True, lambda: [rk for rk in shows if self.items[rk]["leafCount"] <= 10][:40]),
        ]
        for i, (sec, title, smart, members) in enumerate(specs):
            crk = str(800000 + i)
            rks = members()
            self.collections[crk] = {"rk": crk, "sec": sec, "title": title, "smart": smart, "index": 5000 + i,
                                     "rks": rks, "addedAt": NOW - i * 86400}
            if not smart:
                for rk in rks:
                    self.item_collections.setdefault(rk, []).append(crk)
        for sec in self.sections.values():
            sec["collections"] = [c for c in self.collections if self.collections[c]["sec"] == sec["key"]]

    def collection_metadata(self, crk):
        c = self.collections[crk]
        kind = self.sections[c["sec"]]["type"]
        first = c["rks"][0] if c["rks"] else crk
        md = {"ratingKey": crk, "key": f"/library/collections/{crk}/children", "guid": f"collection://{crk}",
              "type": "collection", "subtype": kind, "title": c["title"], "titleSort": c["title"],
              "summary": f"{c['title']}: a synthetic {'smart ' if c['smart'] else ''}collection of "
                         f"{len(c['rks'])} {kind}s.",
              "index": c["index"], "childCount": len(c["rks"]), "smart": "1" if c["smart"] else "0",
              "collectionMode": "-1", "collectionSort": "1" if c["smart"] else "0",
              "librarySectionID": int(c["sec"]), "librarySectionTitle": self.sections[c["sec"]]["title"],
              "thumb": f"/library/collections/{crk}/composite/{NOW}",
              "art": f"/library/metadata/{first}/art/{NOW}",
              "addedAt": c["addedAt"], "updatedAt": c["addedAt"]}
        if c["smart"]:
            md["content"] = f"/library/sections/{c['sec']}/all?type=1&title={c['title']}"
        return md

    def metadata(self, rk, detail=False):
        it = self.items[rk]
        kind = it["kind"]
        md = {"ratingKey": rk, "key": f"/library/metadata/{rk}" + ("/children" if kind == "show" else ""),
              "guid": f"plex://{kind}/{rk:0>24}", "type": kind, "title": it["title"],
              "titleSort": it["title"], "year": it["year"], "summary": "A synthetic title. " * 12,
              "thumb": f"/library/metadata/{rk}/thumb/{NOW}", "art": f"/library/metadata/{rk}/art/{NOW}",
              "addedAt": it["addedAt"], "updatedAt": it["addedAt"], "audienceRating": it["rating"],
              "duration": it["duration"], "librarySectionID": int(it["sec"]),
              "originallyAvailableAt": f"{it['year']}-06-01", "contentRating": "PG-13",
              "Genre": [{"tag": g} for g in it["genres"][:2]],
              "Director": [{"tag": "Some Director"}], "Country": [{"tag": "United States of America"}],
              "Role": [{"tag": f"Actor {n}"} for n in range(3)]}
        if it.get("watched"):
            md["viewCount"] = 1
        if it.get("lastViewedAt"):
            md["lastViewedAt"] = it["lastViewedAt"]
        if it.get("viewOffset"):
            md["viewOffset"] = it["viewOffset"]
        if kind == "show":
            md["leafCount"] = it["leafCount"]
            md["viewedLeafCount"] = it["viewedLeafCount"]
            md["childCount"] = len(self.tree_children.get(rk, [])) or 1
        else:
            md["Media"] = [{"id": int(rk), "duration": it["duration"], "bitrate": 9000, "width": 1920,
                            "height": 1080, "videoCodec": "h264", "audioCodec": "aac", "audioChannels": 2,
                            "container": "mp4", "videoResolution": "1080",
                            "Part": [{"id": int(rk), "key": f"/library/parts/{rk}/1/file.mp4",
                                      "duration": it["duration"], "file": f"/data/{rk}.mp4",
                                      "size": 4_000_000_000, "container": "mp4"}]}]
        if self.item_collections.get(rk):
            md["Collection"] = [{"id": self.collections[c]["index"], "tag": self.collections[c]["title"],
                                 "filter": f"collection={self.collections[c]['index']}"}
                                for c in self.item_collections[rk]]
        if detail:
            md["Genre"] = [{"tag": g, "id": int(self.genre_ids[g])} for g in it["genres"]]
            md["Guid"] = [{"id": f"tmdb://{rk}"}]
        return md


class PhotoLibrary:
    """Section 3: albums are Plex `Directory type="photo"` rows, which JSON
    flattens into Metadata with `type: "photo"` and a `/children` key."""

    MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August",
              "September", "October", "November", "December"]
    PLACES = ["Zürich, Switzerland", "Lisbon, Portugal", "Reykjavík, Iceland", "Kyoto, Japan",
              "Bern, Switzerland", "Lucerne, Switzerland"]
    CAMERAS = [("Apple", "iPhone 15 Pro"), ("Apple", "iPhone 13"), ("FUJIFILM", "X-T5"), ("SONY", "ILCE-7M4")]

    def __init__(self, count, first_rk=900000):
        rnd = random.Random(7)
        self.items = {}
        self.order = []
        rk = first_rk

        def add(item):
            nonlocal rk
            rk += 1
            item["rk"] = str(rk)
            self.items[item["rk"]] = item
            self.order.append(item["rk"])
            return item["rk"]

        years = list(range(2019, 2027))
        trips = [("Iceland 2023", 2023, 7), ("Japan 2024", 2024, 4), ("Lisbon 2025", 2025, 9)]
        trips_rk = add({"kind": "album", "title": "Trips", "parent": None})
        month_albums = []
        for title, year, month in trips:
            month_albums.append((add({"kind": "album", "title": title, "parent": trips_rk}), year, month))
        for year in reversed(years):
            year_rk = add({"kind": "album", "title": str(year), "parent": None})
            for month in range(1, 13):
                if year == 2026 and month > 10:
                    break
                month_albums.append((add({"kind": "album", "title": f"{self.MONTHS[month - 1]} {year}",
                                          "parent": year_rk}), year, month))
        loose = min(24, count)
        for i in range(count):
            if i < loose:
                parent, year, month = None, 2026, 10
            else:
                parent, year, month = month_albums[rnd.randrange(len(month_albums))]
            day = rnd.randint(1, 18 if (year, month) == (2026, 10) else 28)
            is_clip = rnd.random() < 0.05
            portrait = rnd.random() < 0.3
            make, model = rnd.choice(self.CAMERAS)
            add({"kind": "clip" if is_clip else "photo", "title": f"IMG_{4000 + i:04d}",
                 "parent": parent, "date": f"{year}-{month:02d}-{day:02d}",
                 "addedAt": NOW - rnd.randint(0, 86400 * 900),
                 "width": 3024 if portrait else 4032, "height": 4032 if portrait else 3024,
                 "make": make, "model": model,
                 "place": rnd.choice(self.PLACES) if rnd.random() < 0.4 else None,
                 "duration": rnd.randint(3000, 45000) if is_clip else None})

    def metadata(self, rk):
        it = self.items[rk]
        md = {"ratingKey": rk, "type": "clip" if it["kind"] == "clip" else "photo", "title": it["title"],
              "thumb": f"/library/metadata/{rk}/thumb/{NOW}", "librarySectionID": 3,
              "addedAt": it.get("addedAt", NOW), "updatedAt": NOW, "guid": f"local://{rk}"}
        if it["parent"]:
            md["parentRatingKey"] = it["parent"]
            md["parentKey"] = f"/library/metadata/{it['parent']}"
        if it["kind"] == "album":
            md["key"] = f"/library/metadata/{rk}/children"
            md["composite"] = f"/library/metadata/{rk}/composite/{NOW}"
            return md
        md["key"] = f"/library/metadata/{rk}"
        md["originallyAvailableAt"] = it["date"]
        md["year"] = int(it["date"][:4])
        if it.get("place"):
            md["Place"] = [{"tag": it["place"]}]
        if it["kind"] == "clip":
            md["subtype"] = "photo"
            md["duration"] = it["duration"]
            md["Media"] = [{"id": int(rk), "duration": it["duration"], "width": 1920, "height": 1080,
                            "videoCodec": "h264", "audioCodec": "aac", "audioChannels": 2, "container": "mov",
                            "optimizedForStreaming": 1, "videoResolution": "1080",
                            "Part": [{"id": int(rk), "key": f"/library/parts/{rk}/{NOW}/file.mov",
                                      "duration": it["duration"], "file": f"/photos/{rk}.mov", "size": 20_000_000,
                                      "container": "mov", "optimizedForStreaming": True}]}]
        else:
            md["Media"] = [{"id": int(rk), "width": it["width"], "height": it["height"], "aspectRatio": 1.33,
                            "container": "jpeg", "make": it["make"], "model": it["model"],
                            "Part": [{"id": int(rk), "key": f"/library/parts/{rk}/{NOW}/file.jpg",
                                      "size": 3_000_000, "container": "jpeg"}]}]
        return md

    def children(self, parent):
        return [rk for rk in self.order if self.items[rk]["parent"] == parent]

    def query(self, q):
        types = set((q.get("type") or "").split(",")) - {""}
        parent = q.get("parent")
        if types == {"14"}:
            rks = [rk for rk in self.order if self.items[rk]["kind"] == "album" and self.items[rk]["parent"] == parent]
        elif types:
            kinds = {"13": "photo", "12": "clip"}
            wanted = {kinds[t] for t in types if t in kinds}
            clustered = q.get("clusterZoomLevel") == "1" and not parent
            rks = [rk for rk in self.order if self.items[rk]["kind"] in wanted
                   and (clustered or self.items[rk]["parent"] == parent)]
        else:
            rks = self.children(parent)
        sort = (q.get("sort") or "titleSort").split(",")[0]
        field, _, direction = sort.partition(":")
        if field == "originallyAvailableAt":
            key = lambda r: (self.items[r].get("date", ""), self.items[r]["title"])
        elif field == "addedAt":
            key = lambda r: self.items[r].get("addedAt", 0)
        else:
            key = lambda r: self.items[r]["title"].lower()
        return sorted(rks, key=key, reverse=direction == "desc")


class ImageBank:
    """A few dozen generated photo-like JPEGs, picked by rating key."""

    def __init__(self, directory, count=36):
        self.paths = []
        if not directory:
            return
        os.makedirs(directory, exist_ok=True)
        palette = ["#1d3557-#e9c46a", "#264653-#f4a261", "#0b3c5d-#d9b310", "#2a9d8f-#e76f51",
                   "#3d405b-#f2cc8f", "#14213d-#fca311", "#335c67-#e09f3e", "#023047-#ffb703",
                   "#283618-#dda15e"]
        for i in range(count):
            portrait = i % 4 == 3
            size = "900x1200" if portrait else "1200x900"
            for variant, scale in (("full", None), ("small", "360x360^")):
                path = os.path.join(directory, f"photo-{i:02d}-{variant}.jpg")
                if not os.path.exists(path):
                    if variant == "full":
                        cmd = ["magick", "-seed", str(i + 1), "-size", size, f"plasma:{palette[i % len(palette)]}",
                               "-blur", "0x6", "-modulate", "100,130", "-quality", "85", path]
                    else:
                        cmd = ["magick", os.path.join(directory, f"photo-{i:02d}-full.jpg"), "-resize", scale,
                               "-gravity", "center", "-extent", "360x360", "-quality", "80", path]
                    try:
                        subprocess.run(cmd, check=True, capture_output=True)
                    except (OSError, subprocess.CalledProcessError):
                        self.paths = []
                        return
            self.paths.append(i)
        self.directory = directory
        self.cache = {}

    def image(self, rk, large):
        if not self.paths:
            return None
        i = self.paths[int(rk) % len(self.paths)]
        path = os.path.join(self.directory, f"photo-{i:02d}-{'full' if large else 'small'}.jpg")
        if path not in self.cache:
            with open(path, "rb") as f:
                self.cache[path] = f.read()
        return self.cache[path]


def container(**fields):
    mc = {"size": 0}
    mc.update({k: v for k, v in fields.items() if v is not None})
    for key in ("Metadata", "Directory", "Hub"):
        if key in mc:
            mc["size"] = len(mc[key])
    return {"MediaContainer": mc}


# A 1x1 grey PNG for every image request.
PNG = bytes.fromhex(
    "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
    "0000000d4944415478da6364606060000000050001a5f645400000000049454e44ae426082")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    lib = None
    role = None
    args = None
    db = None
    port = None
    photos = None
    images = None

    def log_message(self, fmt, *args):
        pass

    def _send(self, body, ctype="application/json", status=200):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, obj, status=200):
        self._send(json.dumps(obj).encode(), status=status)

    def do_POST(self):
        self.do_GET()

    def do_PUT(self):
        self.do_GET()

    def do_GET(self):
        global T0
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        url = urlparse(self.path)
        q = {k: v[-1] for k, v in parse_qs(url.query).items()}
        start = time.time()
        with T0_LOCK:
            if T0 is None:
                T0 = start
        if self.role == "plextv":
            self.plextv(url.path, q)
        else:
            self.pms(url.path, q)
        quiet = url.path.startswith("/photo") or re.fullmatch(r"/library/metadata/\d+/(thumb|art)/\d+", url.path)
        if not quiet:
            tag = "tv " if self.role == "plextv" else "pms"
            shown = url.path + ("?" + url.query if url.query else "")
            log(f"{start - T0:8.2f}s +{time.time() - start:5.2f}s [{tag}] {self.command} {shown[:160]}")

    # -- latency -------------------------------------------------------------

    def delay(self, scan_rows=0, items=0):
        a = self.args
        time.sleep(a.rtt / 1000)
        if scan_rows:
            with self.db:
                time.sleep(scan_rows * a.scan_us / 1e6)
        if items:
            time.sleep(items * a.item_us / 1e6)

    # -- plex.tv ---------------------------------------------------------------

    def plextv(self, path, q):
        user = {"id": 1, "uuid": "bigplexuser", "username": "bigplex", "title": "Big Plex",
                "friendlyName": "Big Plex", "email": "bigplex@example.com", "thumb": "",
                "authToken": "dusk-screenshot-demo-token", "homeSize": 1, "homeAdmin": True,
                "subscription": {"active": True, "status": "Active", "plan": "lifetime", "features": []},
                "settings": []}
        if path in ("/api/v2/user", "/user", "/users/account", "/api/v2/user/"):
            self._json(user)
        elif path == "/api/v2/user/settings":
            self._json([])
        elif path == "/api/v2/home/users":
            self._json({"id": 1, "name": "Home", "guestUserID": None, "subscription": True,
                        "users": [{"id": 1, "uuid": "bigplexuser", "title": "Big Plex", "username": "bigplex",
                                   "email": "", "friendlyName": "Big Plex", "thumb": "", "hasPassword": True,
                                   "restricted": False, "admin": True, "guest": False, "protected": False,
                                   "home": True}]})
        elif path == "/api/v2/resources":
            port = self.port + 1
            self._json([{
                "name": "Big NAS", "product": "Plex Media Server", "productVersion": "1.42.1.10060",
                "platform": "Linux", "platformVersion": "6.8", "device": "Docker", "clientIdentifier": SERVER_ID,
                "createdAt": "2023-01-01T00:00:00Z", "lastSeenAt": "2026-10-19T09:00:00Z",
                "provides": "server", "ownerId": None, "sourceTitle": None, "publicAddress": "127.0.0.1",
                "accessToken": "big-server-token", "owned": True, "home": False, "synced": False,
                "relay": True, "presence": True, "httpsRequired": False, "publicAddressMatches": True,
                "dnsRebindingProtection": False, "natLoopbackSupported": True,
                "connections": [{"protocol": "http", "address": "127.0.0.1", "port": port,
                                 "uri": f"http://127.0.0.1:{port}", "local": True, "relay": False, "IPv6": False}]}])
        elif path.startswith("/api/v2/pins"):
            self._json({"id": 1, "code": "DEMO", "authToken": "dusk-screenshot-demo-token"})
        else:
            self._json({})

    # -- PMS -------------------------------------------------------------------

    def pms(self, path, q):
        lib = self.lib
        if path.startswith("/photo") or re.fullmatch(r"/library/metadata/\d+/(thumb|art|composite)/\d+", path) \
                or re.fullmatch(r"/library/sections/\w+/composite/\d+", path):
            time.sleep(self.args.rtt / 1000)
            source = q.get("url", path)
            m = re.search(r"/library/(?:metadata|parts)/(\d+)", source)
            jpeg = None
            # With --photos the image bank also gives extras and the episode
            # tree real-looking stills instead of grey squares.
            if m and self.photos and (m.group(1) in self.photos.items or m.group(1) in lib.extra_items
                                      or m.group(1) in lib.tree):
                large = int(q.get("width", 0) or 0) > 800 or "/library/parts/" in source
                jpeg = self.images.image(m.group(1), large)
            if jpeg:
                self._send(jpeg, "image/jpeg")
            else:
                self._send(PNG, "image/png")
        elif path == "/identity":
            self.delay()
            self._json(container(claimed=True, machineIdentifier=SERVER_ID, version="1.42.1"))
        elif path in ("/", ""):
            self.delay()
            self._json(container(friendlyName="Big NAS", machineIdentifier=SERVER_ID, version="1.42.1"))
        elif path == "/library/sections":
            self.delay()
            sections = list(lib.sections.values())
            if self.photos:
                sections.append({"key": "3", "type": "photo", "title": "Photos"})
            dirs = [{"key": s["key"], "type": s["type"], "title": s["title"], "agent": "tv.plex.agents.movie",
                     "scanner": "Plex Movie", "language": "en-US", "uuid": f"uuid-{s['key']}",
                     "art": f"/library/sections/{s['key']}/composite/{NOW}",
                     "thumb": f"/library/sections/{s['key']}/composite/{NOW}",
                     "updatedAt": NOW, "createdAt": NOW, "scannedAt": NOW, "content": True,
                     "directory": True, "hidden": 0, "filters": True, "refreshing": False}
                    for s in sections]
            for d in dirs:
                if d["type"] == "photo":
                    d["agent"], d["scanner"] = "com.plexapp.agents.none", "Plex Photo Scanner"
            self._json(container(Directory=dirs))
        elif m := re.fullmatch(r"/library/sections/(\w+)/all", path):
            if m.group(1) == "3" and self.photos:
                self.photo_all(q)
            else:
                self.section_all(lib.sections.get(m.group(1)), q)
        elif self.photos and (m := re.fullmatch(r"/library/metadata/(\d+)(/children)?", path)) \
                and m.group(1) in self.photos.items:
            self.delay()
            rks = self.photos.children(m.group(1)) if m.group(2) else [m.group(1)]
            self._json(container(Metadata=[self.photos.metadata(rk) for rk in rks]))
        elif m := re.fullmatch(r"/library/sections/(\w+)/firstCharacter", path):
            sec = lib.sections[m.group(1)]
            self.delay(scan_rows=len(sec["rks"]))
            counts = {}
            for rk in sec["rks"]:
                c = lib.items[rk]["title"][0].upper()
                counts[c] = counts.get(c, 0) + 1
            self._json(container(Directory=[{"key": c, "title": c, "size": n} for c, n in sorted(counts.items())]))
        elif m := re.fullmatch(r"/library/sections/(\w+)/filters", path):
            self.delay()
            k = m.group(1)
            self._json(container(Directory=[
                {"filter": "genre", "filterType": "string", "key": f"/library/sections/{k}/genre", "title": "Genre", "type": "filter"},
                {"filter": "unwatched", "filterType": "boolean", "key": f"/library/sections/{k}/unwatched", "title": "Unplayed", "type": "filter"}]))
        elif m := re.fullmatch(r"/library/sections/(\w+)/genre", path):
            sec = lib.sections[m.group(1)]
            self.delay(scan_rows=len(sec["rks"]) // 4)
            self._json(container(Directory=[{"fastKey": f"/library/sections/{sec['key']}/all?genre={gid}",
                                             "key": gid, "title": g, "type": "genre"}
                                            for g, gid in sorted(lib.genre_ids.items())]))
        elif m := re.fullmatch(r"/library/sections/(\w+)/collections", path):
            sec = lib.sections.get(m.group(1))
            crks = sorted(sec["collections"] if sec else [], key=lambda c: lib.collections[c]["title"].lower())
            self.paged(crks, q, lib.collection_metadata, scan_rows=len(crks))
        elif re.fullmatch(r"/library/sections/(\w+)/collection", path):
            self.delay()
            self._json(container(Directory=[]))
        elif m := re.fullmatch(r"/library/sections/(\w+)/prefs", path):
            self.delay()
            self._json(container(Setting=[
                {"id": "collectionMode", "label": "Collections", "type": "int", "default": 2,
                 "value": self.args.collection_mode, "enumValues":
                     "0:Disabled|1:Hide items which are in collections|2:Show collections and their items"},
                {"id": "enableCinemaTrailers", "type": "bool", "default": True, "value": True}]))
        elif (m := re.fullmatch(r"/library/(?:metadata|collections)/(\d+)(/children)?", path)) \
                and m.group(1) in lib.collections:
            c = lib.collections[m.group(1)]
            if m.group(2):
                rks = sorted(c["rks"], key=lambda r: lib.items[r]["title"].lower()) if c["smart"] \
                    else sorted(c["rks"], key=lambda r: lib.items[r]["year"])
                if q.get("sort") and not self.args.collection_ignores_sort:
                    rks = self.sorted_rks(rks, q)
                self.paged(rks, q, lib.metadata, scan_rows=len(lib.sections[c["sec"]]["rks"]) if c["smart"] else 0)
            else:
                self.delay()
                self._json(container(Metadata=[lib.collection_metadata(m.group(1))]))
        elif re.fullmatch(r"/library/collections/\d+/composite/\d+", path):
            time.sleep(self.args.rtt / 1000)
            self._send(PNG, "image/png")
        elif m := re.fullmatch(r"/hubs/sections/(\w+)", path):
            self.section_hubs(lib.sections.get(m.group(1)), q)
        elif m := re.fullmatch(r"/hubs/sections/(\w+)/(\w+)", path):
            sec = lib.sections[m.group(1)]
            items = self.hub_rks(m.group(2), sec)
            self.delay(scan_rows=len(sec["rks"]))
            start = int(q.get("X-Plex-Container-Start", 0) or 0)
            size = int(q.get("X-Plex-Container-Size", 50) or 50)
            page = items[start:start + size]
            self._json(container(Metadata=[lib.metadata(rk) for rk in page], totalSize=len(items)))
        elif path in ("/hubs", "/hubs/continueWatching"):
            self.delay(scan_rows=sum(len(s["rks"]) for s in lib.sections.values()) // 2)
            hubs = []
            for sec in lib.sections.values():
                rks = self.hub_rks("inProgress", sec)
                hubs.append(self.hub(sec, "inProgress", "Continue Watching", "continueWatching", rks, 12))
            if path == "/hubs":
                for sec in lib.sections.values():
                    rks = self.hub_rks("recentlyAdded", sec)
                    hubs.append(self.hub(sec, "recentlyAdded", f"Recently Added in {sec['title']}",
                                         f"{sec['type']}.recentlyadded", rks, 12))
            self._json(container(Hub=hubs))
        elif re.fullmatch(r"/hubs/home/\w+", path) or path == "/hubs/search" or path.startswith("/hubs/"):
            self.delay()
            self._json(container(Hub=[]))
        elif m := re.fullmatch(r"/library/metadata/(\d+)/extras", path):
            self.delay()
            self._json(container(Metadata=[lib.extra_metadata(x) for x in lib.extras.get(m.group(1), [])]))
        elif (m := re.fullmatch(r"/library/metadata/(\d+)(/children|/allLeaves)?", path)) \
                and (m.group(1) in lib.tree or m.group(1) in lib.extra_items
                     or (m.group(2) and m.group(1) in lib.tree_children)):
            self.delay()
            rk, sub = m.group(1), m.group(2)
            if rk in lib.extra_items:
                self._json(container(Metadata=[lib.extra_metadata(rk)]))
            elif sub == "/allLeaves":
                leaves = [e for s in lib.tree_children.get(rk, []) for e in lib.tree_children.get(s, [])]
                self._json(container(Metadata=[lib.tree_metadata(e) for e in leaves]))
            elif sub:
                self._json(container(Metadata=[lib.tree_metadata(c) for c in lib.tree_children.get(rk, [])]))
            else:
                self._json(container(Metadata=[lib.tree_metadata(rk)]))
        elif m := re.fullmatch(r"/library/metadata/(\d+)", path):
            self.delay()
            rk = m.group(1)
            if rk in lib.items:
                self._json(container(Metadata=[lib.metadata(rk, detail=True)]))
            else:
                self._json(container(), 404)
        elif re.fullmatch(r"/library/metadata/(\d+)/(children|allLeaves|similar|related)", path):
            self.delay()
            self._json(container(Metadata=[]))
        elif path == "/status/sessions/history/all":
            self.delay(scan_rows=20000)
            sec_id = q.get("librarySectionID")
            rks = [rk for rk in lib.history if not sec_id or lib.items[rk]["sec"] == sec_id]
            rks.sort(key=lambda r: -lib.items[r].get("lastViewedAt", 0))
            out = [{"historyKey": f"/status/sessions/history/{rk}", "key": f"/library/metadata/{rk}",
                    "ratingKey": rk, "librarySectionID": lib.items[rk]["sec"], "title": lib.items[rk]["title"],
                    "type": lib.items[rk]["kind"], "viewedAt": lib.items[rk]["lastViewedAt"], "accountID": 1}
                   for rk in rks]
            start = int(q.get("X-Plex-Container-Start", 0) or 0)
            size = int(q.get("X-Plex-Container-Size", 200) or 200)
            self._json(container(Metadata=out[start:start + size], totalSize=len(out)))
        elif path == "/media/providers":
            self.delay()
            self._json(container(MediaProvider=[]))
        else:
            self.delay()
            self._json(container())

    def filtered(self, sec, q):
        lib = self.lib
        rks = sec["rks"]
        genre = q.get("genre")
        if genre:
            wanted = set(genre.split(","))
            rks = [rk for rk in rks if any(lib.genre_ids[g] in wanted or g in wanted for g in lib.items[rk]["genres"])]
        if q.get("unwatched") == "1":
            rks = [rk for rk in rks if not lib.items[rk].get("watched")]
        if q.get("collection"):
            rks = []
        fc = q.get("firstCharacter")
        if fc:
            rks = [rk for rk in rks if lib.items[rk]["title"][:1].upper() == fc.upper()]
        return self.sorted_rks(rks, q)

    def sorted_rks(self, rks, q):
        lib = self.lib
        sort = (q.get("sort") or "titleSort").split(",")[0]
        field, _, direction = sort.partition(":")
        keyfuncs = {
            "addedAt": lambda rk: lib.items[rk]["addedAt"],
            "year": lambda rk: lib.items[rk]["year"],
            "originallyAvailableAt": lambda rk: lib.items[rk]["year"],
            "lastViewedAt": lambda rk: lib.items[rk].get("lastViewedAt", 0),
            "duration": lambda rk: lib.items[rk]["duration"],
            "audienceRating": lambda rk: lib.items[rk]["rating"],
        }
        keyfunc = keyfuncs.get(field, lambda rk: lib.items[rk]["title"].lower())
        return sorted(rks, key=keyfunc, reverse=direction == "desc")

    def section_all(self, sec, q):
        if not sec:
            self.delay()
            self._json(container(), 404)
            return
        rks = self.filtered(sec, q)
        if q.get("includeCollections") == "1" and str(self.args.collection_mode) == "1":
            rks = self.fold_collections(rks)
        start = int(q.get("X-Plex-Container-Start", 0) or 0)
        size = q.get("X-Plex-Container-Size")
        size = int(size) if size else len(rks)
        page = rks[start:start + size]
        self.delay(scan_rows=len(sec["rks"]), items=len(page))
        meta = [self.lib.collection_metadata(rk) if rk in self.lib.collections else self.lib.metadata(rk) for rk in page]
        self._json(container(Metadata=meta, totalSize=len(rks), offset=start,
                             librarySectionID=int(sec["key"]), librarySectionTitle=sec["title"]))

    def fold_collections(self, rks):
        """A manual collection's titles collapse into the collection, which
        takes the place of its first title in the sort."""
        out, seen = [], set()
        for rk in rks:
            crks = self.lib.item_collections.get(rk)
            if not crks:
                out.append(rk)
            elif crks[0] not in seen:
                seen.add(crks[0])
                out.append(crks[0])
        return out

    def paged(self, rks, q, render, scan_rows=0):
        start = int(q.get("X-Plex-Container-Start", 0) or 0)
        size = q.get("X-Plex-Container-Size")
        size = int(size) if size else len(rks)
        page = rks[start:start + size]
        self.delay(scan_rows=scan_rows, items=len(page))
        self._json(container(Metadata=[render(rk) for rk in page], totalSize=len(rks), offset=start))

    def photo_all(self, q):
        rks = self.photos.query(q)
        start = int(q.get("X-Plex-Container-Start", 0) or 0)
        size = q.get("X-Plex-Container-Size")
        size = int(size) if size else len(rks)
        page = rks[start:start + size]
        self.delay(scan_rows=len(self.photos.items), items=len(page))
        self._json(container(Metadata=[self.photos.metadata(rk) for rk in page], totalSize=len(rks), offset=start,
                             librarySectionID=3, librarySectionTitle="Photos", viewGroup="photo"))

    def hub_rks(self, name, sec):
        lib = self.lib
        if name == "inProgress":
            return [rk for rk in sec["rks"] if lib.items[rk].get("viewOffset")]
        if name == "recentlyAdded":
            return sorted(sec["rks"], key=lambda r: -lib.items[r]["addedAt"])[:50]
        if name == "topRated":
            return sorted(sec["rks"], key=lambda r: -lib.items[r]["rating"])[:50]
        if name == "recentlyReleased":
            return sorted(sec["rks"], key=lambda r: -lib.items[r]["year"])[:50]
        return []

    def hub(self, sec, name, title, identifier, rks, count):
        return {"hubKey": "", "key": f"/hubs/sections/{sec['key']}/{name}", "title": title,
                "type": sec["type"], "hubIdentifier": f"{identifier}.{sec['key']}", "context": f"hub.{identifier}",
                "size": min(len(rks), count), "more": len(rks) > count, "style": "shelf", "promoted": True,
                "librarySectionID": int(sec["key"]), "librarySectionTitle": sec["title"],
                "Metadata": [self.lib.metadata(rk) for rk in rks[:count]]}

    def section_hubs(self, sec, q):
        count = int(q.get("count", 12) or 12)
        # PMS builds each section hub with its own query over the section.
        names = [("inProgress", "Continue Watching", "inprogress"), ("recentlyAdded", "Recently Added", "recentlyadded"),
                 ("recentlyReleased", "Recently Released", "recentlyreleased"), ("topRated", "Top Rated", "toprated")]
        self.delay(scan_rows=len(sec["rks"]) * len(names))
        hubs = []
        for name, title, ident in names:
            rks = self.hub_rks(name, sec)
            if rks:
                hubs.append(self.hub(sec, name, title, f"{sec['type']}.{ident}", rks, count))
        self._json(container(Hub=hubs, librarySectionID=int(sec["key"])))


class FastServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self):
        import socketserver
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "127.0.0.1", self.server_address[1]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=47600)
    p.add_argument("--movies", type=int, default=60000)
    p.add_argument("--shows", type=int, default=12000)
    p.add_argument("--rtt", type=float, default=40, help="ms per request")
    p.add_argument("--scan-us", type=float, default=25, help="µs per section row scanned by a DB query")
    p.add_argument("--item-us", type=float, default=300, help="µs per returned item")
    p.add_argument("--db-workers", type=int, default=2)
    p.add_argument("--collection-mode", type=int, default=2, choices=(0, 1, 2),
                   help="sections' Collections pref: 0 disabled, 1 hide items in collections, 2 show both")
    p.add_argument("--collection-ignores-sort", action="store_true",
                   help="collection /children ignore sort= (exercises the app's on-device sort)")
    p.add_argument("--photos", type=int, default=0, help="photos (and clips) in a photo library; 0 = none")
    p.add_argument("--image-cache", default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                          "..", "build", "mock-photo-images"))
    args = p.parse_args()
    lib = Library(args.movies, args.shows)
    db = threading.BoundedSemaphore(args.db_workers)
    photos = PhotoLibrary(args.photos) if args.photos else None
    images = ImageBank(args.image_cache if photos else None)

    def make(role):
        return type("H", (Handler,), {"lib": lib, "role": role, "args": args, "db": db, "port": args.port,
                                      "photos": photos, "images": images})

    for role, port in (("plextv", args.port), ("pms", args.port + 1)):
        httpd = FastServer(("127.0.0.1", port), make(role))
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
    log(f"plex.tv on :{args.port}, PMS on :{args.port + 1} — {args.movies} movies, {args.shows} shows; "
        f"{args.photos} photos; rtt={args.rtt}ms scan={args.scan_us}µs/row item={args.item_us}µs db_workers={args.db_workers}")
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
