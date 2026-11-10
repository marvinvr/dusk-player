"""Generates the Apple TV alternate app icons (issue #68): one layered
`DuskIcon<Variant>.imagestack` per supporter variant at the root of
`Dusk/Resources/AppIconsTV.xcassets` (a tvOS-only catalog, so the names can
match the iOS `.icon` bundles without the two colliding in one catalog).

actool only resolves `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` on tvOS to
a top-level image stack of that name ("No applicable image stack found" for a
`.brandassets`), so an alternate is just the Home Screen stack: 400x240 @1x and
800x480 @2x. The 1280x768 App Store stack only exists for the primary icon.

No new art. Each stack copies the primary `AppIconTV.brandassets` "App Icon"
layer structure (Front + Back, the parallax pair the primary ships with) at
the same sizes:
  - Back: the variant's opaque `background.png` (1024 square) resampled into
    the full 5:3 field, so the whole top-to-bottom gradient survives.
  - Front: the primary TV front layer's own alpha (identical silhouette and
    placement) filled with the variant's `mark.png` colours, mapped onto it
    with the same alpha-moment fit `generate_launch_logo_variants.py` uses.

Usage (needs Pillow + NumPy, e.g. `uv run --with numpy --with pillow`):
    python3 scripts/generate_tv_alternate_icons.py Dusk/Resources [preview-dir]

Rerun when an icon's background or mark changes. With a preview dir it also
writes flattened 800x480 previews of every variant for review."""
import json
import os
import shutil
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

RES = sys.argv[1]
PREVIEW = sys.argv[2] if len(sys.argv) > 2 else None
PRIMARY = f"{RES}/Assets.xcassets/AppIconTV.brandassets"
CATALOG = f"{RES}/AppIconsTV.xcassets"
VARIANTS = ["Dawn", "Midnight", "Neon", "Mono", "Aurora", "GoldenHour", "Velvet", "Emerald", "Gilded"]
INFO = {"author": "xcode", "version": 1}

# (scale, back size, primary front file) — mirrors AppIconTV's "App Icon".
ENTRIES = [("1x", (400, 240), "216.png"), ("2x", (800, 480), "432.png")]
PRIMARY_STACK = f"{PRIMARY}/App Icon.imagestack"
BACK_NAMES = {(400, 240): "400x240-back.png", (800, 480): "800x480-back.png"}

primary_mark = np.array(Image.open(f"{RES}/DuskIcon.icon/Assets/dusk_icon_new_transparentcropped.png").convert("RGBA"))


def moments(a):
    a = a.astype(np.float64)
    yy, xx = np.mgrid[0:a.shape[0], 0:a.shape[1]]
    w = a.sum()
    cx, cy = (a * xx).sum() / w, (a * yy).sum() / w
    return cx, cy, np.sqrt((a * ((xx - cx) ** 2 + (yy - cy) ** 2)).sum() / w)


def padded_colours(rgba):
    """Straight RGB with the colour bled outwards past the mark's edge, so the
    resample never pulls in the undefined colour of transparent pixels."""
    rgb = rgba[..., :3].astype(np.float64)
    a = rgba[..., 3].astype(np.float64) / 255
    out = rgb.copy()
    hole = a < 0.5
    for radius in (2, 6, 18, 48):
        if not hole.any():
            break
        wa = np.array(Image.fromarray((a * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(radius))).astype(np.float64)
        filled = np.empty_like(rgb)
        for c in range(3):
            ch = np.array(Image.fromarray((rgb[..., c] * a).astype(np.uint8)).filter(ImageFilter.GaussianBlur(radius))).astype(np.float64)
            filled[..., c] = ch * 255 / np.maximum(wa, 1e-6)
        out[hole] = np.clip(filled, 0, 255)[hole]
        hole = hole & (wa < 8)
    return out


def front_layer(mark_colours, primary_front_path):
    """The primary front's alpha, coloured from the variant mark."""
    front = Image.open(primary_front_path).convert("RGBA")
    alpha = np.array(front)[..., 3]
    fcx, fcy, fr = moments(alpha)
    mcx, mcy, mr = moments(primary_mark[..., 3])
    scale = fr / mr
    tx, ty = fcx - scale * mcx, fcy - scale * mcy
    # Downscale with a proper filter first (the affine transform only point
    # samples), then place it with the sub-pixel offset.
    w, h = mark_colours.size
    scaled = mark_colours.resize((round(w * scale), round(h * scale)), Image.LANCZOS)
    sx, sy = scaled.width / w, scaled.height / h
    mapped = scaled.transform(
        front.size,
        Image.AFFINE,
        (sx / scale, 0, -tx * sx / scale, 0, sy / scale, -ty * sy / scale),
        resample=Image.BICUBIC,
    )
    out = np.dstack([np.array(mapped), alpha])
    out[alpha == 0] = 0
    return Image.fromarray(out, "RGBA")


def back_layer(background, size):
    return background.resize(size, Image.LANCZOS)


def write_json(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


os.makedirs(CATALOG, exist_ok=True)
write_json(f"{CATALOG}/Contents.json", {"info": INFO})
if PREVIEW:
    os.makedirs(PREVIEW, exist_ok=True)

for name in VARIANTS:
    src = f"{RES}/DuskIcon{name}.icon/Assets"
    background = Image.open(f"{src}/background.png").convert("RGB")
    mark_colours = Image.fromarray(
        padded_colours(np.array(Image.open(f"{src}/mark.png").convert("RGBA"))).round().astype(np.uint8), "RGB"
    )
    stack_dir = f"{CATALOG}/DuskIcon{name}.imagestack"
    if os.path.isdir(stack_dir):
        shutil.rmtree(stack_dir)
    os.makedirs(stack_dir)
    write_json(f"{stack_dir}/Contents.json", {
        "info": INFO,
        "layers": [{"filename": "Front.imagestacklayer"}, {"filename": "Back.imagestacklayer"}],
    })
    for layer in ("Front", "Back"):
        layer_dir = f"{stack_dir}/{layer}.imagestacklayer"
        os.makedirs(f"{layer_dir}/Content.imageset")
        write_json(f"{layer_dir}/Contents.json", {"info": INFO})
        images = []
        for scale, size, front_name in ENTRIES:
            filename = front_name if layer == "Front" else BACK_NAMES[size]
            path = f"{layer_dir}/Content.imageset/{filename}"
            if layer == "Front":
                front_layer(mark_colours, f"{PRIMARY_STACK}/Front.imagestacklayer/Content.imageset/{front_name}").save(path, optimize=True)
            else:
                back_layer(background, size).save(path, optimize=True)
            images.append({"filename": filename, "idiom": "tv", "scale": scale})
        write_json(f"{layer_dir}/Content.imageset/Contents.json", {"images": images, "info": INFO})

    if PREVIEW:
        # Flattened like the Home Screen at rest: @2x Front centred on @2x Back.
        w, h = 800, 480
        icon = back_layer(background, (w, h)).convert("RGBA")
        front = front_layer(mark_colours, f"{PRIMARY_STACK}/Front.imagestacklayer/Content.imageset/432.png")
        icon.alpha_composite(front, ((w - front.width) // 2, (h - front.height) // 2))
        mask = Image.new("L", (w, h), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, w - 1, h - 1), radius=24, fill=255)
        icon.putalpha(mask)
        icon.save(f"{PREVIEW}/tv-icon-{name}.png")
    print(name)
