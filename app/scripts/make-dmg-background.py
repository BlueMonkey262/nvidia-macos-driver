#!/usr/bin/env python3
"""Draw the disk image's background (600x360): a quiet light field with an arrow from the app to Applications.
Run on any machine with Pillow:  python3 make-dmg-background.py [OUT.png]
Copyright (c) 2026 BlueMonkey
SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0"""
import sys
from PIL import Image, ImageDraw, ImageFont

W, H = 600, 360   # shorter than the window's visible area (taller windows chrome on macOS 26): a taller picture makes Finder add a scroll bar
out = sys.argv[1] if len(sys.argv) > 1 else "dmg-background.png"
img = Image.new("RGB", (W, H), (246, 246, 248))
d = ImageDraw.Draw(img)
for y in range(H):                       # light gray at the top fading to white at the bottom and the right edge, so the strip of
    for x in range(0, W, 1):             # window left over around the picture is not a visible seam
        t = y / H; u = max(0.0, (x - (W - 60)) / 60.0)
        k = max(t, u)
        d.point((x, y), fill=(int(244 + 11 * k), int(244 + 11 * k), int(247 + 8 * k)))

# arrow between the app (x~330) and Applications (x~540), at the icon row (y~205)
y = 180; x0, x1 = 380, 450
col = (170, 174, 184)
d.rounded_rectangle([x0, y - 5, x1 - 14, y + 5], radius=5, fill=col)
d.polygon([(x1 - 22, y - 20), (x1 + 6, y), (x1 - 22, y + 20)], fill=col)

def font(size):
    for p in ("/System/Library/Fonts/SFNS.ttf", "/System/Library/Fonts/Helvetica.ttc",
              "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf", "/usr/share/fonts/TTF/DejaVuSans.ttf",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(p, size)
        except OSError:
            pass
    return ImageFont.load_default()

def centered(text, cx, cy, size, fill):
    f = font(size); w = d.textlength(text, font=f)
    d.text((cx - w / 2, cy), text, font=f, fill=fill)

centered("Drag the app to Applications", 415, 300, 14, (140, 144, 154))
centered("Read this first", 110, 300, 13, (140, 144, 154))
img.save(out)
print("wrote", out, img.size)
