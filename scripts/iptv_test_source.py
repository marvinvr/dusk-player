#!/usr/bin/env python3
"""Test IPTV source for Dusk: an M3U of Apple's public unencrypted HLS
samples plus an XMLTV guide built around the current time. Playlist and guide
require `Authorization: Bearer dusk-test-token` (exercises the source header).
Catch-up: channels one and two carry the standard `catchup="default"
catchup-days="7" catchup-source=".../catchup/<id>.m3u8?start={utc}&end={utcend}
&duration={duration}"` attributes (channel three has none, so its past is info
only); the guide reaches seven days back. A catch-up request is logged with its
substituted times and redirected (302) to Apple's VOD sample, which ends.
Logos (any PNGs named logo-one/two/three.png) are served without auth from
./www next to this script; missing logos just show the placeholder.

Usage: python3 scripts/iptv_test_source.py [port]   (default 47830)
See docs/iptv.md → Simulator verification."""
import datetime as dt
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 47830
HOST = f"http://127.0.0.1:{PORT}"
TOKEN = "Bearer dusk-test-token"
WWW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "www")

APPLE = "https://devstreaming-cdn.apple.com/videos/streaming/examples"
CHANNELS = [
    ("test.one", "Test News", "1", "one", f"{APPLE}/bipbop_16x9/bipbop_16x9_variant.m3u8"),
    ("test.two", "Test Sports", "2", "two", f"{APPLE}/img_bipbop_adv_example_fmp4/master.m3u8"),
    ("test.three", "Test Cinema", "3", "three", f"{APPLE}/bipbop_4x3/bipbop_4x3_variant.m3u8"),
]
CATCHUP = {"test.one", "test.two"}
CATCHUP_TARGET = f"{APPLE}/bipbop_4x3/bipbop_4x3_variant.m3u8"
SHOWS = {
    "test.one": [("Morning Briefing", "Headlines and weather."), ("Business Hour", "Markets and companies."),
                 ("World Report", "Stories from around the globe."), ("Evening News", None)],
    "test.two": [("Match of the Week", "Live coverage from the stadium."), ("Highlights", None),
                 ("Studio Talk", "Analysis and interviews."), ("Late Kick-Off", None)],
    "test.three": [("Classic Feature", "A restored favourite."), ("Short Films", None),
                   ("Director's Choice", None), ("Night Movie", None)],
}


def playlist():
    lines = [f'#EXTM3U url-tvg="{HOST}/guide.xml"']
    for tvg_id, name, number, logo, url in CHANNELS:
        catchup = ""
        if tvg_id in CATCHUP:
            catchup = (f' catchup="default" catchup-days="7" catchup-source="{HOST}/catchup/{tvg_id}.m3u8'
                       '?start={utc}&end={utcend}&duration={duration}"')
        lines.append(f'#EXTINF:-1 tvg-id="{tvg_id}" tvg-name="{name}" tvg-logo="{HOST}/logo-{logo}.png" '
                     f'group-title="Test" tvg-chno="{number}"{catchup},{name}')
        lines.append(url)
    return "\n".join(lines) + "\n"


def guide():
    now = dt.datetime.now(dt.timezone.utc).replace(minute=0, second=0, microsecond=0)
    # A week back for catch-up: programmes alternate 60 / 90 minutes, so a
    # week is 134 of them; the loop below runs from there to ~2 days ahead.
    start = now - dt.timedelta(minutes=75 * 134)
    fmt = lambda t: t.strftime("%Y%m%d%H%M%S +0000")
    out = ['<?xml version="1.0" encoding="UTF-8"?>', "<tv>"]
    for tvg_id, name, _, logo, _ in CHANNELS:
        out.append(f'<channel id="{tvg_id}"><display-name>{name}</display-name>'
                   f'<icon src="{HOST}/logo-{logo}.png"/></channel>')
    for tvg_id, *_ in CHANNELS:
        t = start
        for i in range(134 + 36):
            title, desc = SHOWS[tvg_id][i % 4]
            stop = t + dt.timedelta(minutes=90 if i % 2 else 60)
            desc_xml = f"<desc>{desc}</desc>" if desc else ""
            out.append(f'<programme start="{fmt(t)}" stop="{fmt(stop)}" channel="{tvg_id}">'
                       f"<title>{title.replace('&', '&amp;')}</title>{desc_xml}</programme>")
            t = stop
    out.append("</tv>")
    return "\n".join(out)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path.startswith("/catchup/"):
            from urllib.parse import parse_qs, urlparse
            query = parse_qs(urlparse(self.path).query)
            fmt = lambda key: dt.datetime.fromtimestamp(int(query[key][0]), dt.timezone.utc).isoformat() \
                if key in query and query[key][0].isdigit() else "?"
            sys.stderr.write(f"[iptv] catch-up {path} start={fmt('start')} end={fmt('end')} "
                             f"duration={query.get('duration', ['?'])[0]}s\n")
            if self.headers.get("Authorization") != TOKEN:
                return self.send(401, b"unauthorized", "text/plain")
            self.send_response(302)
            self.send_header("Location", CATCHUP_TARGET)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path in ("/playlist.m3u", "/guide.xml"):
            if self.headers.get("Authorization") != TOKEN:
                return self.send(401, b"unauthorized", "text/plain")
            body = playlist() if path == "/playlist.m3u" else guide()
            return self.send(200, body.encode(), "audio/x-mpegurl" if path.endswith("m3u") else "application/xml")
        file = os.path.join(WWW, os.path.basename(path))
        if os.path.isfile(file):
            with open(file, "rb") as f:
                return self.send(200, f.read(), "image/png")
        self.send(404, b"not found", "text/plain")

    def send(self, status, body, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("[iptv] %s %s\n" % (self.headers.get("Authorization") and "auth" or "-", fmt % args))


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
