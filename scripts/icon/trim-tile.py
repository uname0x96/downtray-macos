"""Turns a generated picture of an icon tile on a white background into a 1024 px PNG with a
transparent margin, the way the asset catalog wants it. Usage: trim-tile.py in.png out.png"""
import sys
from PIL import Image, ImageChops

src, dst = sys.argv[1], sys.argv[2]
img = Image.open(src).convert("RGBA")
# Bounding box of everything that is not (near) white.
bg = Image.new("RGBA", img.size, (255, 255, 255, 255))
diff = ImageChops.difference(img, bg).convert("L").point(lambda v: 255 if v > 24 else 0)
box = diff.getbbox() or (0, 0, img.width, img.height)
tile = img.crop(box)
side = max(tile.size)
square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
square.paste(tile, ((side - tile.width) // 2, (side - tile.height) // 2))
# Make the white outside the tile transparent (flood from the corners).
px = square.load()
from collections import deque
seen = set()
q = deque([(0, 0), (side - 1, 0), (0, side - 1), (side - 1, side - 1)])
while q:
    x, y = q.popleft()
    if (x, y) in seen or not (0 <= x < side and 0 <= y < side):
        continue
    r, g, b, a = px[x, y]
    if a == 0 or min(r, g, b) < 225:
        continue
    seen.add((x, y))
    px[x, y] = (0, 0, 0, 0)
    q.extend([(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)])
# Tile occupies 80 % of the canvas, like Apple's grid.
tile_side = int(1024 * 0.8)
square = square.resize((tile_side, tile_side), Image.LANCZOS)
out = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
out.paste(square, ((1024 - tile_side) // 2, (1024 - tile_side) // 2), square)
out.save(dst)
