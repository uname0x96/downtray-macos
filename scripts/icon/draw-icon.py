"""Draws the app icon at 1024 px: a macOS-style squircle with a tray and a document dropping
in. Renders at 4x and downsamples for clean edges. Usage: python3 draw-icon.py out.png"""
import math
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 4                    # supersampling
N = 1024 * S
out = sys.argv[1] if len(sys.argv) > 1 else "icon-1024.png"


def superellipse(size, inset, n=5.0):
    """Apple-style continuous corner ("squircle") polygon."""
    cx = cy = size / 2
    r = size / 2 - inset
    pts = []
    for i in range(720):
        t = 2 * math.pi * i / 720
        c, s_ = math.cos(t), math.sin(t)
        x = cx + r * math.copysign(abs(c) ** (2 / n), c)
        y = cy + r * math.copysign(abs(s_) ** (2 / n), s_)
        pts.append((x, y))
    return pts


def gradient(size, top, bottom):
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        t = y / (size - 1)
        col = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        for x in range(size):
            px[x, y] = col
    return img


# --- tile -------------------------------------------------------------------------------
inset = N * 0.1
mask = Image.new("L", (N, N), 0)
ImageDraw.Draw(mask).polygon(superellipse(N, inset), fill=255)

tile = gradient(N, (78, 150, 255), (22, 74, 214))
# a soft light sheen in the upper left
sheen = Image.new("L", (N, N), 0)
ImageDraw.Draw(sheen).ellipse((-N * 0.2, -N * 0.45, N * 0.9, N * 0.55), fill=90)
sheen = sheen.filter(ImageFilter.GaussianBlur(N * 0.08))
tile = Image.composite(Image.new("RGB", (N, N), (255, 255, 255)), tile, sheen.point(lambda v: v))
tile = Image.blend(gradient(N, (78, 150, 255), (22, 74, 214)), tile, 0.35)

canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))
# drop shadow
shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
shadow.paste((0, 0, 0, 110), (0, 0), mask)
shadow = shadow.transform((N, N), Image.AFFINE, (1, 0, 0, 0, 1, -N * 0.012)).filter(ImageFilter.GaussianBlur(N * 0.018))
canvas.alpha_composite(shadow)
canvas.paste(tile, (0, 0), mask)

# --- glyph ------------------------------------------------------------------------------
g = Image.new("RGBA", (N, N), (0, 0, 0, 0))
d = ImageDraw.Draw(g)
white = (255, 255, 255, 255)
soft = (255, 255, 255, 150)

# Tray: a wide rounded box with an open top and a front lip.
tw, th = N * 0.56, N * 0.20
tx, ty = (N - tw) / 2, N * 0.56
line = N * 0.052
d.rounded_rectangle((tx, ty, tx + tw, ty + th), radius=N * 0.045, outline=white, width=int(line))
# fill the tray's front face slightly so it reads as solid
d.rounded_rectangle((tx + line, ty + th * 0.45, tx + tw - line, ty + th - line), radius=N * 0.02, fill=soft)
# handle notch on the front
d.rounded_rectangle((N / 2 - N * 0.07, ty + th * 0.55, N / 2 + N * 0.07, ty + th * 0.55 + line * 0.7),
                    radius=line * 0.35, fill=(22, 74, 214, 255))

# Document with a folded corner, dropping into the tray.
dw, dh = N * 0.26, N * 0.30
dx, dy = N / 2 - dw / 2, N * 0.22
fold = N * 0.07
doc = [(dx, dy), (dx + dw - fold, dy), (dx + dw, dy + fold), (dx + dw, dy + dh), (dx, dy + dh)]
d.polygon(doc, fill=white)
d.polygon([(dx + dw - fold, dy), (dx + dw - fold, dy + fold), (dx + dw, dy + fold)], fill=(200, 220, 255, 255))
# text lines on the document
for i in range(3):
    ly = dy + N * 0.10 + i * N * 0.045
    d.rounded_rectangle((dx + N * 0.045, ly, dx + dw - N * 0.045 - (N * 0.05 if i == 2 else 0), ly + N * 0.018),
                        radius=N * 0.009, fill=(78, 150, 255, 255))

# Down arrow chevron between the document and the tray, in the lighter brand colour.
ax, ay = N / 2, N * 0.545
head = N * 0.055
d.line([(ax - head, ay - head * 0.7), (ax, ay), (ax + head, ay - head * 0.7)], fill=white,
       width=int(line * 0.8), joint="curve")

# Unread badge, the app's signature.
r = N * 0.075
bx, by = N * 0.79, N * 0.21
d.ellipse((bx - r, by - r, bx + r, by + r), fill=(255, 92, 82, 255), outline=white, width=int(N * 0.012))

# subtle glyph shadow for depth
gs = Image.new("RGBA", (N, N), (0, 0, 0, 0))
gs.paste((0, 0, 0, 70), (0, 0), g.split()[3])
gs = gs.transform((N, N), Image.AFFINE, (1, 0, 0, 0, 1, -N * 0.008)).filter(ImageFilter.GaussianBlur(N * 0.01))
canvas.alpha_composite(gs)
canvas.alpha_composite(g)

canvas = canvas.resize((1024, 1024), Image.LANCZOS)
canvas.save(out)
print("wrote", out)
