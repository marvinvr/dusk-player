#!/usr/bin/env python3
"""Synthetic Xtream Codes panel for Dusk: a huge `m3u_plus` playlist served
slowly, plus a working live channel in both Xtream output formats. No real
provider data; every name, id and logo is generated.

- `GET /get.php?username=dusk&password=test&type=m3u_plus&output=ts`
  waits `--delay` seconds before the first byte (Xtream panels build the list
  on request and are that slow), then sends `--live` live channels
  (`/live/<user>/<pass>/<id>.ts`), `--movies` movies (`/movie/…/<id>.mkv`) and
  `--series` series episodes (`/series/…/<id>.mkv`), padded to roughly
  `--megabytes` MB. `output=m3u8` gives `.m3u8` live URLs instead.
- `GET /live/<user>/<pass>/<id>.ts`: a raw live MPEG-TS stream (silent
  test pattern from ffmpeg, real time), what `output=ts` hands a player.
- `GET /live/<user>/<pass>/<id>.m3u8`: the same channel as live HLS (one
  shared ffmpeg HLS encoder; segments under the same directory), the way
  Xtream serves HLS at the same path with `.m3u8`.
- Movie / series URLs answer 404: Dusk must never list them.

Needs ffmpeg on PATH for the streams. Usage:
  python3 scripts/iptv_xtream_test_source.py [--port 47890] [--delay 45]
      [--live 12000] [--movies 30000] [--series 18000] [--megabytes 40]
See docs/iptv.md → Verification."""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, default=47890)
parser.add_argument("--delay", type=float, default=45)
parser.add_argument("--live", type=int, default=12000)
parser.add_argument("--movies", type=int, default=30000)
parser.add_argument("--series", type=int, default=18000)
parser.add_argument("--megabytes", type=float, default=40)
parser.add_argument("--epg-channels", type=int, default=0,
                    help="advertise url-tvg and serve /xmltv.php for this many live channels (+ as many unlisted)")
parser.add_argument("--epg-days", type=float, default=4)
args = parser.parse_args()

HOST = f"http://127.0.0.1:{args.port}"
USER, PASS = "dusk", "test"
FFMPEG = shutil.which("ffmpeg")
SOURCE = ["-re", "-f", "lavfi", "-i", "testsrc=size=640x360:rate=25",
          "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000",
          "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-g", "50",
          "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "64k"]


def playlist(output):
    total = args.live + args.movies + args.series
    # Pad names so the file lands near --megabytes (Xtream VOD names and TMDB
    # logo URLs are long in real lists).
    base = 160
    pad = max(0, int(args.megabytes * 1_000_000 / max(total, 1)) - base) // 2
    filler = ("x" * pad)
    ext = "m3u8" if output in ("m3u8", "hls") else "ts"
    epg = f' url-tvg="{HOST}/xmltv.php?username={USER}&password={PASS}"' if args.epg_channels else ""
    lines = [f"#EXTM3U{epg}"]
    countries = ["US", "UK", "DE", "FR", "IT", "ES", "NL", "CH"]
    for i in range(args.live):
        cc = countries[i % len(countries)]
        lines.append(f'#EXTINF:-1 tvg-id="ch{i}.{cc.lower()}" tvg-name="{cc}| Channel {i} HD" '
                     f'tvg-logo="{HOST}/logos/live/{i}-{filler}.png" group-title="{cc} | General",{cc}| Channel {i} HD')
        lines.append(f"{HOST}/live/{USER}/{PASS}/{100000 + i}.{ext}")
    for i in range(args.movies):
        lines.append(f'#EXTINF:-1 tvg-id="" tvg-name="Movie {i} ({1960 + i % 60}) {filler}" '
                     f'tvg-logo="{HOST}/logos/movie/{i}-{filler}.jpg" group-title="VOD | Genre {i % 40}",'
                     f'Movie {i} ({1960 + i % 60})')
        lines.append(f"{HOST}/movie/{USER}/{PASS}/{200000 + i}.mkv")
    for i in range(args.series):
        lines.append(f'#EXTINF:-1 tvg-id="" tvg-name="Series {i // 20} S01 E{i % 20:02d} {filler}" '
                     f'tvg-logo="{HOST}/logos/series/{i}-{filler}.jpg" group-title="SERIES | Genre {i % 30}",'
                     f'Series {i // 20} S01 E{i % 20:02d}')
        lines.append(f"{HOST}/series/{USER}/{PASS}/{300000 + i}.mkv")
    return ("\n".join(lines) + "\n").encode()


PLAYLISTS = {}
EPG_LOCK = threading.Lock()
EPG_PATH = None


def epg_file():
    """Hourly programmes from a day back to --epg-days ahead, for the first
    --epg-channels live channels and as many channels the playlist never
    lists (Xtream EPGs cover more than the user's package). Built once."""
    global EPG_PATH
    with EPG_LOCK:
        if EPG_PATH:
            return EPG_PATH
        import datetime as dt
        path = os.path.join(HLS_DIR, "xmltv.xml")
        now = dt.datetime.now(dt.timezone.utc).replace(minute=0, second=0, microsecond=0)
        start = now - dt.timedelta(days=1)
        hours = int((args.epg_days + 1) * 24)
        countries = ["us", "uk", "de", "fr", "it", "es", "nl", "ch"]
        ids = [f"ch{i}.{countries[i % 8]}" for i in range(args.epg_channels)]
        ids += [f"unlisted{i}.xx" for i in range(args.epg_channels)]
        fmt = "%Y%m%d%H%M%S +0000"
        with open(path, "w") as f:
            f.write('<?xml version="1.0" encoding="UTF-8"?>\n<tv generator-info-name="dusk-test">\n')
            for cid in ids:
                f.write(f'<channel id="{cid}"><display-name>{cid}</display-name></channel>\n')
            for cid in ids:
                for h in range(hours):
                    a = (start + dt.timedelta(hours=h)).strftime(fmt)
                    b = (start + dt.timedelta(hours=h + 1)).strftime(fmt)
                    f.write(f'<programme start="{a}" stop="{b}" channel="{cid}"><title>Show {h} on {cid}</title>'
                            f'<desc>Synthetic programme description number {h} for channel {cid}, '
                            f'long enough to look like a real EPG entry.</desc></programme>\n')
            f.write("</tv>\n")
        EPG_PATH = path
        return path
HLS_DIR = tempfile.mkdtemp(prefix="dusk-xtream-hls-")
HLS_LOCK = threading.Lock()
HLS_PROCESS = None


def start_hls():
    global HLS_PROCESS
    with HLS_LOCK:
        if HLS_PROCESS and HLS_PROCESS.poll() is None:
            return
        HLS_PROCESS = subprocess.Popen(
            [FFMPEG, "-loglevel", "error", *SOURCE, "-f", "hls", "-hls_time", "2", "-hls_list_size", "6",
             "-hls_flags", "delete_segments", "-hls_segment_filename", os.path.join(HLS_DIR, "seg%05d.ts"),
             os.path.join(HLS_DIR, "index.m3u8")],
            stdin=subprocess.DEVNULL)
    deadline = time.time() + 15
    while time.time() < deadline and not os.path.exists(os.path.join(HLS_DIR, "index.m3u8")):
        time.sleep(0.2)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), fmt % a))

    def send_plain(self, status, body=b"", ctype="text/plain"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        try:
            if url.path == "/xmltv.php":
                path = epg_file()
                self.log_message("xmltv: %.1f MB", os.path.getsize(path) / 1e6)
                self.serve_file(path, "application/xml")
            elif url.path == "/get.php":
                self.serve_playlist(urllib.parse.parse_qs(url.query))
            elif len(parts) == 4 and parts[0] == "live" and parts[3].startswith("seg"):
                self.serve_file(os.path.join(HLS_DIR, os.path.basename(parts[3])), "video/mp2t")
            elif len(parts) == 4 and parts[0] == "live" and parts[3].endswith(".m3u8"):
                start_hls()
                self.serve_file(os.path.join(HLS_DIR, "index.m3u8"), "application/vnd.apple.mpegurl")
            elif len(parts) == 4 and parts[0] == "live" and parts[3].endswith(".ts"):
                self.serve_ts()
            else:
                self.send_plain(404, b"not found")
        except (BrokenPipeError, ConnectionResetError):
            pass

    def serve_playlist(self, query):
        if query.get("username") != [USER] or query.get("password") != [PASS]:
            return self.send_plain(401, b"bad credentials")
        output = (query.get("output") or ["ts"])[0]
        if output not in PLAYLISTS:
            PLAYLISTS[output] = playlist(output)
        body = PLAYLISTS[output]
        self.log_message("playlist %s: %.1f MB, first byte in %ss", output, len(body) / 1e6, args.delay)
        time.sleep(args.delay)
        self.send_response(200)
        self.send_header("Content-Type", "audio/x-mpegurl")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        view = memoryview(body)
        for start in range(0, len(body), 256 * 1024):
            self.wfile.write(view[start:start + 256 * 1024])

    def serve_file(self, path, ctype):
        try:
            with open(path, "rb") as f:
                body = f.read()
        except FileNotFoundError:
            return self.send_plain(404, b"not found")
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def serve_ts(self):
        # Live: no length, closes when the player hangs up.
        self.send_response(200)
        self.send_header("Content-Type", "video/mp2t")
        self.send_header("Connection", "close")
        self.end_headers()
        process = subprocess.Popen([FFMPEG, "-loglevel", "error", *SOURCE, "-f", "mpegts", "-"],
                                   stdout=subprocess.PIPE, stdin=subprocess.DEVNULL)
        try:
            while chunk := process.stdout.read(188 * 64):
                self.wfile.write(chunk)
        finally:
            process.kill()
            self.close_connection = True


if __name__ == "__main__":
    print(f"Xtream test panel on {HOST}/get.php?username={USER}&password={PASS}&type=m3u_plus&output=ts "
          f"(first byte after {args.delay}s)", flush=True)
    try:
        ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
    finally:
        if HLS_PROCESS:
            HLS_PROCESS.kill()
        shutil.rmtree(HLS_DIR, ignore_errors=True)
