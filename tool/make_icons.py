"""Draws the Fitmeasure launcher icons into android/app/src/main/res.

A lime progress ring around a dumbbell, on the app's dark background.
Produces the legacy icon, the adaptive icon's foreground and a monochrome
layer for Android 13 themed icons. Run from the repo root:

    python3 tool/make_icons.py   (needs Pillow)
"""

import math
import os

from PIL import Image, ImageDraw, ImageFilter

RES = 'android/app/src/main/res'
BG = (12, 13, 17)
BG_LIGHT = (28, 31, 38)
LIME = (184, 243, 74)
LIME_LIGHT = (222, 255, 160)
WHITE = (244, 245, 247)
SS = 4  # supersampling for smooth edges

DENSITIES = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def draw_mark(size, scale, mono=False):
    """Ring and dumbbell on a transparent canvas; [scale] is the ring's
    outer diameter as a fraction of [size]."""
    s = size * SS
    img = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    c = s / 2
    outer = s * scale / 2
    width = outer * 0.2
    r = outer - width / 2

    # Soft glow behind the ring.
    if not mono:
        glow = Image.new('RGBA', (s, s), (0, 0, 0, 0))
        gd = ImageDraw.Draw(glow)
        gd.ellipse(
            [c - outer, c - outer, c + outer, c + outer],
            outline=LIME + (90,),
            width=round(width * 1.2),
        )
        img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(s * 0.03)))

    d = ImageDraw.Draw(img)
    # Track, then the arc drawn as many small round-capped steps so it can
    # fade from light to lime.
    track = (255, 255, 255, 60) if mono else (255, 255, 255, 22)
    d.ellipse([c - r - width / 2, c - r - width / 2, c + r + width / 2, c + r + width / 2],
              outline=track, width=round(width))
    start, sweep = -90, 290
    steps = 240
    for i in range(steps + 1):
        a = math.radians(start + sweep * i / steps)
        x, y = c + r * math.cos(a), c + r * math.sin(a)
        col = WHITE if mono else lerp(LIME_LIGHT, LIME, min(1, i / (steps * 0.6)))
        d.ellipse([x - width / 2, y - width / 2, x + width / 2, y + width / 2], fill=col + (255,))

    # Dumbbell: a bar with two plates each side, centred.
    fg = WHITE + (255,)
    bar_w, bar_h = outer * 0.95, outer * 0.12
    d.rounded_rectangle([c - bar_w / 2, c - bar_h / 2, c + bar_w / 2, c + bar_h / 2],
                        radius=bar_h / 2, fill=fg)
    for side in (-1, 1):
        for (dx, w, h) in ((0.30, 0.13, 0.62), (0.45, 0.10, 0.42)):
            x = c + side * outer * dx
            d.rounded_rectangle([x - outer * w / 2, c - outer * h / 2,
                                 x + outer * w / 2, c + outer * h / 2],
                                radius=outer * w * 0.35, fill=fg)
    return img.resize((size, size), Image.LANCZOS)


def legacy(size):
    s = size * SS
    img = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    # Circle with a gentle top-left light.
    bg = Image.new('RGBA', (s, s), BG + (255,))
    light = Image.new('RGBA', (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(light).ellipse([-s * 0.3, -s * 0.3, s * 0.7, s * 0.7], fill=BG_LIGHT + (255,))
    bg = Image.alpha_composite(bg, light.filter(ImageFilter.GaussianBlur(s * 0.18)))
    mask = Image.new('L', (s, s), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, s - 1, s - 1], fill=255)
    img.paste(bg, (0, 0), mask)
    img = img.resize((size, size), Image.LANCZOS)
    return Image.alpha_composite(img, draw_mark(size, 0.66))


def save(img, density, name):
    folder = os.path.join(RES, f'mipmap-{density}')
    os.makedirs(folder, exist_ok=True)
    img.save(os.path.join(folder, name), optimize=True)


for density, k in DENSITIES.items():
    save(legacy(round(48 * k)), density, 'ic_launcher.png')
    # Adaptive layers are 108dp; keep the mark inside the 66dp safe zone.
    save(draw_mark(round(108 * k), 0.56), density, 'ic_launcher_foreground.png')
    save(draw_mark(round(108 * k), 0.56, mono=True), density, 'ic_launcher_monochrome.png')

# A large copy for the README and store-style listings.
os.makedirs('assets/icon', exist_ok=True)
legacy(512).save('assets/icon/icon-512.png', optimize=True)
print('icons written')
