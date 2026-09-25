"""Builds the 1024x1024 promotional image for the Downtray Pro in-app purchase.

App Store Connect wants a flattened 1024x1024 PNG or JPEG with no transparency and square
corners (it applies its own rounded mask). The image reuses the app icon's tray-and-arrow
glyph on the icon's teal gradient and adds a gold sparkle to mark the Pro tier. No text, no
price, per Apple's promotional image guidance.

Usage: python3 scripts/icon/make-iap-image.py [out.png]
"""
import math
import sys

from PIL import Image, ImageDraw, ImageFilter

ROOT = __file__.rsplit("/scripts/", 1)[0]
ICON = f"{ROOT}/macOS/Downtray/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png"
OUT = sys.argv[1] if len(sys.argv) > 1 else f"{ROOT}/docs/icons/pro-promo.png"

W = 1024
S = 4  # supersampling for the vector parts
N = W * S

icon = Image.open(ICON).convert("RGBA")
tile_top, tile_bottom = 150, 870  # rows well inside the squircle, clear of its rim
SAMPLE_L, SAMPLE_R = 210, 814  # columns beside the glyph, inside the tile


def base_colour(sy, sx=None):
    """Background colour of the icon at row sy: the two side samples, interpolated across x."""
    left = icon.getpixel((SAMPLE_L, int(sy)))[:3]
    right = icon.getpixel((SAMPLE_R, int(sy)))[:3]
    t = 0.5 if sx is None else (sx - SAMPLE_L) / (SAMPLE_R - SAMPLE_L)
    return tuple(left[i] + (right[i] - left[i]) * t for i in range(3))


# --- background: the icon's vertical gradient stretched to full bleed --------------------
bg = Image.new("RGB", (W, W))
px = bg.load()
for y in range(W):
    sy = tile_top + (tile_bottom - tile_top) * y / (W - 1)
    col = tuple(int(c) for c in base_colour(sy))
    for x in range(W):
        px[x, y] = col
# soft highlight in the upper left, like the icon's sheen
sheen = Image.new("L", (W, W), 0)
ImageDraw.Draw(sheen).ellipse((-W * 0.25, -W * 0.45, W * 0.75, W * 0.45), fill=70)
sheen = sheen.filter(ImageFilter.GaussianBlur(W * 0.12))
bg = Image.composite(Image.new("RGB", (W, W), (255, 255, 255)), bg, sheen)

# --- glyph: lift the white tray and arrow off the icon by whiteness -----------------------
gx0, gy0, gx1, gy1 = 230, 220, 800, 800
region = icon.crop((gx0, gy0, gx1, gy1))
rw, rh = region.size
mask = Image.new("L", (rw, rh), 0)
mp = mask.load()
rp = region.load()
for y in range(rh):
    sy = gy0 + y
    for x in range(rw):
        r, g, b, _ = rp[x, y]
        base = base_colour(sy, gx0 + x)
        # the glyph is white: its darkest channel sits well above the background's
        w = min(r, g, b) - min(base)
        mp[x, y] = max(0, min(255, int((w - 12) / 30 * 255)))
mask = mask.filter(ImageFilter.GaussianBlur(0.6))
glyph = region.copy()
glyph.putalpha(mask)

# scale the glyph down a little so it breathes inside the square
scale = 0.92
glyph = glyph.resize((int(rw * scale), int(rh * scale)), Image.LANCZOS)
gw, gh = glyph.size
gpos = ((W - gw) // 2, int(W * 0.53 - gh / 2))

canvas = bg.convert("RGBA")
shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
shadow.paste((0, 40, 40, 90), gpos, glyph.split()[3])
shadow = shadow.transform((W, W), Image.AFFINE, (1, 0, 0, 0, 1, -W * 0.012)).filter(ImageFilter.GaussianBlur(W * 0.012))
canvas.alpha_composite(shadow)
canvas.alpha_composite(glyph, gpos)

# --- Pro sparkle, drawn at 4x -------------------------------------------------------------
def star(cx, cy, r, inner=0.36):
    pts = []
    for i in range(8):
        a = math.pi / 4 * i - math.pi / 2
        rr = r if i % 2 == 0 else r * inner
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    return pts


layer = Image.new("RGBA", (N, N), (0, 0, 0, 0))
d = ImageDraw.Draw(layer)
gold_top, gold_bottom = (255, 214, 96), (255, 158, 42)
white = (255, 255, 255, 255)
stars = [((0.80, 0.235), 0.088), ((0.685, 0.135), 0.040), ((0.905, 0.105), 0.030)]
for (fx, fy), fr in stars:
    cx, cy, r = fx * N, fy * N, fr * N
    outline = star(cx, cy, r + N * 0.010)
    d.polygon(outline, fill=white)
    # gold fill via a masked vertical gradient
    fill_mask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(fill_mask).polygon(star(cx, cy, r), fill=255)
    grad = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    gp = ImageDraw.Draw(grad)
    y0, y1 = int(cy - r), int(cy + r) + 1
    for y in range(y0, y1):
        t = (y - y0) / max(1, y1 - y0 - 1)
        col = tuple(int(gold_top[i] + (gold_bottom[i] - gold_top[i]) * t) for i in range(3)) + (255,)
        gp.line([(cx - r - 8, y), (cx + r + 8, y)], fill=col)
    layer.paste(grad, (0, 0), fill_mask)

layer = layer.resize((W, W), Image.LANCZOS)
sshadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
sshadow.paste((0, 40, 40, 80), (0, 0), layer.split()[3])
sshadow = sshadow.transform((W, W), Image.AFFINE, (1, 0, 0, 0, 1, -W * 0.01)).filter(ImageFilter.GaussianBlur(W * 0.01))
canvas.alpha_composite(sshadow)
canvas.alpha_composite(layer)

canvas.convert("RGB").save(OUT, optimize=True)
print("wrote", OUT)
