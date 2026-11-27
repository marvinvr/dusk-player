#!/usr/bin/env python3
"""Generate the T-0 test media and copy it into the shared demo folder.

    python3 -I scripts/demo-testdata/make_media.py <group> [<group> ...]
    python3 -I scripts/demo-testdata/make_media.py all

Groups: versions, multipart, subtitles, extras, photos, paging.

Everything is synthetic (ffmpeg test patterns, silent audio, PIL text), so it
is licence-free. The only third-party asset is the OFL font Pacifico, fetched
from google/fonts for the ASS attachment. Files are built in a staging folder
(DUSK_DEMO_STAGING, default ~/.cache/dusk-demo-testdata) and copied to the demo
root (DUSK_DEMO_ROOT, default /Volumes/Bulk/Media/Demo) only when missing or
different. Nothing is ever deleted, and nothing is written under Real/ or Stress/.
"""
import datetime as dt
import hashlib
import os
import random
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vobsub  # noqa: E402

ROOT = Path(os.environ.get("DUSK_DEMO_ROOT", "/Volumes/Bulk/Media/Demo"))
STAGE = Path(os.environ.get("DUSK_DEMO_STAGING", Path.home() / ".cache/dusk-demo-testdata"))
FONT_URL = "https://github.com/google/fonts/raw/main/ofl/pacifico/Pacifico-Regular.ttf"
FORBIDDEN = ("Real", "Stress")


def log(*a):
    print(*a, flush=True)


def ff(*args):
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *map(str, args)], check=True)


def stage(rel):
    p = STAGE / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


def publish(rel):
    """Copy one staged file to the demo root if it is missing or different."""
    rel = Path(rel)
    assert rel.parts[0] not in FORBIDDEN, rel
    src, dst = STAGE / rel, ROOT / rel
    assert ROOT in dst.parents
    if dst.exists() and dst.stat().st_size == src.stat().st_size:
        return False
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
    return True


def font():
    p = STAGE / "_assets/Pacifico-Regular.ttf"
    if not p.exists():
        p.parent.mkdir(parents=True, exist_ok=True)
        urllib.request.urlretrieve(FONT_URL, p)
    return p


def label_png(text, w, h, sub=None):
    key = hashlib.sha1(repr((text, sub, w, h)).encode()).hexdigest()[:12]
    p = STAGE / "_assets" / f"label-{key}.png"
    p.parent.mkdir(parents=True, exist_ok=True)
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    big = ImageFont.load_default(max(24, h // 9))
    small = ImageFont.load_default(max(16, h // 22))
    d.rounded_rectangle((w * 0.08, h * 0.32, w * 0.92, h * 0.68), radius=h // 40, fill=(10, 12, 20, 200))
    d.text((w / 2, h * (0.46 if sub else 0.5)), text, font=big, fill="white", anchor="mm")
    if sub:
        d.text((w / 2, h * 0.58), sub, font=small, fill=(210, 210, 210), anchor="mm")
    img.save(p)
    return p


def clip(rel, seconds, w, h, text, sub=None, codec="h264", extra_inputs=(), extra_args=(), audio_lang="eng",
         title=None):
    """Labelled test pattern + silent stereo audio."""
    out = stage(rel)
    if out.exists():
        return out
    vcodec = (["-c:v", "libx264", "-preset", "veryfast", "-crf", "32", "-pix_fmt", "yuv420p"] if codec == "h264"
              else ["-c:v", "libx265", "-preset", "fast", "-crf", "34", "-pix_fmt", "yuv420p",
                    "-x265-params", "log-level=error"])
    if out.suffix == ".mp4":
        vcodec += ["-tag:v", "hvc1"] if codec == "hevc" else []
        vcodec += ["-movflags", "+faststart"]
    ff("-f", "lavfi", "-i", f"testsrc2=s={w}x{h}:r=24:d={seconds}",
       "-loop", "1", "-i", label_png(text, w, h, sub),
       "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
       *extra_inputs,
       "-filter_complex", "[0:v][1:v]overlay=0:0:shortest=1[v]",
       "-map", "[v]", "-map", "2:a", *extra_args,
       *vcodec, "-c:a", "aac", "-b:a", "48k", "-t", seconds,
       "-metadata:s:a:0", f"language={audio_lang}", *(["-metadata", f"title={title}"] if title else []), out)
    return out


# ------------------------------------------------------------------ groups
def g_versions():
    base = "Movies/Dusk Two Versions (2026)/Dusk Two Versions (2026)"
    clip(f"{base} - 1080p.mkv", 60, 1920, 1080, "Dusk Two Versions", "Version: 1080p H.264")
    clip(f"{base} - 2160p.mkv", 60, 3840, 2160, "Dusk Two Versions", "Version: 2160p HEVC", codec="hevc")
    return [f"{base} - 1080p.mkv", f"{base} - 2160p.mkv"]


def g_multipart():
    base = "Movies/Dusk Two Parts (2026)/Dusk Two Parts (2026)"
    clip(f"{base} - cd1.mkv", 45, 1280, 720, "Dusk Two Parts", "Part 1 of 2 (cd1)")
    clip(f"{base} - cd2.mkv", 45, 1280, 720, "Dusk Two Parts", "Part 2 of 2 (cd2)")
    return [f"{base} - cd1.mkv", f"{base} - cd2.mkv"]


ASS_HEAD = """[Script Info]
ScriptType: v4.00+
PlayResX: 1280
PlayResY: 720
WrapStyle: 0

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
{styles}
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""


def _t(s):
    return f"{int(s // 3600)}:{int(s // 60 % 60):02d}:{s % 60:05.2f}"


def _srt_t(s):
    ms = int(round(s * 1000))
    return f"{ms // 3600000:02d}:{ms // 60000 % 60:02d}:{ms // 1000 % 60:02d},{ms % 1000:03d}"


def srt(cues):
    return "".join(f"{i}\n{_srt_t(a)} --> {_srt_t(b)}\n{t}\n\n" for i, (a, b, t) in enumerate(cues, 1))


def g_subtitles():
    rels = []
    # A: embedded ASS with an attached font, plus an external .ass sidecar
    base = "Movies/Dusk Subtitles ASS (2026)/Dusk Subtitles ASS (2026)"
    out = stage(f"{base}.mkv")
    if not out.exists():
        styles = ("Style: Default,Pacifico,54,&H00FFFFFF,&H000000FF,&H00402010,&H80000000,0,0,0,0,100,100,0,0,1,3,1,2,40,40,60,1\n"
                  "Style: Sign,Pacifico,40,&H0000E0FF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,-8,1,2,0,8,40,40,40,1\n")
        ev = []
        for i, s in enumerate(range(2, 58, 6)):
            ev.append(f"Dialogue: 0,{_t(s)},{_t(s + 4)},Default,,0,0,0,,Embedded ASS line {i + 1} in {{\\i1}}Pacifico{{\\i0}} (attached font)")
        ev.append(f"Dialogue: 1,{_t(10)},{_t(30)},Sign,,0,0,0,,{{\\pos(300,140)\\frz-8}}Positioned sign, rotated")
        ev.append(f"Dialogue: 1,{_t(32)},{_t(50)},Sign,,0,0,0,,{{\\move(100,200,1100,200)\\c&H00FF80&}}Moving karaoke-style colour")
        ass = stage(f"_assets/{Path(base).name}.embedded.ass")
        ass.write_text(ASS_HEAD.format(styles=styles) + "\n".join(ev) + "\n", encoding="utf-8")
        tmp = clip(f"_assets/{Path(base).name}.video.mkv", 60, 1280, 720, "Dusk Subtitles ASS", "embedded ASS + Pacifico attachment, external .de.ass")
        ff("-i", tmp, "-i", ass, "-attach", font(),
           "-map", "0", "-map", "1", "-c", "copy",
           "-metadata:s:t:0", "mimetype=application/x-truetype-font", "-metadata:s:t:0", "filename=Pacifico-Regular.ttf",
           "-metadata:s:s:0", "language=eng", "-metadata:s:s:0", "title=English (ASS, styled)",
           out)
    ext = stage(f"{base}.de.ass")
    if not ext.exists():
        styles = "Style: Default,Arial,46,&H0000FFFF,&H000000FF,&H00000000,&H80000000,1,0,0,0,100,100,0,0,1,3,1,8,40,40,50,1\n"
        ev = [f"Dialogue: 0,{_t(s)},{_t(s + 4)},Default,,0,0,0,,Externe ASS-Zeile {i + 1} (gelb, oben)"
              for i, s in enumerate(range(3, 58, 6))]
        ext.write_text(ASS_HEAD.format(styles=styles) + "\n".join(ev) + "\n", encoding="utf-8")
    rels += [f"{base}.mkv", f"{base}.de.ass"]

    # B: VobSub (embedded + external) and a forced-only track (embedded + external)
    base = "Movies/Dusk Subtitles VobSub Forced (2026)/Dusk Subtitles VobSub Forced (2026)"
    out = stage(f"{base}.mkv")
    forced = [(6, 10, "[Sign] BÄCKEREI = Bakery"), (24, 28, "[Foreign dialogue] Where is the station?"),
              (44, 48, "[Note] Ich komme gleich. = I'll be right there.")]
    if not out.exists():
        vs_en = stage("_assets/vobsub-en")
        vobsub.write(str(vs_en), [(s, s + 4, f"Embedded VobSub line {i + 1}") for i, s in enumerate(range(2, 58, 6))],
                     1280, 720, lang="en")
        fsrt = stage("_assets/forced-embedded.srt")
        fsrt.write_text(srt(forced), encoding="utf-8")
        tmp = clip(f"_assets/{Path(base).name}.video.mkv", 60, 1280, 720, "Dusk Subtitles VobSub Forced",
                   "embedded VobSub + forced-only SRT, external .de VobSub + .en.forced.srt")
        ff("-i", tmp, "-i", f"{vs_en}.idx", "-i", fsrt,
           "-map", "0", "-map", "1", "-map", "2", "-c", "copy", "-c:s:1", "srt",
           "-metadata:s:s:0", "language=eng", "-metadata:s:s:0", "title=English (VobSub)",
           "-metadata:s:s:1", "language=eng", "-metadata:s:s:1", "title=English (Forced only)",
           "-disposition:s:0", "0", "-disposition:s:1", "forced",
           out)
    de = stage(f"{base}.de.idx")
    if not de.exists():
        vobsub.write(str(STAGE / f"{base}.de"),
                     [(s, s + 4, f"Externe VobSub-Zeile {i + 1}") for i, s in enumerate(range(3, 58, 6))],
                     1280, 720, lang="de")
    fext = stage(f"{base}.en.forced.srt")
    if not fext.exists():
        fext.write_text(srt([(a + 1, b + 1, "(external) " + t) for a, b, t in forced]), encoding="utf-8")
    rels += [f"{base}.mkv", f"{base}.de.idx", f"{base}.de.sub", f"{base}.en.forced.srt"]
    return rels


def g_extras():
    rels = []
    # movie: BBB already has Behind The Scenes, Featurettes and a local trailer; add a deleted scene
    # explicit title tags: Plex prefers the embedded title for extras (and otherwise
    # mangles names, e.g. "Alternate Ending" -> "Ending"); Jellyfin uses the file name
    r = "Movies/Big Buck Bunny (2008)/Deleted Scenes/Alternate Ending.mp4"
    clip(r, 15, 1280, 720, "Big Buck Bunny", "Extra: deleted scene", title="Alternate Ending")
    rels.append(r)
    # show, season and episode extras on Weekend Projects (Shorts)
    show = "Shorts/Weekend Projects"
    for r, sub, title in [
        (f"{show}/Featurettes/Meet the Builders.mp4", "Extra (show): featurette", "Meet the Builders"),
        (f"{show}/Trailers/Weekend Projects Trailer.mp4", "Extra (show): trailer", "Weekend Projects Trailer"),
        (f"{show}/Season 01/Behind The Scenes/Season One Bloopers.mp4", "Extra (season 1): behind the scenes",
         "Season One Bloopers"),
        # episode-level: Plex attaches it to S01E01, Jellyfin 12.4 files it under the season
        (f"{show}/Season 01/Weekend Projects - S01E01 - Building the Treehouse-behindthescenes.mp4",
         "Extra (episode 1): behind the scenes", "Building the Treehouse: Behind the Scenes"),
    ]:
        clip(r, 15, 1280, 720, "Weekend Projects", sub, title=title)
        rels.append(r)
    return rels


# ------------------------------------------------------------------ photos
def _exif(img, when, orientation=1, make="Dusk", model="T-0 Generator"):
    ex = Image.Exif()
    ex[0x010F] = make
    ex[0x0110] = model
    ex[0x0112] = orientation
    ex[0x0132] = when.strftime("%Y:%m:%d %H:%M:%S")
    sub = ex.get_ifd(0x8769)
    sub[0x9003] = when.strftime("%Y:%m:%d %H:%M:%S")  # DateTimeOriginal
    sub[0x9004] = when.strftime("%Y:%m:%d %H:%M:%S")  # DateTimeDigitized
    return ex


def _photo(text, sub, color, size=(1600, 1067)):
    img = Image.new("RGB", size, color)
    d = ImageDraw.Draw(img)
    w, h = size
    for i in range(0, w, 80):
        d.line((i, 0, i - h // 2, h), fill=tuple(min(255, c + 25) for c in color), width=18)
    d.text((w / 2, h * 0.42), text, font=ImageFont.load_default(h // 9), fill="white", anchor="mm")
    d.text((w / 2, h * 0.58), sub, font=ImageFont.load_default(h // 24), fill="white", anchor="mm")
    return img


def g_photos():
    album = "Photos/Metadata Test"
    rels = []
    shots = [  # three months, two photos each
        (dt.datetime(2025, 8, 3, 9, 15), (40, 110, 160)), (dt.datetime(2025, 8, 21, 18, 40), (60, 140, 120)),
        (dt.datetime(2025, 9, 7, 12, 5), (150, 100, 40)), (dt.datetime(2025, 9, 28, 16, 30), (120, 70, 150)),
        (dt.datetime(2025, 10, 11, 8, 50), (160, 60, 60)), (dt.datetime(2025, 10, 30, 20, 10), (50, 50, 70)),
    ]
    for i, (when, color) in enumerate(shots, 1):
        r = f"{album}/EXIF_{when:%Y-%m-%d}_{i:02d}.jpg"
        p = stage(r)
        if not p.exists():
            _photo(when.strftime("%d %B %Y"), f"EXIF DateTimeOriginal {when:%Y-%m-%d %H:%M}", color).save(
                p, quality=85, exif=_exif(None, when))
        rels.append(r)
    # rotated: pixels stored landscape, EXIF Orientation 6 (rotate 90 CW to display portrait)
    r = f"{album}/Rotated_Orientation6.jpg"
    p = stage(r)
    if not p.exists():
        when = dt.datetime(2025, 9, 14, 11, 0)
        portrait = _photo("UP ↑", "Orientation 6: this text is upright only if EXIF rotation is applied",
                          (30, 120, 70), size=(1067, 1600))
        d = ImageDraw.Draw(portrait)
        d.polygon([(533, 120), (433, 300), (633, 300)], fill="white")
        landscape = portrait.transpose(Image.Transpose.ROTATE_90)  # stored rotated 90 CCW
        landscape.save(p, quality=85, exif=_exif(None, when, orientation=6))
    rels.append(r)
    # HEIC via sips (macOS), EXIF carried over from a JPEG
    r = f"{album}/HEIC_2025-09-20.heic"
    p = stage(r)
    if not p.exists():
        when = dt.datetime(2025, 9, 20, 14, 45)
        j = stage("_assets/heic-source.jpg")
        _photo("HEIC", f"EXIF DateTimeOriginal {when:%Y-%m-%d %H:%M}", (90, 90, 160)).save(
            j, quality=90, exif=_exif(None, when))
        subprocess.run(["sips", "-s", "format", "heic", str(j), "--out", str(p)], check=True,
                       stdout=subprocess.DEVNULL)
    rels.append(r)
    # clip with a creation date
    r = f"{album}/Clip_2025-10-05.mp4"
    clip(r, 8, 1280, 720, "Photo library clip", "creation_time 2025-10-05",
         extra_args=["-metadata", "creation_time=2025-10-05T15:20:00Z"])
    rels.append(r)
    return rels


# ------------------------------------------------------------------ paging
WORDS_A = ["Amber", "Brisk", "Copper", "Dusky", "Ember", "Frosted", "Golden", "Hollow", "Ivory", "Jade",
           "Kindled", "Lunar", "Misty", "Nimble", "Opal", "Paper", "Quiet", "Rusty", "Silver", "Tidal",
           "Umber", "Velvet", "Willow", "Xenial", "Yonder", "Zephyr"]
WORDS_B = ["Atlas", "Harbor", "Lantern", "Meadow", "Orchard", "Signal", "Voyage", "Canyon", "Echo", "Garden",
           "Horizon", "Island", "Junction", "Kingdom", "Letter", "Mirror", "North", "Outpost", "Parade", "Quarry"]
SPECIAL = ["12 Quiet Rooms", "1999 Summer Tapes", "2 Hours to Dawn", "300 Lanterns", "42 Signals",
           "7 Days in Velvet", "9 to 5 Harbor", "#Hashtag Holiday", "(Untitled) Meadow", "[Redacted] Letter",
           "¡Olé Parade!", "…And Then the Echo", "'Til Morning", "@Home Outpost", "$5 Voyage", "&Co Garden",
           "Élan Orchard", "Ångström Atlas", "Øresund Signal", "Über Canyon", "Ça Va Island",
           "the lowercase lantern", "The Amber Harbor", "A Copper Mirror", "An Ivory Kingdom"]


def paging_titles(n=520):
    rnd = random.Random(20261127)
    titles = list(SPECIAL)
    seen = set(titles)
    while len(titles) < n:
        a = WORDS_A[len(titles) % len(WORDS_A)]
        t = f"{a} {rnd.choice(WORDS_B)}"
        if rnd.random() < 0.3:
            t += f" {rnd.choice(['II', 'III', 'Returns', 'at Night', 'Forever', 'Redux'])}"
        if t in seen:
            continue
        seen.add(t)
        titles.append(t)
    return [(t, 1960 + rnd.randrange(66)) for t in titles]


def safe_name(t):
    return t.replace("/", "-").replace(":", "-").replace("?", "").replace("$", "S")


def g_paging():
    stub = stage("_assets/paging-stub.mkv")
    if not stub.exists():
        ff("-f", "lavfi", "-i", "testsrc2=s=160x90:r=10:d=2", "-c:v", "libx264", "-preset", "veryfast",
           "-crf", "40", "-pix_fmt", "yuv420p", stub)
    rels = []
    for t, y in paging_titles():
        r = f"Paging Test/{safe_name(t)} ({y}).mkv"
        p = stage(r)
        if not p.exists():
            shutil.copyfile(stub, p)
        rels.append(r)
    return rels


GROUPS = {"versions": g_versions, "multipart": g_multipart, "subtitles": g_subtitles,
          "extras": g_extras, "photos": g_photos, "paging": g_paging}


def main(argv):
    names = list(GROUPS) if argv == ["all"] else argv
    if not names:
        print(__doc__)
        return 2
    if not ROOT.is_dir():
        sys.exit(f"demo root {ROOT} is not mounted")
    for n in names:
        rels = GROUPS[n]()
        copied = sum(publish(r) for r in rels)
        log(f"{n}: {len(rels)} files, {copied} copied to {ROOT}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
