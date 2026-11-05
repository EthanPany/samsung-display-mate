#!/usr/bin/env python3
"""Draws the app icon: a glowing monitor on a deep blue tile. Needs Pillow."""
import json, os, sys
from PIL import Image, ImageDraw, ImageFilter

S = 2048  # drawn at 2x and scaled down for clean edges

def vgrad(size, top, bottom):
    g = Image.new("RGBA", (1, size[1]))
    for y in range(size[1]):
        t = y / max(size[1] - 1, 1)
        g.putpixel((0, y), tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))
    return g.resize(size)

def rounded(size, box, r):
    m = Image.new("L", size, 0)
    ImageDraw.Draw(m).rounded_rectangle(box, r, fill=255)
    return m

canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# Tile on Apple's macOS grid: 824 of 1024 with a soft shadow.
m = (S - 1648) // 2
tile = (m, m, S - m, S - m)
radius = 370
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((m, m + 24, S - m, S - m + 24), radius, fill=(0, 0, 0, 110))
canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(36)))
canvas.paste(vgrad((S, S), (34, 60, 190, 255), (8, 12, 52, 255)), (0, 0), rounded((S, S), tile, radius))

# Color wash behind the screen.
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse((470, 420, 1580, 1370), fill=(90, 150, 255, 150))
glow = glow.filter(ImageFilter.GaussianBlur(170))
tile_mask = rounded((S, S), tile, radius)
glow.putalpha(Image.composite(glow.getchannel("A"), Image.new("L", (S, S), 0), tile_mask))
canvas.alpha_composite(glow)

# Monitor stand.
d = ImageDraw.Draw(canvas)
d.rounded_rectangle((930, 1370, 1118, 1560), 22, fill=(205, 218, 245, 255))
d.rounded_rectangle((720, 1520, 1328, 1590), 35, fill=(232, 240, 255, 255))

# Monitor body and screen.
d.rounded_rectangle((430, 540, 1618, 1400), 84, fill=(238, 244, 255, 255))
screen = (476, 586, 1572, 1354)
canvas.paste(vgrad((S, S), (22, 34, 92, 255), (6, 9, 34, 255)), (0, 0), rounded((S, S), screen, 48))

# Level bars: quiet on the left, loud on the right, in the OLED's warm-to-cool glow.
bars = [(650, 180), (820, 310), (990, 450), (1160, 310), (1330, 180)]
colors = [(255, 186, 92), (255, 132, 142), (214, 124, 255), (120, 160, 255), (92, 222, 255)]
glowbars = Image.new("RGBA", (S, S), (0, 0, 0, 0))
g = ImageDraw.Draw(glowbars)
cy = (586 + 1354) // 2
for (x, h), c in zip(bars, colors):
    g.rounded_rectangle((x, cy - h // 2, x + 68, cy + h // 2), 34, fill=c + (255,))
blur = glowbars.filter(ImageFilter.GaussianBlur(46))
blur.putalpha(Image.composite(blur.getchannel("A"), Image.new("L", (S, S), 0), rounded((S, S), screen, 48)))
canvas.alpha_composite(blur)
canvas.alpha_composite(glowbars)

# Glass sheen across the top of the tile.
sheen = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(sheen).rounded_rectangle((m + 6, m + 6, S - m - 6, S - m - 6), radius - 6, outline=(255, 255, 255, 70), width=6)
canvas.alpha_composite(sheen)

icon = canvas.resize((1024, 1024), Image.LANCZOS)
out = sys.argv[1]
os.makedirs(out, exist_ok=True)
images = []
for pt in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        name = f"icon_{pt}x{pt}@{scale}x.png"
        icon.resize((pt * scale, pt * scale), Image.LANCZOS).save(os.path.join(out, name))
        images.append({"idiom": "mac", "size": f"{pt}x{pt}", "scale": f"{scale}x", "filename": name})
json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, open(os.path.join(out, "Contents.json"), "w"), indent=2)
