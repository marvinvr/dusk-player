"""Generates the Director's Cut icons (Eclipse, Velvet) in the same layer
layout as the other alternates: background.png (opaque gradient) + mark.png
(the Dusk mark's alpha, recolored), plus a 512px flattened preview.

Usage (needs Pillow + NumPy):
    python3 scripts/generate_directors_cut_icons.py Dusk/Resources <out-dir>

Writes <out-dir>/DuskIcon{Eclipse,Velvet}.icon/Assets/{background,mark}.png
and <out-dir>/IconPreview{Eclipse,Velvet}.png. Copy them into the .icon
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

# ---------------------------------------------------------------- Eclipse
# A black sun: near-black field, a glowing corona ring centred on the mark,
# and the mark itself as the dark occluding disc with a thin warm rim light.
cx, cy = 548, 513
r = np.hypot(xx - cx, yy - cy)
R = 426
ring = np.exp(-((r - R) / 16) ** 2)
halo = np.exp(-((r - R) / 70) ** 2) * (r > R - 30)
outer = np.exp(-np.maximum(r - R, 0) / 150) * (r > R)
# Slightly uneven corona (stronger toward the top-right, like a diamond-ring moment).
ang = np.arctan2(yy - cy, xx - cx)
flare = 1 + 0.35 * np.exp(-((ang + 0.9) / 0.5) ** 2)
glow_w = (1.0 * ring + 0.55 * halo + 0.28 * outer) * flare
core_col = hexc("#FFF4E0")
mid_col = hexc("#FFB45C")
far_col = hexc("#C2542E")
bg = vertical(hexc("#0B0A10"), hexc("#060509"), hexc("#020204"))
corona = (core_col * ring[..., None] + mid_col * (0.55 * halo)[..., None] + far_col * (0.28 * outer)[..., None]) * flare[..., None]
bg_e = 1 - (1 - bg) * (1 - np.clip(corona, 0, 1))  # screen
save_dir = f"{OUT}/DuskIconEclipse.icon/Assets"; os.makedirs(save_dir, exist_ok=True)
save_rgb(bg_e, f"{save_dir}/background.png")
# Mark: near-black with a warm inner rim where it faces the corona.
inner = alpha - blur(alpha, 5)
rim = np.clip(inner * 2.4, 0, 1) * 0.7
mark_e = ramp([(0, hexc("#3A2F2A")), (1, hexc("#1C1715"))], t) * shade[..., None]
mark_e = mark_e * (1 - rim[..., None]) + hexc("#FFC98A")[None, None] * rim[..., None] * 0.85 + mark_e * rim[..., None] * 0.15
save_rgba(mark_e, alpha, f"{save_dir}/mark.png")
preview(bg_e, mark_e, alpha, f"{OUT}/IconPreviewEclipse.png")

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
print("ok")
