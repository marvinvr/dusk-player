#!/usr/bin/env python3
"""Phase 0 gate harness (docs/jellyfin/05-plan.md §3): G2 request log, G3 pixels.

  gate.py screens record   # rebuild the committed baseline (pre-refactor tree only)
  gate.py screens check    # compare this tree against the baseline; non-zero on any difference
  gate.py screens repeat   # fresh runs compared with each other (harness determinism)
  gate.py smoke record|check|repeat   # G6, the same driver against plex-demo (smoke_proxy.py)

For every platform (iphone, ipad, tv) the Debug app is built, a disposable
simulator of the exact device type and runtime in baseline/manifest.json is
created, and every scripted screen runs isolated: a fresh parity mock
(parity_mock.py, own port, own request log), a fresh app install (empty
container), a screenshot-mode launch, a wait until the app has sent no
request for a while, a screenshot. The simulator is deleted afterwards.

G2: per screen, the multiset of `METHOD path?sorted-query` with tokens,
client/session ids and device fields stripped must equal the baseline. The
baseline merges 3 runs: a line whose count differed between them (the app
fetches it a racy number of times) keeps its recorded range and only gets a
note outside it; every other count must match exactly.
G3: per screen, the screenshot must match the baseline within
manifest.tolerance (per-channel fuzz, then a maximum share of differing
pixels).

Output (logs, screenshots, normalised requests, diff images) goes to
--out (default build/parity/runs/<timestamp>).
"""
import argparse
import contextlib
import datetime
import json
import random
import re
import os
import shutil
import signal
import socket
import subprocess
import sys
import time
import uuid
from pathlib import Path
from urllib.parse import parse_qsl, urlparse

ROOT = Path(__file__).resolve().parents[2]
HERE = ROOT / "scripts" / "parity"
SUITES = {
    # G2/G3: the parity mock; the baseline is committed.
    "screens": {"manifest": HERE / "baseline" / "manifest.json", "baseline": HERE / "baseline"},
    # G6: plex-demo through smoke_proxy.py. Its baseline shows a shared live
    # server (real titles, server ids), so it stays on the machine, out of git.
    "smoke": {"manifest": HERE / "smoke_manifest.json",
              "baseline": Path.home() / ".cache" / "dusk-parity" / "smoke-baseline"},
}
BUNDLE_ID = "com.dusk-player.app"

# Query parameters that differ per install or per launch. Only these: client
# constants (product, platform, features…) travel in headers today, and should
# one move into a query it must be compared.
STRIPPED_QUERY = {
    "x-plex-token", "x-plex-client-identifier", "x-plex-session-identifier", "x-plex-session-id",
    "x-plex-device-name", "session",
}

PLATFORMS = {
    "iphone": {"sdk": "iphonesimulator", "scheme": "Dusk", "app_dir": "Debug-iphonesimulator",
               "destination": "generic/platform=iOS Simulator"},
    "ipad": {"sdk": "iphonesimulator", "scheme": "Dusk", "app_dir": "Debug-iphonesimulator",
             "destination": "generic/platform=iOS Simulator"},
    "tv": {"sdk": "appletvsimulator", "scheme": "Dusk-tvOS", "app_dir": "Debug-appletvsimulator",
           "destination": "generic/platform=tvOS Simulator"},
}


def log(message):
    print(message, flush=True)


def run(cmd, timeout=120, check=True, **kwargs):
    return subprocess.run(cmd, check=check, timeout=timeout, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kwargs)


def free_port_pair():
    """An even port P with P and P + 1 free, below the ephemeral range (macOS
    hands ephemeral ports out sequentially, so probing port 0 walks into 65535)."""
    rng = random.Random()
    for _ in range(500):
        port = rng.randrange(20000, 45000, 2)
        with contextlib.ExitStack() as stack:
            try:
                for candidate in (port, port + 1):
                    s = stack.enter_context(socket.socket())
                    s.bind(("127.0.0.1", candidate))
                return port
            except OSError:
                continue
    raise RuntimeError("no free port pair")


# -- normalisation -------------------------------------------------------------

EPOCH_LIKE = re.compile(r"(?<!\d)1\d{9}(?!\d)")


def relative_times(text, at, fold=False):
    """Unix times within ~2 years of the request become day offsets from it:
    the mock's NOW in image paths, the app's `viewedAt>=` windows. With
    `fold` (a live server, whose timestamps are absolute) every one is `<t>`."""
    def replace(match):
        if fold:
            return "<t>"
        delta = int(match.group(0)) - at
        if abs(delta) > 800 * 86400:
            return match.group(0)
        days = round(delta / 86400)
        return f"<now{days:+d}d>" if days else "<now>"
    return EPOCH_LIKE.sub(replace, text)


def normalise_target(method, target, at, fold_times=False):
    url = urlparse(target)
    query = sorted((k, v) for k, v in parse_qsl(url.query, keep_blank_values=True)
                   if k.lower() not in STRIPPED_QUERY)
    shown = "&".join(f"{k}={v}" for k, v in query)
    return relative_times(f"{method} {url.path}" + (f"?{shown}" if shown else ""), at, fold_times)


UUID_LIKE = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")


def normalised_requests(log_path, presence_only=(), rewrites=(), fold_times=False):
    """Sorted multiset. `rewrites` ([regex, replacement]) fold values that
    depend on timing (playback position, segment numbers); lines matching a
    `presence_only` regex (periodic requests) only have to be present."""
    patterns = [re.compile(p) for p in presence_only]
    rewrites = [(re.compile(p), r) for p, r in rewrites]
    counts = {}
    for raw in Path(log_path).read_text().splitlines():
        if raw.strip():
            entry = json.loads(raw)
            line = f"[{entry['role']}] " + normalise_target(entry["method"], entry["target"], entry["time"], fold_times)
            line = UUID_LIKE.sub("<uuid>", line)
            for pattern, replacement in rewrites:
                line = pattern.sub(replacement, line)
            if entry.get("blocked"):
                line += "  [BLOCKED]"
            counts[line] = counts.get(line, 0) + 1
    shown = []
    for line, n in sorted(counts.items()):
        shown.append(f"   * {line}\n" if any(p.search(line) for p in patterns) else f"{n:>4} {line}\n")
    return "".join(shown)


# -- pixels ---------------------------------------------------------------------

def image_stddev(png):
    out = run(["magick", str(png), "-colorspace", "gray", "-format", "%[fx:standard_deviation]", "info:"])
    return float(out.stdout.strip())


def pixel_difference(baseline, candidate, diff_path, tolerance):
    """Share of pixels whose colour differs by more than the fuzz."""
    size = run(["magick", "identify", "-format", "%w %h", str(baseline)]).stdout.split()
    other = run(["magick", "identify", "-format", "%w %h", str(candidate)]).stdout.split()
    if size != other:
        return 1.0, f"size {other[0]}x{other[1]} != baseline {size[0]}x{size[1]}"
    result = run(["magick", "compare", "-metric", "AE", "-fuzz", f"{tolerance['fuzz_percent']}%",
                  str(baseline), str(candidate), str(diff_path)], check=False)
    # `compare` prints the count first ("123" or "123 (0.0001)"); exit 1 means "different".
    count = float(result.stdout.strip().split()[0])
    share = count / (int(size[0]) * int(size[1]))
    return share, f"{int(count)} px ({share:.4%})"


# -- simulator -------------------------------------------------------------------

class Simulator:
    def __init__(self, platform, spec, out):
        self.platform, self.spec, self.out = platform, spec, out
        self.udid = None

    def __enter__(self):
        name = f"Dusk Parity {self.platform} {uuid.uuid4().hex[:8]}"
        self.udid = run(["xcrun", "simctl", "create", name, self.spec["device_type"], self.spec["runtime"]]).stdout.strip()
        log(f"{self.platform}: disposable simulator {self.udid} ({self.spec['device_type']}, {self.spec['runtime']})")
        try:
            run(["xcrun", "simctl", "boot", self.udid], timeout=180)
            run(["xcrun", "simctl", "bootstatus", self.udid, "-b"], timeout=300)
            run(["xcrun", "simctl", "ui", self.udid, "appearance", "dark"], check=False)
            if self.platform != "tv":
                run(["xcrun", "simctl", "status_bar", self.udid, "override", "--time", "9:41",
                     "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
                     "--cellularMode", "active", "--cellularBars", "4", "--operatorName", "",
                     "--batteryState", "charged", "--batteryLevel", "100"])
            # Let first-boot daemons finish before the first capture.
            time.sleep(20)
        except BaseException:
            # __exit__ does not run when __enter__ raises.
            self.__exit__()
            raise
        return self

    def __exit__(self, *_):
        if not self.udid:
            return
        run(["xcrun", "simctl", "shutdown", self.udid], check=False, timeout=120)
        run(["xcrun", "simctl", "delete", self.udid], check=False, timeout=120)
        log(f"{self.platform}: deleted {self.udid}")

    def simctl(self, *args, **kwargs):
        return run(["xcrun", "simctl", *args[:1], self.udid, *args[1:]], **kwargs)


# -- one screen -------------------------------------------------------------------

def stable_screenshot(sim, png, manifest, screen):
    """Screenshots 1.5 s apart until two agree within the tolerance, so a tab
    or push transition still running is never captured."""
    if screen.get("pixels") is False:
        sim.simctl("io", "screenshot", "--type=png", str(png), timeout=60)
        return png
    factor = sim.spec["scale"]
    previous = png.with_suffix(".previous.png")
    sim.simctl("io", "screenshot", "--type=png", str(previous), timeout=60)
    for _ in range(8):
        time.sleep(1.5)
        sim.simctl("io", "screenshot", "--type=png", str(png), timeout=60)
        a = reduced(previous, factor, png.with_suffix(".a.png"))
        b = reduced(png, factor, png.with_suffix(".b.png"))
        share, _ = pixel_difference(a, b, png.with_suffix(".ab.png"), manifest["tolerance"])
        for scratch in (a, b, png.with_suffix(".ab.png")):
            scratch.unlink(missing_ok=True)
        if share <= manifest["tolerance"]["max_differing_share"] / 4:
            previous.unlink(missing_ok=True)
            return png
        shutil.copy(png, previous)
    log(f"  {screen['name']}: screen never settled; keeping the last frame")
    previous.unlink(missing_ok=True)
    return png


def server_command(manifest, port, request_log, screen):
    """The per-screen server: the parity mock (G2/G3) or the plex-demo proxy (G6)."""
    if manifest.get("server") == "smoke_proxy":
        return [sys.executable, "-I", str(HERE / "smoke_proxy.py"), "--port", str(port), "--log", str(request_log),
                "--upstream", manifest["proxy"]["upstream"], "--server", manifest["proxy"]["server"]]
    # A screen's `mock` overrides the defaults (the photo library only exists
    # for the photos screen: elsewhere its racy emptiness probe would decide
    # whether a Photos tab shows).
    mock = {**manifest["mock"], **screen.get("mock", {})}
    return [sys.executable, "-I", str(HERE / "parity_mock.py"), "--port", str(port), "--log", str(request_log),
            "--movies", str(mock["movies"]), "--shows", str(mock["shows"]), "--photos", str(mock["photos"]),
            "--image-cache", str(ROOT / "build" / "parity" / "photo-bank")]


SMOKE_TOKEN = []


def server_env(manifest):
    """The smoke proxy gets one plex.tv token per gate run, in memory only."""
    env = dict(os.environ)
    if manifest.get("server") == "smoke_proxy":
        if not SMOKE_TOKEN:
            sys.path.insert(0, str(HERE))
            import smoke_proxy
            SMOKE_TOKEN.append(smoke_proxy.sign_in(argparse.Namespace(
                login_file="~/.config/jellyfin-demo/compare-plex-login",
                password_file="~/.config/jellyfin-demo/compare-password")))
        env["DUSK_PARITY_PLEX_TOKEN"] = SMOKE_TOKEN[0]
    return env


def capture_screen(sim, app, screen, manifest, out_dir):
    timing = manifest["timing"]
    port = free_port_pair()
    request_log = out_dir / f"{screen['name']}.jsonl"
    request_log.unlink(missing_ok=True)
    mock_out = (out_dir / f"{screen['name']}.mock.log").open("w")
    mock = subprocess.Popen(server_command(manifest, port, request_log, screen), env=server_env(manifest),
                            stdout=mock_out, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        ready_deadline = time.time() + 120
        while "ready" not in (out_dir / f"{screen['name']}.mock.log").read_text():
            if mock.poll() is not None or time.time() > ready_deadline:
                raise RuntimeError(f"parity mock did not start: {out_dir / (screen['name'] + '.mock.log')}")
            time.sleep(0.2)

        sim.simctl("terminate", BUNDLE_ID, check=False)
        sim.simctl("uninstall", BUNDLE_ID, check=False)
        sim.simctl("install", str(app), timeout=300)
        arguments = ["-DuskScreenshotMode", "YES", "-DuskScreenshotPlexTV", f"http://127.0.0.1:{port}",
                     "-DuskScreenshotScreen", screen["screen"], "-DuskScreenshotMute", "1",
                     "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        arguments += manifest.get("launch_arguments", {}).get(sim.platform, [])
        for key, value in screen.get("args", {}).items():
            arguments += [f"-{key}", str(value)]
        sim.simctl("launch", BUNDLE_ID, *arguments, timeout=120)

        # Quiescence: at least `min_seconds`, then `quiet_seconds` without a
        # request. A screen with `seconds` (playback) is captured after exactly that long.
        start = time.time()
        last_count, last_change = -1, start
        while "seconds" in screen:
            if time.time() - start >= screen["seconds"]:
                break
            time.sleep(0.25)
        while "seconds" not in screen:
            count = len(request_log.read_text().splitlines()) if request_log.exists() else 0
            now = time.time()
            if count != last_count:
                last_count, last_change = count, now
            if now - start >= timing["min_seconds"] and now - last_change >= timing["quiet_seconds"]:
                break
            if now - start >= timing["max_seconds"]:
                log(f"  {screen['name']}: still requesting after {timing['max_seconds']} s")
                break
            time.sleep(0.25)
        time.sleep(timing["settle_seconds"])
        settled_count = len(request_log.read_text().splitlines()) if request_log.exists() else 0
        png = stable_screenshot(sim, out_dir / f"{screen['name']}.png", manifest, screen)
        sim.simctl("terminate", BUNDLE_ID, check=False)
        lines = request_log.read_text().splitlines()[:settled_count] if request_log.exists() else []
        request_log.write_text("".join(line + "\n" for line in lines))
        (out_dir / f"{screen['name']}.requests.txt").write_text(
            normalised_requests(request_log, manifest.get("presence_only", []), manifest.get("rewrites", []),
                                manifest.get("times") == "fold"))
        log(f"  {screen['name']}: {settled_count} requests, {time.time() - start:.1f} s")
        return png
    finally:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(mock.pid, signal.SIGTERM)
        mock.wait(timeout=10)
        mock_out.close()


# -- build -------------------------------------------------------------------------

def build_app(platform, out):
    spec = PLATFORMS[platform]
    derived = ROOT / "build" / "parity" / f"dd-{spec['sdk']}"
    app = derived / "Build" / "Products" / spec["app_dir"] / "Dusk.app"
    out.mkdir(parents=True, exist_ok=True)
    build_log = out / f"build-{spec['sdk']}.log"
    if not build_log.exists():
        log(f"{platform}: building {spec['scheme']} ({build_log})")
        with build_log.open("w") as output:
            code = subprocess.call(["xcodebuild", "-project", "Dusk.xcodeproj", "-scheme", spec["scheme"],
                                    "-configuration", "Debug", "-destination", spec["destination"],
                                    "-derivedDataPath", str(derived), "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES", "build"],
                                   cwd=ROOT, stdout=output, stderr=subprocess.STDOUT, timeout=3600)
        if code:
            raise RuntimeError(f"build failed: {build_log}")
    return app


# -- run / compare -----------------------------------------------------------------

def run_platform(platform, manifest, out, screens):
    app = build_app(platform, out)
    platform_out = out / platform
    platform_out.mkdir(parents=True, exist_ok=True)
    with Simulator(platform, manifest["devices"][platform], platform_out) as sim:
        for screen in screens:
            if platform in screen.get("skip", []):
                continue
            # `expect`: a request the screen's destination always sends. When
            # an app-side race kept the route from firing (the photo-library
            # probe), the capture is retried, loudly.
            for attempt in range(1, 4):
                capture_screen(sim, app, screen, manifest, platform_out)
                if not screen.get("expect"):
                    break
                text = (platform_out / f"{screen['name']}.requests.txt").read_text()
                if re.search(screen["expect"], text):
                    break
                log(f"  {screen['name']}: RETRY {attempt}: destination request /{screen['expect']}/ missing")
            else:
                raise RuntimeError(f"{platform}/{screen['name']}: destination never reached in 3 attempts")
    return platform_out


def reduced(png, factor, dest):
    """Screenshots are compared (and stored) at 1/scale, box-filtered: point
    resolution on iPhone/iPad. Text and layout changes survive the averaging;
    the stored baseline stays small."""
    run(["magick", str(png), "-filter", "Box", "-resize", f"{100 / factor:.6f}%", "-strip",
         "-define", "png:compression-level=9", str(dest)])
    return dest


# Request lists: "<count> <line>". count is "3" (exact), "1-2" (a line whose
# count varied between the baseline runs: the app fetches it a racy number of
# times) or "*" (presence_only).

def parse_requests(text):
    parsed = {}
    for raw in text.splitlines():
        if raw.strip():
            count, line = raw.strip().split(" ", 1)
            if count == "*":
                parsed[line] = "*"
            else:
                low, _, high = count.partition("-")
                parsed[line] = (int(low), int(high or low))
    return parsed


def format_requests(parsed):
    shown = []
    for line, spec in sorted(parsed.items()):
        if spec == "*":
            count = "*"
        else:
            count = str(spec[0]) if spec[0] == spec[1] else f"{spec[0]}-{spec[1]}"
        shown.append(f"{count:>4} {line}\n")
    return "".join(shown)


def merge_requests(texts):
    """Merges the runs of one screen; returns (merged text, lines not in every run)."""
    runs = [parse_requests(t) for t in texts]
    every = set.intersection(*(set(r) for r in runs))
    # Image lines are judged by identity (compare_images), so the baseline
    # keeps every image any run loaded.
    images = {line for r in runs for line in r if IMAGE.search(line)}
    unstable = sorted(set.union(*(set(r) for r in runs)) - every - images)
    merged = {line: "*" for line in images - every}
    for line in every:
        specs = [r[line] for r in runs]
        if "*" in specs:
            merged[line] = "*"
        else:
            merged[line] = (min(s[0] for s in specs), max(s[1] for s in specs))
    return format_requests(merged), unstable


def without_optional(text, screen, platform, manifest):
    """Drops lines matching a manifest `optional` rule: background prefetches
    whose presence depends on timing. A rule applies to every screen and
    platform unless it names `screens` / `platforms`; a screen in `except`
    keeps the lines strict."""
    def applies(rule):
        return (screen["name"] not in rule.get("except", [])
                and screen["name"] in rule.get("screens", [screen["name"]])
                and platform in rule.get("platforms", [platform]))
    rules = [re.compile(rule["pattern"]) for rule in manifest.get("optional", []) if applies(rule)]
    return "".join(line + "\n" for line in text.splitlines()
                   if line.strip() and not any(rule.search(line) for rule in rules))


IMAGE = re.compile(r"\] GET /photo/:/transcode\?.*?url=([^&]+)")


def compare_images(expected, actual):
    """Image requests by identity (the `url=` path). Off-screen prefetches and
    transient layout sizes vary with timing, while what is on screen is G3's
    job. So: a new image identity fails; an identity whose sizes share nothing
    with the baseline fails; a missing identity or an extra size is a note."""
    def grouped(lines):
        groups = {}
        for line in lines:
            groups.setdefault(IMAGE.search(line).group(1), set()).add(line)
        return groups
    want, got = grouped(expected), grouped(actual)
    failures, notes = [], []
    for identity in sorted(set(got) - set(want)):
        failures += [f"extra    {line}" for line in sorted(got[identity])]
    for identity in sorted(set(want) - set(got)):
        notes.append(f"unloaded image {identity}")
    for identity in sorted(set(want) & set(got)):
        if not want[identity] & got[identity]:
            failures += [f"size     {line}" for line in sorted(got[identity])]
            failures += [f"baseline {line}" for line in sorted(want[identity])]
        else:
            notes += [f"extra size {line}" for line in sorted(got[identity] - want[identity])]
    return failures, notes


def compare_requests(expected_text, actual_text, count_free=()):
    """(failures, notes). Lines must be the same set; a line with an exact
    baseline count must have that count; a racy line (recorded range, or a
    manifest `count_free` pattern: session bootstrap and connection probes)
    only notes a count outside its range."""
    count_free = [re.compile(p) for p in count_free]
    expected, actual = parse_requests(expected_text), parse_requests(actual_text)
    failures, notes = compare_images([l for l in expected if IMAGE.search(l)], [l for l in actual if IMAGE.search(l)])
    expected = {l: v for l, v in expected.items() if not IMAGE.search(l)}
    actual = {l: v for l, v in actual.items() if not IMAGE.search(l)}
    failures += [f"missing  {line}" for line in sorted(set(expected) - set(actual))]
    failures += [f"extra    {line}" for line in sorted(set(actual) - set(expected))]
    for line in sorted(set(expected) & set(actual)):
        want, got = expected[line], actual[line]
        if want == "*" or got == "*":
            continue
        if want[0] == want[1] and not any(p.search(line) for p in count_free):
            if got != want:
                failures.append(f"count    {line}: {got[0]}, baseline {want[0]}")
        elif got[0] < want[0] or got[1] > want[1]:
            notes.append(f"racy     {line}: {got[0]}, baseline range {want[0]}-{want[1]}")
    return failures, notes


def screen_pixels(screen, platform, manifest, bp, cp, out, name, baseline_is_reduced):
    factor = manifest["devices"][platform]["scale"]
    if not baseline_is_reduced:
        bp = reduced(bp, factor, out / f"{name}.expected.png")
    cp = reduced(cp, factor, out / f"{name}.actual.png")
    # Masks ([x, y, w, h] in reduced pixels) cover what may change without a
    # behaviour change, e.g. the app version on Settings.
    masks = manifest.get("platform_masks", {}).get(platform, []) + screen.get("masks", {}).get(platform, [])
    if masks:
        draw = []
        for x, y, w, h in masks:
            draw += ["-draw", f"rectangle {x},{y} {x + w - 1},{y + h - 1}"]
        for path, masked in ((bp, out / f"{name}.expected.masked.png"), (cp, out / f"{name}.actual.masked.png")):
            run(["magick", str(path), "-fill", "black", *draw, str(masked)])
        bp, cp = out / f"{name}.expected.masked.png", out / f"{name}.actual.masked.png"
    return pixel_difference(bp, cp, out / f"{name}.diff.png", manifest["tolerance"])


def compare(baseline_dir, candidate_dir, platforms, screens, manifest, diff_dir, baseline_is_reduced):
    tolerance = manifest["tolerance"]
    failures = []
    for platform in platforms:
        out = diff_dir / platform
        out.mkdir(parents=True, exist_ok=True)
        for screen in screens:
            if platform in screen.get("skip", []):
                continue
            name = screen["name"]
            b, c = baseline_dir / platform, candidate_dir / platform
            expected, actual = b / f"{name}.requests.txt", c / f"{name}.requests.txt"
            if not expected.exists() or not actual.exists():
                failures.append(f"{platform}/{name}: missing request log")
            else:
                problems, notes = compare_requests(without_optional(expected.read_text(), screen, platform, manifest),
                                                   without_optional(actual.read_text(), screen, platform, manifest),
                                                   manifest.get("count_free", []))
                for note in notes:
                    log(f"  {platform}/{name}: note {note}")
                if problems:
                    (out / f"{name}.requests.diff").write_text("\n".join(problems) + "\n")
                    failures.append(f"{platform}/{name}: G2 request log differs\n  " + "\n  ".join(problems))
            if screen.get("pixels") is False:
                continue
            bp, cp = b / f"{name}.png", c / f"{name}.png"
            if not bp.exists() or not cp.exists():
                failures.append(f"{platform}/{name}: missing screenshot")
                continue
            share, detail = screen_pixels(screen, platform, manifest, bp, cp, out, name, baseline_is_reduced)
            if share > tolerance["max_differing_share"]:
                failures.append(f"{platform}/{name}: G3 pixels differ, {detail} (expected/actual/diff png in {out})")
            else:
                log(f"  {platform}/{name}: pixels ok, {detail}")
    return failures


def consolidate(run_dirs, platforms, screens, manifest, merged_dir):
    """Merges several runs into one baseline-shaped directory (request ranges,
    first run's screenshots) and returns what was not reproducible."""
    problems = []
    for platform in platforms:
        target = merged_dir / platform
        target.mkdir(parents=True, exist_ok=True)
        for screen in screens:
            if platform in screen.get("skip", []):
                continue
            name = screen["name"]
            texts = [without_optional((d / platform / f"{name}.requests.txt").read_text(), screen, platform, manifest)
                     for d in run_dirs]
            merged, unstable = merge_requests(texts)
            (target / f"{name}.requests.txt").write_text(merged)
            problems += [f"{platform}/{name}: G2 line not in every run: {line}" for line in unstable]
            if screen.get("pixels") is False:
                continue
            first = run_dirs[0] / platform / f"{name}.png"
            shutil.copy(first, target / f"{name}.png")
            for i, other in enumerate(run_dirs[1:], start=2):
                share, detail = screen_pixels(screen, platform, manifest, first, other / platform / f"{name}.png",
                                              target, f"{name}.run{i}", False)
                if share > manifest["tolerance"]["max_differing_share"]:
                    problems.append(f"{platform}/{name}: G3 run {i} differs from run 1, {detail}")
                else:
                    log(f"  {platform}/{name}: run {i} pixels match run 1, {detail}")
    return problems


def store_baseline(merged_dir, platforms, screens, manifest, baseline):
    for platform in platforms:
        target = baseline / platform
        target.mkdir(parents=True, exist_ok=True)
        for screen in screens:
            if platform in screen.get("skip", []):
                continue
            name = screen["name"]
            shutil.copy(merged_dir / platform / f"{name}.requests.txt", target / f"{name}.requests.txt")
            if screen.get("pixels") is False:
                continue
            png = merged_dir / platform / f"{name}.png"
            # A black or blank frame must never become the baseline.
            if image_stddev(png) < 0.02:
                raise RuntimeError(f"{platform}/{name}: screenshot is near-uniform, refusing it as a baseline: {png}")
            reduced(png, manifest["devices"][platform]["scale"], target / f"{name}.png")


def environment():
    xcode = run(["xcodebuild", "-version"]).stdout.split("\n")
    commit = run(["git", "rev-parse", "HEAD"], cwd=ROOT).stdout.strip()
    dirty = bool(run(["git", "status", "--porcelain", "--", "Dusk", "DuskTopShelf", "project.yml"], cwd=ROOT).stdout.strip())
    vlckit = (ROOT / "Frameworks" / "VLCKit-VERSION.txt").read_text().strip()
    stamp = ROOT / "Frameworks" / "MobileVLCKit.xcframework" / "vlckit-installed.txt"
    # Tree hashes survive rebases: they name the app sources that were recorded.
    trees = {path: run(["git", "rev-parse", f"HEAD:{path}"], cwd=ROOT).stdout.strip()
             for path in ("Dusk", "DuskTopShelf", "project.yml")}
    return {"commit": commit, "app_trees": trees, "app_sources_dirty": dirty, "xcode": " ".join(x for x in xcode if x),
            "vlckit": vlckit, "vlckit_installed": stamp.read_text().strip() if stamp.exists() else None}


def check_environment(baseline):
    xcode = " ".join(x for x in run(["xcodebuild", "-version"]).stdout.split("\n") if x)
    recorded_file = baseline / "recorded.json"
    if not recorded_file.exists():
        raise RuntimeError(f"no baseline at {baseline}; run `record` on the pre-refactor tree first")
    recorded = json.loads(recorded_file.read_text())
    if recorded.get("xcode") and recorded["xcode"] != xcode:
        raise RuntimeError(f"Xcode differs from the baseline ({xcode!r} != {recorded['xcode']!r}); "
                           "pixels are only comparable on the same Xcode and simulator runtime")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("suite", choices=sorted(SUITES), help="screens = G2/G3 on the mock, smoke = G6 on plex-demo")
    parser.add_argument("mode", choices=["record", "check", "repeat"])
    parser.add_argument("--baseline", type=Path, help="baseline directory (default per suite)")
    parser.add_argument("--platforms", default="iphone,ipad,tv")
    parser.add_argument("--screens", help="comma-separated subset of manifest screen names")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--runs", type=int, help="record/repeat: fresh runs to merge (default 3 / 2)")
    parser.add_argument("--reuse", action="store_true",
                        help="record/repeat with --out of an earlier attempt: keep its complete runs and only "
                             "re-merge them (after a manifest `optional`/`masks` change)")
    parser.add_argument("--compare-to", type=Path, help="check: compare against this run directory instead of the baseline")
    args = parser.parse_args()

    suite = SUITES[args.suite]
    manifest = json.loads(suite["manifest"].read_text())
    baseline = (args.baseline or suite["baseline"]).resolve()
    platforms = [p for p in args.platforms.split(",") if p]
    screens = manifest["screens"]
    if args.screens:
        wanted = args.screens.split(",")
        screens = [s for s in screens if s["name"] in wanted]
    out = (args.out or ROOT / "build" / "parity" / "runs" / datetime.datetime.now().strftime("%Y%m%d-%H%M%S")).resolve()
    out.mkdir(parents=True, exist_ok=True)
    log(f"output: {out}")
    for platform in platforms:
        spec = manifest["devices"][platform]
        if spec["runtime"] not in run(["xcrun", "simctl", "list", "runtimes"]).stdout:
            raise RuntimeError(f"runtime {spec['runtime']} for {platform} is not installed")

    if args.mode == "check" and not args.compare_to:
        check_environment(baseline)

    if args.mode in ("record", "repeat"):
        # Several fresh runs; whatever is not reproducible between them is a
        # harness problem and must never reach the baseline.
        runs = args.runs or (3 if args.mode == "record" else 2)
        run_dirs = [out / f"run{i}" for i in range(1, runs + 1)]
        for platform in platforms:
            for run_dir in run_dirs:
                done = all((run_dir / platform / f"{sc['name']}.requests.txt").exists()
                           for sc in screens if platform not in sc.get("skip", []))
                if args.reuse and done:
                    log(f"{platform}: reusing {run_dir / platform}")
                    continue
                run_platform(platform, manifest, run_dir, screens)
        failures = consolidate(run_dirs, platforms, screens, manifest, out / "merged")
        if args.mode == "record" and not failures:
            store_baseline(out / "merged", platforms, screens, manifest, baseline)
            recorded = environment()
            recorded["date"] = datetime.date.today().isoformat()
            recorded["platforms"] = platforms
            recorded["runs"] = runs
            (baseline / "recorded.json").write_text(json.dumps(recorded, indent=2) + "\n")
            log(f"baseline stored in {baseline}")
    else:
        for platform in platforms:
            run_platform(platform, manifest, out, screens)
        failures = compare(args.compare_to or baseline, out, platforms, screens, manifest, out / "diff",
                           args.compare_to is None)

    if failures:
        log("\nFAILED:\n" + "\n".join(failures))
        log(f"diffs in {out / 'diff'}")
        sys.exit(1)
    log(f"\n{args.suite}: no difference")


if __name__ == "__main__":
    def terminate(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, terminate)
    try:
        main()
    except (RuntimeError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        print(f"parity gate stopped: {error}", file=sys.stderr)
        sys.exit(2)
