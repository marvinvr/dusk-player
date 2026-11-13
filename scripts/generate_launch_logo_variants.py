"""Generates the launch splash logo for every alternate app icon, so the
SwiftUI splash (`LaunchSplash.swift`) shows the mark the user picked.

No new art: every alternate's mark.png is the primary mark's alpha recolored
on the same 1024 canvas. This maps each mark's colours into LaunchLogo's
980 x 1130 frame (the fit is measured from the alpha moments of the two
primary artworks, which line up to well under a pixel) and keeps LaunchLogo's
own high-resolution alpha, so every variant has exactly the default
silhouette and the splash animation anchors stay valid.

Usage (needs Pillow + NumPy, e.g. `uv run --with numpy --with pillow`):
    python3 scripts/generate_launch_logo_variants.py Dusk/Resources

Writes Assets.xcassets/LaunchLogo<Variant>.imageset/logo.png + Contents.json."""
import json
import os
import sys

import numpy as np
from PIL import Image, ImageFilter

RES = sys.argv[1]
CATALOG = f"{RES}/Assets.xcassets"
VARIANTS = ["Dawn", "Midnight", "Neon", "Mono", "Aurora", "GoldenHour", "Velvet", "Emerald", "Gilded", "Sapphire"]

launch = Image.open(f"{CATALOG}/LaunchLogo.imageset/dusk_icon_new_transparent.png").convert("RGBA")
launch_alpha = np.array(launch)[..., 3]
primary = np.array(Image.open(f"{RES}/DuskIcon.icon/Assets/dusk_icon_new_transparentcropped.png").convert("RGBA"))


def moments(a):
    a = a.astype(np.float64)
    yy, xx = np.mgrid[0:a.shape[0], 0:a.shape[1]]
    w = a.sum()
    cx, cy = (a * xx).sum() / w, (a * yy).sum() / w
    return cx, cy, np.sqrt((a * ((xx - cx) ** 2 + (yy - cy) ** 2)).sum() / w)


# Launch = scale * mark + offset.
lcx, lcy, lr = moments(launch_alpha)
mcx, mcy, mr = moments(primary[..., 3])
scale = lr / mr
tx, ty = lcx - scale * mcx, lcy - scale * mcy


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


contents = {
    "images": [{"filename": "logo.png", "idiom": "universal"}],
    "info": {"author": "xcode", "version": 1},
}

for name in VARIANTS:
    mark = np.array(Image.open(f"{RES}/DuskIcon{name}.icon/Assets/mark.png").convert("RGBA"))
    colours = Image.fromarray(padded_colours(mark).round().astype(np.uint8), "RGB")
    mapped = colours.transform(
        launch.size,
        Image.AFFINE,
        (1 / scale, 0, -tx / scale, 0, 1 / scale, -ty / scale),
        resample=Image.BICUBIC,
    )
    logo = np.dstack([np.array(mapped), launch_alpha])
    # Fully transparent pixels carry no colour; zero them so the PNG stays small.
    logo[launch_alpha == 0] = 0
    out_dir = f"{CATALOG}/LaunchLogo{name}.imageset"
    os.makedirs(out_dir, exist_ok=True)
    Image.fromarray(logo, "RGBA").save(f"{out_dir}/logo.png", optimize=True)
    with open(f"{out_dir}/Contents.json", "w") as f:
        json.dump(contents, f, indent=2)
        f.write("\n")
    print(name)
