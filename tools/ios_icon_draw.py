#!/usr/bin/env python3
"""The iOS app's own icon, drawn from nothing (no game art, no logos):

    tools/ios_icon_draw.py ios/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png

A city at night: a sky from deep blue to violet, a skyline with lit
windows, a road running to the horizon and the long-exposure streaks of
tail lights (red) and headlights (white-gold) sweeping along it, with a
glow. 1024x1024, opaque, square corners (iOS rounds them). Drawn at 2x
and scaled down; the windows come from a fixed seed, so the same file
every time.
"""
import math
import random
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

S = 2048                      # drawn at 2x
HORIZON = int(S * 0.56)
VANISH = (S * 0.5, HORIZON + S * 0.01)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def sky(im):
    d = ImageDraw.Draw(im)
    top, mid, low = (8, 10, 34), (38, 20, 78), (150, 52, 92)
    for y in range(HORIZON + 40):
        t = y / (HORIZON + 40)
        c = lerp(top, mid, t / 0.7) if t < 0.7 else lerp(mid, low, (t - 0.7) / 0.3)
        d.line([(0, y), (S, y)], fill=c)
    # a soft glow over the city where the road meets the sky
    glow = Image.new("L", (S, S), 0)
    ImageDraw.Draw(glow).ellipse([S * 0.12, HORIZON - S * 0.30, S * 0.88, HORIZON + S * 0.12], fill=170)
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.07))
    im.paste((255, 96, 120), (0, 0), glow)


def skyline(im, rnd):
    d = ImageDraw.Draw(im)
    x = -20
    towers = []
    while x < S:
        w = rnd.randint(70, 190)
        # taller towers towards the middle, like a downtown seen down a road
        mid = 1 - abs((x + w / 2) / S - 0.5) * 1.6
        h = int(S * (0.07 + 0.26 * max(mid, 0.12) * rnd.uniform(0.55, 1.0)))
        towers.append((x, w, h))
        x += w - rnd.randint(0, 24)
    for x, w, h in towers:
        top = HORIZON - h
        shade = rnd.randint(14, 26)
        d.rectangle([x, top, x + w, HORIZON + 30], fill=(shade, shade - 4, shade + 16))
        if rnd.random() < 0.3:                      # a spire
            d.rectangle([x + w // 2 - 4, top - rnd.randint(40, 110), x + w // 2 + 4, top], fill=(shade, shade - 4, shade + 16))
        # windows
        for wy in range(top + 18, HORIZON - 10, 26):
            for wx in range(x + 12, x + w - 16, 22):
                if rnd.random() < 0.38:
                    c = rnd.choice([(255, 214, 140), (255, 190, 110), (180, 220, 255), (255, 236, 190)])
                    a = rnd.uniform(0.35, 1.0)
                    d.rectangle([wx, wy, wx + 9, wy + 13], fill=lerp((20, 16, 40), c, a))


def road(im):
    d = ImageDraw.Draw(im)
    vx, vy = VANISH
    # the ground and the road's wedge
    for y in range(HORIZON, S):
        t = (y - HORIZON) / (S - HORIZON)
        d.line([(0, y), (S, y)], fill=lerp((22, 14, 40), (8, 6, 16), t))
    d.polygon([(vx - 8, vy), (vx + 8, vy), (S * 1.05, S), (-S * 0.05, S)], fill=(16, 14, 26))
    # lane marks
    for i in range(9):
        t0, t1 = (i / 9) ** 1.8, ((i + 0.45) / 9) ** 1.8
        y0, y1 = vy + (S - vy) * t0, vy + (S - vy) * t1
        w0, w1 = 2 + 26 * t0, 2 + 26 * t1
        d.polygon([(vx - w0 / 2, y0), (vx + w0 / 2, y0), (vx + w1 / 2, y1), (vx - w1 / 2, y1)], fill=(120, 110, 90))


def streak(layer, color, x_far, x_near, width_near, bend):
    """A light trail from near the vanishing point to the bottom edge."""
    d = ImageDraw.Draw(layer)
    vx, vy = VANISH
    pts = []
    for i in range(121):
        t = i / 120
        e = t ** 1.9                                 # perspective: slow far away
        y = vy + 6 + (S + 80 - vy) * e
        x = vx + (x_far - vx) * (1 - e) + (x_near - vx) * e + bend * math.sin(e * math.pi) * S
        pts.append((x, y, 1 + width_near * e))
    for (x0, y0, w0), (x1, y1, w1) in zip(pts, pts[1:]):
        d.line([(x0, y0), (x1, y1)], fill=color, width=max(1, int((w0 + w1) / 2)))


def lights(im):
    trails = Image.new("RGB", (S, S), (0, 0, 0))
    vx = VANISH[0]
    # tail lights going away on the right, headlights coming on the left
    for dx, w, c in [(0.26, 80, (255, 30, 24)), (0.36, 60, (255, 64, 36)), (0.45, 40, (255, 118, 52)),
                     (0.52, 24, (255, 176, 90))]:
        streak(trails, c, vx + 12, vx + dx * S, w, 0.07)
    for dx, w, c in [(-0.28, 76, (255, 232, 180)), (-0.38, 52, (255, 206, 128)), (-0.47, 30, (255, 250, 232))]:
        streak(trails, c, vx - 12, vx + dx * S, w, -0.06)
    # light adds up: a wide bloom, a tight one, and the trails themselves
    out = im
    for radius, k in [(S * 0.030, 0.85), (S * 0.010, 0.9), (1.5, 1.0)]:
        layer = trails.filter(ImageFilter.GaussianBlur(radius))
        out = ImageChops.add(out, Image.eval(layer, lambda v, k=k: int(v * k)))
    return out


def vignette(im):
    m = Image.new("L", (S, S), 0)
    ImageDraw.Draw(m).ellipse([-S * 0.25, -S * 0.2, S * 1.25, S * 1.3], fill=255)
    m = m.filter(ImageFilter.GaussianBlur(S * 0.12))
    dark = Image.new("RGB", (S, S), (0, 0, 0))
    return Image.composite(im, Image.blend(dark, im, 0.45), m)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    rnd = random.Random(1103)
    im = Image.new("RGB", (S, S), (0, 0, 0))
    sky(im)
    skyline(im, rnd)
    road(im)
    im = lights(im)
    im = vignette(im)
    im = im.resize((1024, 1024), Image.LANCZOS)
    Image.frombytes("RGB", im.size, im.tobytes()).save(sys.argv[1], format="PNG", optimize=True)
    print("  icon: %s (1024x1024, drawn)" % sys.argv[1])


if __name__ == "__main__":
    main()
