"""Turns a black-on-white glyph into the menu bar template imageset (18 pt at 1x and 2x).
macOS tints a template image itself, so only the alpha matters.
Usage: menubar-template.py glyph.png <MenuBarIcon.imageset dir>"""
import json
import os
import sys
from PIL import Image

src, dest = sys.argv[1], sys.argv[2]
os.makedirs(dest, exist_ok=True)
img = Image.open(src).convert("L")
# Darkness becomes alpha; the off-white paper becomes fully transparent.
alpha = img.point(lambda v: 255 if v < 80 else (0 if v > 200 else int(255 * (200 - v) / 120)))
box = alpha.getbbox()
glyph = alpha.crop(box)
side = max(glyph.size)
pad = int(side * 0.04)
canvas = Image.new("L", (side + 2 * pad, side + 2 * pad), 0)
canvas.paste(glyph, (pad + (side - glyph.width) // 2, pad + (side - glyph.height) // 2))
entries = []
for scale in (1, 2):
    pt = 18
    px = pt * scale
    resized = canvas.resize((px, px), Image.LANCZOS)
    out = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    out.putalpha(resized)
    name = f"menubar@{scale}x.png"
    out.save(os.path.join(dest, name))
    entries.append({"filename": name, "idiom": "mac", "scale": f"{scale}x"})
with open(os.path.join(dest, "Contents.json"), "w") as f:
    json.dump({"images": entries, "info": {"author": "xcode", "version": 1},
               "properties": {"template-rendering-intent": "template"}}, f, indent=2)
print("wrote", dest)
