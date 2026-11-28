#!/usr/bin/env python3
"""Records the Plex side of the provider contract fixtures
(DuskTests/Fixtures/PlexContract/plex-contract-*.json).

    python3 -I DuskTests/Fixtures/PlexContract/record_plex_contract_fixtures.py

The Jellyfin side is DuskTests/Fixtures/Jellyfin (scripts/jellyfin/record_fixtures.sh).
Both demo servers read the same /data folder, so each title is matched to its
Jellyfin fixture by file path, not by title.

Rules, because plex-demo is shared and the repo is public:
- Read-only GETs as the comparison user (duskcompare), with the same query
  Dusk sends for a detail page (includeMarkers=1, includeGuids=1).
- The server's identity (machineIdentifier, librarySectionUUID) is replaced by
  a placeholder; the script fails and writes nothing when a token or the real
  machine identifier would still appear in a fixture.

Credentials (never printed): ~/.config/jellyfin-demo/compare-plex-token and
plex-token (only to look up the server's machine identifier).
"""
import json
import os
import sys
import urllib.parse
import urllib.request
from pathlib import Path

CFG = Path(os.environ.get("DUSK_DEMO_CFG", Path.home() / ".config/jellyfin-demo"))
PLEX_URL = os.environ.get("DUSK_DEMO_PLEX", "http://storage:10012").rstrip("/")
OUT = Path(__file__).resolve().parent
JELLYFIN = OUT.parent / "Jellyfin"
CLIENT_ID = "dusk-contract-fixture-recorder"
MACHINE_PLACEHOLDER = "c0ffeec0ffeec0ffeec0ffeec0ffeec0"

# fixture name → Jellyfin fixture holding the same file
TITLES = {
    "knives-out": "jellyfin-item-knives-out.json",
    "dune-part-two": "jellyfin-item-dune-part-two.json",
    "the-office-s01e01": "jellyfin-item-the-office-s01e01.json",
}


def secret(name):
    return (CFG / name).read_text().strip()


def get(url, token):
    req = urllib.request.Request(url, headers={
        "Accept": "application/json", "X-Plex-Token": token,
        "X-Plex-Client-Identifier": CLIENT_ID, "X-Plex-Product": "Dusk Fixture Recorder",
    })
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def server(path, token, **params):
    q = "?" + urllib.parse.urlencode(params) if params else ""
    return get(PLEX_URL + path + q, token).get("MediaContainer", {})


def main():
    owner = secret("plex-token")
    machine_id = server("/identity", owner)["machineIdentifier"]
    token = None
    for r in get("https://plex.tv/api/v2/resources?includeHttps=1", secret("compare-plex-token")):
        if r.get("clientIdentifier") == machine_id:
            token = r["accessToken"]
    if not token:
        sys.exit("plex-demo is not in the comparison user's resources")

    # Every video file the user can see, by path.
    by_path = {}
    for section in server("/library/sections", token).get("Directory", []):
        kind = {"movie": 1, "show": 4}.get(section["type"])
        if not kind:
            continue
        items = server(f"/library/sections/{section['key']}/all", token, type=kind).get("Metadata", [])
        for item in items:
            for media in item.get("Media", []):
                for part in media.get("Part", []):
                    by_path.setdefault(part.get("file"), item["ratingKey"])

    secrets = {owner, token, machine_id}
    written = {}
    for name, jellyfin_fixture in TITLES.items():
        path = json.loads((JELLYFIN / jellyfin_fixture).read_text())["Path"]
        rating_key = by_path.get(path)
        if not rating_key:
            sys.exit(f"{name}: no Plex item for {path}")
        payload = get(f"{PLEX_URL}/library/metadata/{rating_key}?includeMarkers=1&includeGuids=1", token)
        container = payload.get("MediaContainer", {})
        for key in ("machineIdentifier", "librarySectionUUID"):
            if key in container:
                container[key] = MACHINE_PLACEHOLDER
        for item in container.get("Metadata", []):
            if "librarySectionUUID" in item:
                item["librarySectionUUID"] = MACHINE_PLACEHOLDER
        text = json.dumps(payload, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
        if any(s and s in text for s in secrets):
            sys.exit(f"{name}: a token or the machine identifier is still in the fixture")
        written[OUT / f"plex-contract-{name}.json"] = text

    for file, text in written.items():
        file.write_text(text)
        print(f"wrote {file.name}")


if __name__ == "__main__":
    main()
