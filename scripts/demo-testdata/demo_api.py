"""Small API clients for plex-demo and jellyfin-demo (T-0 test data).

Credentials are read at runtime from ~/.config/jellyfin-demo/ and are never
printed. Only the standard library is used.
"""
import json
import os
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

CFG = Path(os.environ.get("DUSK_DEMO_CFG", Path.home() / ".config/jellyfin-demo"))
PLEX_URL = os.environ.get("DUSK_DEMO_PLEX", "http://storage:10012")
JF_URL = os.environ.get("DUSK_DEMO_JELLYFIN", "http://jellyfin-demo")
PLEX_MACHINE_ID = None  # looked up lazily
CLIENT_ID = "dusk-demo-testdata"
DEMO_USERS_ON_JF = ("duskcompare", "tester")


def secret(name):
    return (CFG / name).read_text().strip()


def _request(method, url, headers, body=None, raw=False):
    data = None
    if body is not None:
        data = json.dumps(body).encode() if not isinstance(body, bytes) else body
        headers = {**headers, "Content-Type": "application/json"}
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            payload = r.read()
            status = r.status
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"{method} {url.split('?')[0]} -> HTTP {e.code}: {e.read()[:300]!r}") from None
    if raw:
        return status, payload
    if not payload:
        return None
    try:
        return json.loads(payload)
    except ValueError:
        return payload.decode(errors="replace")


# --------------------------------------------------------------------- Plex
class Plex:
    def __init__(self, token):
        self.token = token

    def req(self, method, path, params=None, raw=False):
        q = dict(params or {})
        url = PLEX_URL + path + ("?" + urllib.parse.urlencode(q, doseq=True) if q else "")
        h = {"Accept": "application/json", "X-Plex-Token": self.token,
             "X-Plex-Client-Identifier": CLIENT_ID, "X-Plex-Product": "Dusk T-0"}
        return _request(method, url, h, raw=raw)

    def get(self, path, **params):
        return self.req("GET", path, params)

    def mc(self, path, **params):
        return (self.get(path, **params) or {}).get("MediaContainer", {})

    def machine_id(self):
        return self.mc("/identity")["machineIdentifier"]

    def section(self, title):
        for d in self.mc("/library/sections").get("Directory", []):
            if d["title"] == title:
                return d
        return None

    def items(self, section_key, type_=None):
        p = {"includeGuids": 1}
        if type_:
            p["type"] = type_
        return self.mc(f"/library/sections/{section_key}/all", **p).get("Metadata", [])

    def uri(self, rating_keys):
        return (f"server://{self.machine_id()}/com.plexapp.plugins.library/library/metadata/"
                + ",".join(str(k) for k in rating_keys))


def plex_owner():
    return Plex(secret("plex-token"))


def plex_user_server_token(account_token_file):
    """Server access token for a shared user, from plex.tv resources."""
    owner = plex_owner()
    mid = owner.machine_id()
    url = "https://plex.tv/api/v2/resources?includeHttps=1"
    h = {"Accept": "application/json", "X-Plex-Token": secret(account_token_file),
         "X-Plex-Client-Identifier": CLIENT_ID, "X-Plex-Product": "Dusk T-0"}
    for r in _request("GET", url, h):
        if r.get("clientIdentifier") == mid:
            return r["accessToken"]
    raise RuntimeError("plex-demo not in the user's resources")


def plex_tv(method, path, token, body=None, accept="application/json"):
    h = {"Accept": accept, "X-Plex-Token": token, "X-Plex-Client-Identifier": CLIENT_ID,
         "X-Plex-Product": "Dusk T-0"}
    return _request(method, "https://plex.tv" + path, h, body=body, raw=accept != "application/json")


# ----------------------------------------------------------------- Jellyfin
class Jellyfin:
    def __init__(self, user, password):
        self.auth = ('MediaBrowser Client="Dusk T-0", Device="demo-testdata", '
                     'DeviceId="dusk-demo-testdata", Version="1.0"')
        r = _request("POST", JF_URL + "/Users/AuthenticateByName",
                     {"Authorization": self.auth}, {"Username": user, "Pw": password})
        self.token = r["AccessToken"]
        self.user_id = r["User"]["Id"]

    def req(self, method, path, params=None, body=None, raw=False):
        q = {k: v for k, v in (params or {}).items() if v is not None}
        url = JF_URL + path + ("?" + urllib.parse.urlencode(q, doseq=True) if q else "")
        h = {"Authorization": f'{self.auth}, Token="{self.token}"', "Accept": "application/json"}
        return _request(method, url, h, body=body, raw=raw)

    def get(self, path, **params):
        return self.req("GET", path, params)

    def post(self, path, body=None, **params):
        return self.req("POST", path, params, body=body if body is not None else b"")

    def items(self, user_id=None, **params):
        p = {"userId": user_id or self.user_id, "recursive": "true", "fields": "Path,ProviderIds"}
        p.update(params)
        return self.get("/Items", **p)["Items"]

    def user(self, name):
        for u in self.get("/Users"):
            if u["Name"] == name:
                return u
        return None

    def library(self, name):
        for f in self.get("/Library/VirtualFolders"):
            if f["Name"] == name:
                return f
        return None

    def by_path(self, path, types="Movie,Episode,Series,Video,Photo"):
        """Map one /data/... path to its Jellyfin item."""
        for it in self.items(includeItemTypes=types, searchTerm=Path(path).stem[:40]):
            if it.get("Path") == path:
                return it
        for it in self.items(includeItemTypes=types):  # slow fallback
            if it.get("Path") == path:
                return it
        raise RuntimeError(f"Jellyfin has no item at {path}")


def jf_admin():
    return Jellyfin("marvinvr", secret("admin-password"))


def jf_compare():
    return Jellyfin("duskcompare", secret("compare-password"))
