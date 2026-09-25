"""Composes the App Review screenshot for the Downtray Pro in-app purchase.

App Store Connect accepts only the app's screenshot sizes for this image: 16:10, one of
1280x800, 1440x900, 2560x1600 or 2880x1800, PNG or JPEG, no alpha channel. It is seen by
App Review only and must clearly show the item being sold, so the image puts the two
places the purchase is offered side by side: Settings with the Pro section first, and
the popover with the Pro sheet. Both are the bridge's own renders (see docs/app-store.md,
"In-app purchase review information").

Usage: python3 scripts/make-iap-review-shot.py <dir-with-captures> [out.png]
  <dir> holds "Downtray Settings.png" (880x1344) and "panel.png" (720x1040) from the
  bridge's screenshot command. The 64-pixel empty title strip on the Settings render
  is cropped off.
"""
import sys

from PIL import Image, ImageDraw, ImageFilter

W, H = 2560, 1600
BG = (28, 28, 30)  # macOS dark window chrome, so the captures read as windows on a desk
RADIUS = 24
GAP = 180
TITLE_STRIP = 64

src = sys.argv[1].rstrip("/")
out = sys.argv[2] if len(sys.argv) > 2 else f"{src}/downtray-pro-iap-review-2560x1600.png"

settings = Image.open(f"{src}/Downtray Settings.png").convert("RGB")
settings = settings.crop((0, TITLE_STRIP, settings.width, settings.height))
panel = Image.open(f"{src}/panel.png").convert("RGB")


def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.width - 1, img.height - 1), radius, fill=255)
    rgba = img.convert("RGBA")
    rgba.putalpha(mask)
    return rgba


canvas = Image.new("RGBA", (W, H), BG + (255,))
total = settings.width + GAP + panel.width
x = (W - total) // 2
for img in (settings, panel):
    y = (H - img.height) // 2
    tile = rounded(img, RADIUS)
    shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 140), (x, y + 18), tile.split()[3])
    shadow = shadow.filter(ImageFilter.GaussianBlur(28))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(tile, (x, y))
    x += img.width + GAP

canvas.convert("RGB").save(out, optimize=True)
print("wrote", out, canvas.size)
