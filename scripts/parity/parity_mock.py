#!/usr/bin/env python3
"""Deterministic Plex mock for the Phase 0 gate (G2 request log, G3 pixels).

Wraps `scripts/mock_large_plex.py` without editing it:

  * the mock's clock (`NOW`) is --epoch, the mock's start time by default:
    every `addedAt` / `lastViewedAt` keeps the same age relative to the app's
    clock, and gate.py rewrites epoch-like numbers in requests to day offsets
    (`<now-30d>`) before comparing;
  * every request (plex.tv and PMS, images included, path and query in full)
    is appended to --log as one JSON line;
  * routes the large-library mock leaves empty get small fixed answers so the
    scripted screens are not empty states: `/hubs/search`, `/playlists*`;
  * images are solid colours derived from the image's identity (rating key and
    thumb/art/composite), never from the requested size, so a screen that
    starts showing a different image changes colour in the screenshot. Photo
    library images still come from the mock's seeded ImageMagick bank.

Usage: parity_mock.py --port 47800 --log requests.jsonl --image-cache DIR [--epoch N]
"""
import argparse
import hashlib
import json
import os
import re
import struct
import sys
import threading
import time
import zlib
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import mock_large_plex as base  # noqa: E402

LOG_LOCK = threading.Lock()
LOG_FILE = None

PLAYLISTS = [
    # rating key, title, smart, (section, first index, count)
    ("850001", "Weekend Marathon", False, ("1", 0, 12)),
    ("850002", "Short Evenings", True, ("1", 20, 8)),
]


def solid_png(rgb, width=4, height=4):
    raw = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


PNG_CACHE = {}


def identity_png(source):
    """Same colour for the same image identity, whatever size was asked for."""
    identity = re.sub(r"/\d{9,}(?=/|$)", "", urlparse(source).path)
    if identity not in PNG_CACHE:
        digest = hashlib.sha1(identity.encode()).digest()
        # Keep colours mid-range so text over artwork stays readable.
        PNG_CACHE[identity] = solid_png([48 + b % 160 for b in digest[:3]])
    return PNG_CACHE[identity]


class ParityHandler(base.Handler):
    def do_GET(self):
        if LOG_FILE:
            line = json.dumps({"time": round(time.time(), 3), "role": self.role, "method": self.command,
                               "target": self.path})
            with LOG_LOCK:
                LOG_FILE.write(line + "\n")
                LOG_FILE.flush()
        super().do_GET()

    def pms(self, path, q):
        lib = self.lib
        if path.startswith("/photo") or re.fullmatch(r"/library/metadata/\d+/(thumb|art|composite)/\d+", path) \
                or re.fullmatch(r"/library/(sections|collections)/\w+/composite/\d+", path) \
                or re.fullmatch(r"/playlists/\d+/composite/\d+", path):
            source = q.get("url", path)
            m = re.search(r"/library/(?:metadata|parts)/(\d+)", source)
            if m and self.photos and (m.group(1) in self.photos.items or m.group(1) in lib.extra_items
                                      or m.group(1) in lib.tree):
                return super().pms(path, q)
            self._send(identity_png(source), "image/png")
        elif path == "/hubs/search":
            self.search(q)
        elif path == "/playlists":
            if self.command == "GET":
                self._json(base.container(Metadata=[self.playlist(p) for p in PLAYLISTS]))
            else:
                self._json(base.container())
        elif m := re.fullmatch(r"/playlists/(\d+)(/items)?", path):
            playlist = next((p for p in PLAYLISTS if p[0] == m.group(1)), None)
            if not playlist:
                self._json(base.container(), 404)
            elif m.group(2):
                self._json(base.container(Metadata=self.playlist_items(playlist), totalSize=playlist[3][2]))
            else:
                self._json(base.container(Metadata=[self.playlist(playlist)]))
        else:
            super().pms(path, q)

    def search(self, q):
        lib = self.lib
        needle = (q.get("query") or "").lower()
        limit = int(q.get("limit", 10) or 10)
        hubs = []
        for sec, kind, title in (("1", "movie", "Movies"), ("2", "show", "Shows")):
            rks = [rk for rk in lib.sections[sec]["rks"] if needle and needle in lib.items[rk]["title"].lower()]
            rks = sorted(rks, key=lambda r: lib.items[r]["title"].lower())[:limit]
            hubs.append({"hubKey": "", "key": "", "title": title, "type": kind, "hubIdentifier": kind,
                         "context": "", "size": len(rks), "more": False, "style": "shelf",
                         "Metadata": [lib.metadata(rk) for rk in rks]})
        self._json(base.container(Hub=hubs))

    def playlist_rks(self, playlist):
        sec, first, count = playlist[3]
        return self.lib.sections[sec]["rks"][first:first + count]

    def playlist(self, playlist):
        rk, title, smart, _ = playlist
        rks = self.playlist_rks(playlist)
        return {"ratingKey": rk, "key": f"/playlists/{rk}/items", "guid": f"com.plexapp.agents.none://{rk}",
                "type": "playlist", "title": title, "summary": f"{title}: a synthetic playlist.",
                "smart": smart, "playlistType": "video", "composite": f"/playlists/{rk}/composite/{base.NOW}",
                "duration": sum(self.lib.items[r]["duration"] for r in rks), "leafCount": len(rks),
                "addedAt": base.NOW - 86400, "updatedAt": base.NOW - 3600}

    def playlist_items(self, playlist):
        out = []
        for i, rk in enumerate(self.playlist_rks(playlist)):
            md = self.lib.metadata(rk)
            if not playlist[2]:
                md["playlistItemID"] = 9000 + i
            out.append(md)
        return out


def main():
    global LOG_FILE
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", type=int, required=True, help="plex.tv mock; the PMS listens on port + 1")
    p.add_argument("--log", required=True, help="JSON-lines request log (appended)")
    p.add_argument("--epoch", type=int, default=int(time.time()),
                   help="the mock's NOW (default: start time). Data ages stay relative to it, so the app's own "
                        "clock-relative logic (history windows, recently added) sees the same library every day")
    p.add_argument("--movies", type=int, default=300)
    p.add_argument("--shows", type=int, default=120)
    p.add_argument("--photos", type=int, default=150)
    p.add_argument("--image-cache", required=True, help="seeded photo bank directory (reused across runs)")
    args = p.parse_args()

    base.NOW = args.epoch
    LOG_FILE = open(args.log, "a", buffering=1)
    # No latency: the gate compares what is requested, not when.
    mock_args = argparse.Namespace(rtt=0, scan_us=0, item_us=0, collection_mode=2, collection_ignores_sort=False)
    lib = base.Library(args.movies, args.shows)
    db = threading.BoundedSemaphore(4)
    photos = base.PhotoLibrary(args.photos) if args.photos else None
    images = base.ImageBank(args.image_cache if photos else None)
    if photos and not images.paths:
        sys.exit("ImageMagick (`magick`) is needed for the photo library images")

    def make(role):
        return type("H", (ParityHandler,), {"lib": lib, "role": role, "args": mock_args, "db": db,
                                            "port": args.port, "photos": photos, "images": images})

    servers = []
    for role, port in (("plextv", args.port), ("pms", args.port + 1)):
        httpd = base.FastServer(("127.0.0.1", port), make(role))
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        servers.append(httpd)
    print(f"parity mock ready on :{args.port}/:{args.port + 1} epoch={args.epoch}", flush=True)
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
