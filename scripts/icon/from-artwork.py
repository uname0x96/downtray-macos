"""Cuts an app-icon tile out of a generated picture (a coloured tile on a neutral background,
shadow included) and writes the 1024 px PNG the asset catalog wants: transparent outside the
tile, tile at 80 % of the canvas. Usage: from-artwork.py in.png out.png"""
import sys
from collections import deque
from PIL import Image, ImageFilter

src, dst = sys.argv[1], sys.argv[2]
img = Image.open(src).convert("RGBA")
w, h = img.size
# The tile is the saturated region; background and shadow are neutral.
sat = img.convert("HSV").split()[1].point(lambda v: 255 if v > 40 else 0)
# Everything reachable from the corners through unsaturated pixels is outside; the rest
# (including the white glyph enclosed by the tile) is the tile.
px = sat.load()
outside = Image.new("L", (w, h), 0)
op = outside.load()
q = deque([(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)])
while q:
    x, y = q.popleft()
    if not (0 <= x < w and 0 <= y < h) or op[x, y] or px[x, y]:
        continue
    op[x, y] = 255
    q.extend([(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)])
mask = outside.point(lambda v: 0 if v else 255).filter(ImageFilter.GaussianBlur(1.2))
box = mask.point(lambda v: 255 if v > 128 else 0).getbbox()
tile = img.crop(box)
tile.putalpha(mask.crop(box))
# Apple icons are square; a slightly oblong tile is stretched rather than letterboxed.
tile_side = int(1024 * 0.8)
square = tile.resize((tile_side, tile_side), Image.LANCZOS)
out = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
out.paste(square, ((1024 - tile_side) // 2, (1024 - tile_side) // 2))
out.save(dst)
print("wrote", dst, "tile", box)
