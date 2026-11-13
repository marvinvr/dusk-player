"""Generates the subscriber icons (Velvet, Emerald, Gilded, Sapphire) in the same layer
layout as the other alternates: background.png (opaque gradient) + mark.png
(the Dusk mark's alpha, recolored), plus a 512px flattened preview.

Usage (needs Pillow + NumPy):
    python3 scripts/generate_directors_cut_icons.py Dusk/Resources <out-dir>

Writes <out-dir>/DuskIcon{Velvet,Emerald,Gilded,Sapphire}.icon/Assets/{background,mark}.png
and <out-dir>/IconPreview{Velvet,Emerald,Gilded,Sapphire}.png. Copy them into the .icon
bundles (icon.json is shared with the other alternates) and the
IconPreview* imagesets."""
import sys, os
import numpy as np
from PIL import Image, ImageFilter

RES = sys.argv[1]
OUT = sys.argv[2]
N = 1024
base = np.array(Image.open(f"{RES}/DuskIcon.icon/Assets/dusk_icon_new_transparentcropped.png").convert("RGBA")).astype(np.float64) / 255
alpha = base[..., 3]
yy, xx = np.mgrid[0:N, 0:N].astype(np.float64)

# Per-tile shading from the primary mark's luminance, normalised around 1 so
# the recolor keeps the original's subtle facet variation.
lum = 0.299 * base[..., 0] + 0.587 * base[..., 1] + 0.114 * base[..., 2]
lum_blur = np.array(Image.fromarray((lum * alpha * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(120))).astype(np.float64) / 255
a_blur = np.array(Image.fromarray((alpha * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(120))).astype(np.float64) / 255
local = np.where(a_blur > 1e-3, lum_blur / np.maximum(a_blur, 1e-3), 1)
shade = np.clip(1 + 0.6 * (lum - local), 0.85, 1.12)

# Diagonal ramp across the mark: top-left -> right tip (like Neon/Golden Hour).
x0, y0, x1, y1 = 248, 172, 849, 512
d = np.array([x1 - x0, y1 - y0]); d = d / np.dot(d, d)
t = np.clip((xx - x0) * d[0] + (yy - y0) * d[1], 0, 1)

def hexc(h):
    return np.array([int(h[i:i + 2], 16) for i in (1, 3, 5)], dtype=np.float64) / 255

def ramp(stops, t):
    out = np.zeros(t.shape + (3,))
    for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
        m = (t >= p0) & (t <= p1)
        u = ((t - p0) / (p1 - p0))[..., None]
        out[m] = (c0 * (1 - u) + c1 * u)[m]
    return out

def vertical(top, mid, bot):
    v = (yy / (N - 1))[..., None]
    lo = top * (1 - 2 * v) + mid * (2 * v)
    hi = mid * (2 - 2 * v) + bot * (2 * v - 1)
    return np.where(v < 0.5, lo, hi)

def save_rgb(arr, path):
    Image.fromarray((np.clip(arr, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB").save(path, optimize=True)

def save_rgba(rgb, a, path):
    img = np.dstack([np.clip(rgb, 0, 1), np.clip(a, 0, 1)])
    Image.fromarray((img * 255 + 0.5).astype(np.uint8), "RGBA").save(path, optimize=True)

def blur(arr, r):
    return np.array(Image.fromarray((np.clip(arr, 0, 1) * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(r))).astype(np.float64) / 255

def preview(bg, mark_rgb, mark_a, path):
    # Flatten like Icon Composer would (mark offset -5.5pt, -1pt), 512px.
    shift_x, shift_y = -5.53125, -1
    m = Image.fromarray((np.dstack([np.clip(mark_rgb, 0, 1), mark_a]) * 255 + 0.5).astype(np.uint8), "RGBA")
    m = m.transform(m.size, Image.AFFINE, (1, 0, -shift_x, 0, 1, -shift_y), resample=Image.BICUBIC)
    b = Image.fromarray((np.clip(bg, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB").convert("RGBA")
    b.alpha_composite(m)
    b.convert("RGB").resize((512, 512), Image.LANCZOS).save(path, optimize=True)

# ---------------------------------------------------------------- Emerald
# Velvet's jewel-tone sibling: a deep emerald field lit by a soft overhead
# spotlight; the mark runs from bright emerald to the same gold tip.
spot = np.exp(-(((xx - 512) / 620) ** 2 + ((yy - 300) / 520) ** 2))
bg_m = vertical(hexc("#0B4430"), hexc("#06291C"), hexc("#02110B"))
bg_m = bg_m * (0.80 + 0.38 * spot[..., None])
save_dir = f"{OUT}/DuskIconEmerald.icon/Assets"; os.makedirs(save_dir, exist_ok=True)
save_rgb(bg_m, f"{save_dir}/background.png")
mark_m = ramp([
    (0.00, hexc("#4FE6A4")),
    (0.55, hexc("#0FA36C")),
    (0.80, hexc("#0B8758")),
    (1.00, hexc("#F2C25E")),
], t) * shade[..., None]
save_rgba(mark_m, alpha, f"{save_dir}/mark.png")
preview(bg_m, mark_m, alpha, f"{OUT}/IconPreviewEmerald.png")

# ---------------------------------------------------------------- Gilded
# Polished gold on black lacquer: alternating light/deep bands across the
# mark read as metal, a faint warm glow sits behind it.
glow = np.exp(-(((xx - 540) / 420) ** 2 + ((yy - 512) / 420) ** 2))
bg_g = vertical(hexc("#17130D"), hexc("#0B0907"), hexc("#040303"))
bg_g = bg_g + hexc("#3A2A10")[None, None] * (0.45 * glow)[..., None]
save_dir = f"{OUT}/DuskIconGilded.icon/Assets"; os.makedirs(save_dir, exist_ok=True)
save_rgb(bg_g, f"{save_dir}/background.png")
mark_g = ramp([
    (0.00, hexc("#FFF0BE")),
    (0.22, hexc("#F0C45A")),
    (0.45, hexc("#B9842A")),
    (0.68, hexc("#F7D57E")),
    (1.00, hexc("#A8721F")),
], t) * shade[..., None]
save_rgba(mark_g, alpha, f"{save_dir}/mark.png")
preview(bg_g, mark_g, alpha, f"{OUT}/IconPreviewGilded.png")

# ---------------------------------------------------------------- Velvet
# Deep cinema-red curtain field with soft vertical folds; the mark runs from
# rich crimson to a touch of gold at the tip.
folds = 0.5 + 0.5 * np.cos(xx / N * 2 * np.pi * 5.5 + 0.6 * np.sin(yy / N * 3))
folds = blur(folds, 18)
bg_v = vertical(hexc("#4A0812"), hexc("#30040B"), hexc("#160105"))
bg_v = bg_v * (0.78 + 0.32 * folds[..., None])
vign = np.clip(1 - 0.35 * ((xx - 512) ** 2 + (yy - 420) ** 2) / (720 ** 2), 0.55, 1)
bg_v = bg_v * vign[..., None]
save_dir = f"{OUT}/DuskIconVelvet.icon/Assets"; os.makedirs(save_dir, exist_ok=True)
save_rgb(bg_v, f"{save_dir}/background.png")
mark_v = ramp([
    (0.00, hexc("#FF5A6E")),
    (0.55, hexc("#E0283F")),
    (0.80, hexc("#C8243A")),
    (1.00, hexc("#F2C25E")),
], t) * shade[..., None]
save_rgba(mark_v, alpha, f"{save_dir}/mark.png")
preview(bg_v, mark_v, alpha, f"{OUT}/IconPreviewVelvet.png")

# ---------------------------------------------------------------- Sapphire
# Polished violet-blue stone: Gilded's banded "polished" ramp in cornflower
# and indigo, soft diagonal light shafts across a deep indigo field.
shaft = blur(0.5 + 0.5 * np.sin((xx * 0.8 + yy * 0.6) / N * 2 * np.pi * 2.2), 30) ** 3
bg_s = vertical(hexc("#1E1A63"), hexc("#100D3C"), hexc("#05041A"))
bg_s = bg_s * (0.86 + 0.28 * shaft[..., None])
vign = np.clip(1 - 0.35 * ((xx - 512) ** 2 + (yy - 420) ** 2) / (720 ** 2), 0.55, 1)
bg_s = bg_s * vign[..., None]
save_dir = f"{OUT}/DuskIconSapphire.icon/Assets"; os.makedirs(save_dir, exist_ok=True)
save_rgb(bg_s, f"{save_dir}/background.png")
mark_s = ramp([
    (0.00, hexc("#D6E0FF")),
    (0.22, hexc("#7F97FF")),
    (0.45, hexc("#3340C4")),
    (0.68, hexc("#8EA2FF")),
    (1.00, hexc("#2A2D9E")),
], t) * shade[..., None]
save_rgba(mark_s, alpha, f"{save_dir}/mark.png")
preview(bg_s, mark_s, alpha, f"{OUT}/IconPreviewSapphire.png")
print("ok")
