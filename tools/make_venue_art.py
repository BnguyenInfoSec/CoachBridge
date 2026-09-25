#!/usr/bin/env python3
"""Draws Coach Bridge's default venue artwork.

Original flat illustrations — no photographs, logos or trademarks — one per seeded place,
written into the asset catalog as single-scale image sets. Re-run after editing:

    python3 tools/make_venue_art.py
"""
from __future__ import annotations

import json
import math
import os
import random

import numpy as np
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

# Design coordinates. Scenes are composed in this space; everything is drawn at SUPERSAMPLE
# times this and filtered down, which is what makes the edges clean.
W, H = 1200, 800
SUPERSAMPLE = 2

# Portrait output, sized for a 3x iPhone filling the screen. The landscape composition sits as
# a band inside it, with sky extended above and ground below.
OUT_W, OUT_H = 1170, 2532
HORIZON_BIAS = 0.56

OUT = os.path.join(os.path.dirname(__file__), "..", "CoachBridge", "Resources", "Assets.xcassets", "VenueArt")


# ---------------------------------------------------------------- drawing at scale

class ScaledDraw:
    """An ImageDraw that multiplies every coordinate by `k`.

    Lets the scene code stay written in comfortable 1200x800 numbers while the actual raster is
    drawn at k times that and filtered down.
    """

    def __init__(self, img, k):
        self._d = ImageDraw.Draw(img)
        self._k = k

    def _pts(self, xy):
        k = self._k
        if not xy:
            return xy
        if isinstance(xy[0], (int, float)):
            return [v * k for v in xy]
        return [(x * k, y * k) for x, y in xy]

    def _kw(self, kw):
        if "width" in kw and kw["width"] is not None:
            kw["width"] = max(1, int(round(kw["width"] * self._k)))
        return kw

    def line(self, xy, **kw): self._d.line(self._pts(xy), **self._kw(kw))
    def polygon(self, xy, **kw): self._d.polygon(self._pts(xy), **self._kw(kw))
    def ellipse(self, xy, **kw): self._d.ellipse(self._pts(xy), **self._kw(kw))
    def rectangle(self, xy, **kw): self._d.rectangle(self._pts(xy), **self._kw(kw))
    def arc(self, xy, start, end, **kw): self._d.arc(self._pts(xy), start, end, **self._kw(kw))

    def rounded_rectangle(self, xy, radius=0, **kw):
        self._d.rounded_rectangle(self._pts(xy), radius=radius * self._k, **self._kw(kw))


def canvas(color=(0, 0, 0)):
    """A new raster at supersampled size."""
    return Image.new("RGB", (W * SUPERSAMPLE, H * SUPERSAMPLE), color)


def draw_on(img):
    return ScaledDraw(img, SUPERSAMPLE)


# ---------------------------------------------------------------- helpers

def rgb(h: int) -> tuple[int, int, int]:
    return ((h >> 16) & 0xFF, (h >> 8) & 0xFF, h & 0xFF)


def mix(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def vgrad(top, bottom, w=W, h=H, y0=0, y1=None):
    """Vertical gradient image, drawn at supersampled resolution."""
    y1 = h if y1 is None else y1
    img = canvas(bottom)
    d = draw_on(img)
    span = max(1, (y1 - y0) * SUPERSAMPLE)
    for y in range(y0 * SUPERSAMPLE, y1 * SUPERSAMPLE):
        d.line([(0, y), (w * SUPERSAMPLE, y)], fill=mix(top, bottom, (y - y0 * SUPERSAMPLE) / span))
    return img


def band(d, y0, y1, top, bottom):
    """Horizontal band gradient. Steps in sub-pixels so there are no gaps once scaled."""
    step = 1 / SUPERSAMPLE
    span = max(1e-6, y1 - y0)
    y = y0
    while y < y1:
        d.line([(0, y), (W, y)], fill=mix(top, bottom, (y - y0) / span), width=1)
        y += step


def sun(img, x, y, r, color, glow=2.4):
    """Soft disc, drawn on its own layer so the glow doesn't bleed into edges."""
    size = img.size
    k = size[0] / W
    x, y, r = x * k, y * k, r * k
    layer = Image.new("RGB", size, (0, 0, 0))
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(layer).ellipse([x - r, y - r, x + r, y + r], fill=color)
    md = ImageDraw.Draw(mask)
    md.ellipse([x - r * glow, y - r * glow, x + r * glow, y + r * glow], fill=70)
    md.ellipse([x - r, y - r, x + r, y + r], fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(r * 0.55))
    return Image.composite(layer, img, mask)


def shimmer(d, y0, y1, color, rnd, count=70, width=3):
    """Broken horizontal streaks: reads as water without any texture work."""
    for _ in range(count):
        y = rnd.randint(y0, y1)
        t = (y - y0) / max(1, y1 - y0)
        x = rnd.randint(-60, W)
        ln = rnd.randint(40, 260) * (0.4 + t)
        d.line([(x, y), (x + ln, y)], fill=color, width=max(1, int(width * (0.4 + t))))


def clouds(d, rnd, y0, y1, color, n=7):
    for _ in range(n):
        cy = rnd.randint(y0, y1)
        cx = rnd.randint(-100, W)
        w = rnd.randint(140, 420)
        h = rnd.randint(14, 30)
        d.ellipse([cx, cy, cx + w, cy + h], fill=color)
        d.ellipse([cx + w * 0.2, cy - h * 0.6, cx + w * 0.75, cy + h * 0.7], fill=color)


def hill(d, pts, color):
    d.polygon(pts + [(W, H), (0, H)], fill=color)


def ridge(d, base_y, amp, color, seed, steps=24, rough=0.5):
    rnd = random.Random(seed)
    pts = []
    y = base_y
    for i in range(steps + 1):
        x = W * i / steps
        y += rnd.uniform(-amp, amp) * rough
        y = max(base_y - amp * 2, min(base_y + amp * 2, y))
        pts.append((x, y))
    d.polygon(pts + [(W, H), (0, H)], fill=color)
    return pts


def pine(d, x, base, h, color):
    w = h * 0.42
    for i, f in enumerate((1.0, 0.72, 0.46)):
        top = base - h * (0.35 + 0.28 * i)
        d.polygon([(x, top - h * 0.28), (x - w * f, base - h * 0.28 * i), (x + w * f, base - h * 0.28 * i)], fill=color)
    d.rectangle([x - h * 0.035, base - h * 0.06, x + h * 0.035, base], fill=color)


def palm(d, x, base, h, color):
    d.line([(x, base), (x - h * 0.08, base - h)], fill=color, width=max(3, int(h * 0.035)))
    top = (x - h * 0.08, base - h)
    for a in (-160, -130, -95, -60, -25):
        r = math.radians(a)
        cx = top[0] + math.cos(r) * h * 0.34
        cy = top[1] + math.sin(r) * h * 0.20
        d.line([top, (cx, cy)], fill=color, width=max(2, int(h * 0.022)))
        d.line([(cx, cy), (cx + math.cos(r) * h * 0.16, cy + h * 0.10)], fill=color, width=max(2, int(h * 0.018)))


def cable(d, x0, y0, x1, y1, sag, color, width=7, steps=60):
    """Parabolic span: ends at the towers, sagging by `sag` at mid-span."""
    pts = []
    for i in range(steps + 1):
        t = i / steps
        x = x0 + (x1 - x0) * t
        y = y0 + (y1 - y0) * t + sag * (1 - (2 * t - 1) ** 2)
        pts.append((x, y))
    d.line(pts, fill=color, width=width, joint="curve")
    return pts


def road(d, y_far, y_near, w_far, w_near, color, cx=W * 0.5):
    d.polygon([(cx - w_far, y_far), (cx + w_far, y_far), (cx + w_near, y_near), (cx - w_near, y_near)], fill=color)


def dashes(d, y_far, y_near, color, cx=W * 0.5, n=7):
    for i in range(n):
        t0 = i / n
        t1 = t0 + 0.55 / n
        ya = y_far + (y_near - y_far) * (t0 ** 1.8)
        yb = y_far + (y_near - y_far) * (t1 ** 1.8)
        wa = 2 + 10 * (t0 ** 1.8)
        wb = 2 + 10 * (t1 ** 1.8)
        d.polygon([(cx - wa, ya), (cx + wa, ya), (cx + wb, yb), (cx - wb, yb)], fill=color)


def grain(img, amount=5, seed=7):
    """A whisper of noise so the flats don't band on an OLED."""
    rnd = random.Random(seed)
    w, h = img.size
    px = img.load()
    for _ in range(int(w * h * 0.04)):
        x, y = rnd.randrange(w), rnd.randrange(h)
        r, g, b = px[x, y]
        n = rnd.randint(-amount, amount)
        px[x, y] = (max(0, min(255, r + n)), max(0, min(255, g + n)), max(0, min(255, b + n)))
    return img


# ---------------------------------------------------------------- time of day

# Each scene is drawn once, then graded into four times of day — the way a Mac dynamic
# desktop shifts the same photograph rather than shipping four unrelated pictures.
# tint/alpha recolour it, bright/sat set the exposure, lift keeps night shadows from
# crushing to black.
PHASES = {
    "morning": dict(tint=(255, 206, 178), alpha=0.22, bright=0.97, sat=0.94, lift=0.03),
    "day":     dict(tint=(246, 250, 255), alpha=0.10, bright=1.10, sat=1.12, lift=0.00),
    "evening": dict(tint=(255, 138, 66),  alpha=0.30, bright=0.86, sat=1.10, lift=0.02),
    "night":   dict(tint=(26, 40, 82),    alpha=0.52, bright=0.46, sat=0.70, lift=0.06),
}


def grade(img, phase, seed=0):
    """Recolour a scene for one time of day."""
    p = PHASES[phase]
    out = ImageEnhance.Brightness(img).enhance(p["bright"])
    out = Image.blend(out, Image.new("RGB", out.size, p["tint"]), p["alpha"])
    out = ImageEnhance.Color(out).enhance(p["sat"])
    if p["lift"]:
        a = np.asarray(out).astype(np.float32)
        a = a + (255 - a) * p["lift"]          # lift shadows more than highlights
        out = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))
    if phase == "night":
        out = add_night_sky(out, seed)
    return out


def add_night_sky(img, seed):
    """Stars in whatever part of the top of the frame is actually open sky, plus a moon.

    Sky is found per column by walking down until the pixel stops looking like the one
    above it — crude, but these are flat illustrations, so it lands on the skyline.
    """
    a = np.asarray(img).astype(np.int16)
    h, w, _ = a.shape
    limit = int(h * 0.62)
    # First row where a column changes sharply = the horizon for that column.
    diff = np.abs(np.diff(a[:limit].sum(axis=2), axis=0))
    horizon = np.argmax(diff > 40, axis=0)
    horizon[horizon == 0] = limit                  # no edge found: all sky down to the cap

    d = ImageDraw.Draw(img)
    rnd = random.Random(seed + 991)
    for _ in range(320):
        x = rnd.randrange(w)
        top = max(8, int(horizon[x]) - 14)
        if top < 20:
            continue
        y = rnd.randrange(6, top)
        r = rnd.choice((1, 1, 1, 2))
        v = rnd.randint(170, 255)
        d.ellipse([x, y, x + r, y + r], fill=(v, v, min(255, v + 12)))

    # Moon, tucked into the widest piece of open sky in the top-right quadrant.
    band_start = int(w * 0.55)
    col = band_start + int(np.argmax(horizon[band_start:]))
    my = max(70, int(horizon[col]) // 2)
    img = sun(img, col, my, 34, (226, 232, 244), glow=2.0)
    dd = draw_on(img)
    dd.ellipse([col - 46, my - 30, col + 4, my + 22], fill=(0, 0, 0, 0)) if False else None
    return img


# ---------------------------------------------------------------- scenes

def bayshore_run():
    """Dawn on the bay: flat water, a cable-stayed bridge in the distance, the path in front."""
    sky_t, sky_b = rgb(0x17243F), rgb(0xF2915C)
    img = vgrad(sky_t, sky_b, y1=430)
    d = draw_on(img)
    clouds(d, random.Random(3), 90, 300, rgb(0x3B4668), 6)
    img = sun(img, 880, 395, 46, rgb(0xFFD08A))
    d = draw_on(img)

    # far shore
    d.rectangle([0, 408, W, 430], fill=rgb(0x2B3350))
    for x in range(0, W, 47):
        h = 10 + (x * 7919 % 26)
        d.rectangle([x, 430 - h - 22, x + 18, 408], fill=rgb(0x2B3350))

    # bridge: deck arcing left to right with a single pylon and cables
    deck = [(120, 402), (430, 356), (760, 372), (1200, 398)]
    d.line(deck, fill=rgb(0x222A44), width=9, joint="curve")
    px, py = 430, 356
    d.polygon([(px - 9, py), (px + 9, py), (px + 4, py - 96), (px - 4, py - 96)], fill=rgb(0x222A44))
    for tx in (150, 230, 310, 560, 700, 840):
        d.line([(px, py - 92), (tx, 400 if tx > px else 396)], fill=rgb(0x2B3350), width=2)

    # water
    band(d, 430, 610, rgb(0x2A4A6B), rgb(0x16304A))
    band(d, 610, H, rgb(0x16304A), rgb(0x0E2136))
    shimmer(d, 436, 700, rgb(0x6FA6C9), random.Random(11), 90)
    for y in range(432, 560, 6):                      # sun path on the water
        w = 26 + (y - 432) * 1.5
        d.line([(880 - w / 2, y), (880 + w / 2, y)], fill=rgb(0xE8B87E), width=2)

    # bikeway in the foreground
    d.polygon([(0, 690), (W, 640), (W, H), (0, H)], fill=rgb(0x233A33))
    d.polygon([(0, 726), (W, 668), (W, 792), (0, H)], fill=rgb(0x3C3F46))
    d.line([(0, 762), (W, 700)], fill=rgb(0xE8C77A), width=5)
    for x in range(-40, W, 210):                       # reeds along the path
        for k in range(6):
            bx = x + k * 9
            d.line([(bx, 700 - x * 0.03), (bx + 5 - k, 650 - x * 0.03)], fill=rgb(0x1B2E28), width=3)
    return img


def imperial_beach():
    """Evening surf, pier silhouette, wet sand holding the sky."""
    img = vgrad(rgb(0x2A2350), rgb(0xFF9F6E), y1=470)
    d = draw_on(img)
    clouds(d, random.Random(5), 120, 330, rgb(0x6A4C74), 8)
    img = sun(img, 330, 432, 54, rgb(0xFFE0A8))
    d = draw_on(img)

    band(d, 470, 600, rgb(0x2B5470), rgb(0x1C3B54))
    shimmer(d, 474, 596, rgb(0x87B7CE), random.Random(2), 60)
    for y in range(472, 520, 5):
        w = 30 + (y - 472) * 2.4
        d.line([(330 - w / 2, y), (330 + w / 2, y)], fill=rgb(0xF6C88E), width=2)

    # pier
    d.rectangle([520, 428, 1200, 446], fill=rgb(0x1C1B2E))
    for x in range(536, 1200, 52):
        d.rectangle([x, 446, x + 11, 512 + (x % 3) * 4], fill=rgb(0x1C1B2E))
    d.rectangle([1084, 396, 1160, 430], fill=rgb(0x1C1B2E))

    # breaking surf
    for i, (y, a) in enumerate(((600, 0xBFD8E2), (628, 0xD6E7EE), (656, 0xEAF3F6))):
        pts = [(0, y)]
        for x in range(0, W + 1, 60):
            pts.append((x, y + math.sin(x / 120 + i) * 7))
        d.polygon(pts + [(W, y + 34), (0, y + 34)], fill=rgb(a))

    # wet then dry sand
    band(d, 690, 748, rgb(0xC8A987), rgb(0xB89876))
    for y in range(690, 748, 4):
        d.line([(0, y), (W, y)], fill=mix(rgb(0xC8A987), rgb(0xE9C79C), 0.25))
    band(d, 748, H, rgb(0xD9B98F), rgb(0xC2A075))
    rnd = random.Random(77)
    for _ in range(160):                                # shell flecks in the dry sand
        x, y = rnd.randrange(W), rnd.randrange(752, H)
        d.ellipse([x, y, x + 4, y + 2], fill=rgb(0xB79A76))
    return img


def silver_strand():
    """The Strand: ocean on one side, a deep bank of dune grass, the road running straight."""
    img = vgrad(rgb(0x3E6FA8), rgb(0xCFE4EF), y1=300)
    d = draw_on(img)
    clouds(d, random.Random(9), 50, 210, rgb(0xF7FAFC), 7)

    band(d, 300, 396, rgb(0x2F6E8E), rgb(0x1F5675))                            # ocean
    shimmer(d, 304, 392, rgb(0x9FD0E0), random.Random(4), 60)
    for i, (y, c) in enumerate(((388, 0xBFD9E4), (404, 0xE8F2F5))):            # shorebreak
        pts = [(x, y + math.sin(x / 140 + i) * 6) for x in range(0, W + 1, 60)]
        d.polygon(pts + [(W, y + 26), (0, y + 26)], fill=rgb(c))

    band(d, 424, 486, rgb(0xE6CEA3), rgb(0xD6BB8E))                            # beach

    d.polygon([(0, 470), (W, 452), (W, 612), (0, 640)], fill=rgb(0x93A067))    # dune bank
    d.polygon([(0, 470), (W, 452), (W, 508), (0, 528)], fill=rgb(0xA8B277))    # sunlit crest
    for x in range(-20, W + 20, 11):                                            # blades
        h = 26 + (x * 7717 % 40)
        y = 626 - x * 0.023
        lean = 7 - (x % 5) * 3
        d.line([(x, y), (x + lean, y - h)], fill=rgb(0x6F7D49), width=2)
        d.line([(x + 5, y), (x + 5 + lean // 2, y - h * 0.7)], fill=rgb(0x7E8C55), width=2)

    d.polygon([(0, 640), (W, 612), (W, H), (0, H)], fill=rgb(0x45484F))        # road
    d.line([(0, 652), (W, 624)], fill=rgb(0xE6E8EA), width=5)
    d.line([(0, 788), (W, 752)], fill=rgb(0xE6E8EA), width=6)
    for i in range(9):                                                          # centre dashes
        x0 = i * 150 - 40
        d.line([(x0, 722 - x0 * 0.03), (x0 + 84, 722 - (x0 + 84) * 0.03)], fill=rgb(0xE8C77A), width=7)
    return img


def bayshore_ride():
    """Same bay, afternoon: palms, the traffic-free path, water on the left."""
    img = vgrad(rgb(0x2E7BC4), rgb(0xCDE6F2), y1=400)
    d = draw_on(img)
    clouds(d, random.Random(21), 70, 250, rgb(0xFFFFFF), 7)

    d.rectangle([0, 392, W, 420], fill=rgb(0x5E7A86))                 # far shoreline
    for x in range(0, W, 63):
        d.rectangle([x, 420 - 34 - (x * 331 % 30), x + 22, 400], fill=rgb(0x51707D))

    band(d, 420, 560, rgb(0x2E7FA6), rgb(0x1E5E80))
    shimmer(d, 424, 556, rgb(0x93CBE0), random.Random(8), 80)

    d.polygon([(0, 556), (W, 540), (W, 604), (0, 626)], fill=rgb(0x7E8D55))   # bank
    d.polygon([(0, 604), (W, 572), (W, 724), (0, 776)], fill=rgb(0x4A4E57))   # bike path
    d.line([(0, 664), (W, 648)], fill=rgb(0xF0F2F4), width=4)
    d.polygon([(0, 724), (W, 692), (W, H), (0, H)], fill=rgb(0x7E8D55))

    for x, h in ((140, 250), (300, 190), (1010, 300), (1130, 210)):    # palms
        palm(d, x, 600 - x * 0.02, h, rgb(0x2C3A2C))
    return img


def otay_lakes():
    """The climbing day: chaparral ridges stacked back, a road threading them."""
    img = vgrad(rgb(0x6FA8D8), rgb(0xF4E0BC), y1=420)
    d = draw_on(img)
    clouds(d, random.Random(33), 60, 240, rgb(0xFFFFFF), 5)
    ridge(d, 420, 26, rgb(0x8FA2A8), 1)
    ridge(d, 486, 30, rgb(0x74898C), 2)
    ridge(d, 556, 34, rgb(0x5C6F63), 3)
    ridge(d, 634, 30, rgb(0x46553F), 4)

    # road switching back up the nearest ridge
    pts = [(-20, H), (240, 760), (520, 706), (430, 664), (700, 636), (980, 610), (1210, 596)]
    d.line(pts, fill=rgb(0x4B4F55), width=34, joint="curve")
    d.line(pts, fill=rgb(0xE8C77A), width=3, joint="curve")

    rnd = random.Random(12)
    for _ in range(90):                                              # scrub
        x = rnd.randrange(-20, W)
        y = rnd.randrange(640, H)
        r = rnd.randint(7, 20)
        d.ellipse([x, y, x + r * 2, y + r], fill=rgb(0x35422F))
    return img


def pain_cave():
    """The garage: trainer, fan, mat, a window doing the lighting."""
    img = canvas(rgb(0x1D2230))
    d = draw_on(img)
    band(d, 0, 560, rgb(0x232A3B), rgb(0x1A2030))
    d.polygon([(0, 560), (W, 560), (W, H), (0, H)], fill=rgb(0x2C3042))       # floor

    d.rectangle([760, 90, 1120, 360], fill=rgb(0x33507A))                      # window
    d.rectangle([760, 90, 1120, 360], outline=rgb(0x161B27), width=12)
    d.line([(940, 96), (940, 354)], fill=rgb(0x161B27), width=8)
    d.line([(766, 225), (1114, 225)], fill=rgb(0x161B27), width=8)
    d.polygon([(760, 360), (1120, 360), (1240, H), (700, H)], fill=rgb(0x2F3549))  # light on the floor

    # mat
    d.polygon([(250, 612), (880, 612), (960, 760), (170, 760)], fill=rgb(0x161B27))

    # trainer + bike, all silhouette
    fr = rgb(0x0E1220)
    accent = rgb(0xEB6834)
    d.polygon([(430, 700), (640, 700), (600, 742), (470, 742)], fill=fr)       # trainer base
    d.rectangle([520, 620, 548, 706], fill=fr)                                  # cassette leg
    d.ellipse([470, 560, 610, 700], outline=fr, width=14)                       # rear wheel
    d.line([(540, 630), (700, 566)], fill=fr, width=13)                         # down tube
    d.line([(700, 566), (742, 470)], fill=fr, width=13)                         # fork
    d.line([(540, 630), (600, 500)], fill=fr, width=13)                         # seat tube
    d.line([(600, 500), (744, 478)], fill=fr, width=12)                         # top tube
    d.line([(586, 494), (520, 470)], fill=fr, width=14)                         # saddle
    d.line([(742, 470), (700, 440)], fill=accent, width=12)                     # bars
    d.line([(700, 440), (790, 430)], fill=accent, width=10)                     # aero extensions
    d.ellipse([672, 592, 760, 680], outline=fr, width=12)                       # chainring guard
    d.line([(716, 636), (762, 682)], fill=accent, width=10)                     # crank

    # fan
    d.rectangle([180, 470, 200, 700], fill=rgb(0x141926))
    d.ellipse([110, 350, 270, 510], outline=rgb(0x141926), width=12)
    for a in range(0, 360, 60):
        r = math.radians(a)
        d.line([(190, 430), (190 + math.cos(r) * 66, 430 + math.sin(r) * 66)], fill=rgb(0x1B2130), width=14)
    d.ellipse([172, 412, 208, 448], fill=rgb(0x141926))

    # towel + bottle
    d.polygon([(830, 660), (930, 648), (946, 712), (842, 726)], fill=rgb(0xD9DCE3))
    d.rounded_rectangle([300, 600, 342, 700], 14, fill=rgb(0x199E70))
    return img


def pool():
    """Long course: lane ropes running away from you, tiled black lines underneath."""
    img = canvas(rgb(0x0F5E86))
    d = draw_on(img)
    band(d, 0, 120, rgb(0xC9D6DB), rgb(0xA9B9C0))                    # deck
    d.rectangle([0, 112, W, 130], fill=rgb(0x8C9EA6))                 # gutter
    band(d, 130, H, rgb(0x1E86B4), rgb(0x0B4C70))

    lanes = 6
    for i in range(lanes + 1):
        t = i / lanes
        x_far = 180 + t * (W - 360)
        x_near = -260 + t * (W + 520)
        d.polygon([(x_far - 3, 140), (x_far + 3, 140), (x_near + 9, H), (x_near - 9, H)], fill=rgb(0x0A3F5E))
    for i in range(1, lanes):                                         # lane ropes as bead runs
        t = i / lanes
        for k in range(30):
            p = k / 30
            y = 150 + (H - 150) * (p ** 1.9)
            x = (180 + t * (W - 360)) + ((-260 + t * (W + 520)) - (180 + t * (W - 360))) * (p ** 1.9)
            r = 3 + 12 * (p ** 1.9)
            col = rgb(0xEDEFF2) if k % 3 else (rgb(0xEB6834) if i % 2 else rgb(0x2A78D6))
            d.ellipse([x - r, y - r * 0.7, x + r, y + r * 0.7], fill=col)

    shimmer(d, 150, H, rgb(0x6FC3E2), random.Random(6), 120, 4)
    for x in range(-100, W + 200, 96):                                # ripple arcs
        d.arc([x, 560, x + 150, 640], 200, 340, fill=rgb(0x8FD3EC), width=3)
    return img


def ventura_cove():
    """Mission Bay at first light: flat water, a buoy, low shore, no swell."""
    img = vgrad(rgb(0x30405F), rgb(0xE9A87C), y1=400)
    d = draw_on(img)
    clouds(d, random.Random(15), 110, 300, rgb(0x5A5C7A), 6)
    img = sun(img, 760, 378, 40, rgb(0xFFDDA5))
    d = draw_on(img)

    d.polygon([(0, 392), (260, 372), (620, 384), (1200, 366), (1200, 410), (0, 410)], fill=rgb(0x37405C))
    for x, h in ((120, 120), (190, 90), (980, 140), (1070, 96)):
        palm(d, x, 392, h, rgb(0x2A3148))

    band(d, 410, 620, rgb(0x2F5A76), rgb(0x1B3B52))
    band(d, 620, H, rgb(0x1B3B52), rgb(0x12293B))
    shimmer(d, 414, 740, rgb(0x82B9D2), random.Random(17), 70)
    for y in range(412, 530, 6):
        w = 22 + (y - 412) * 1.4
        d.line([(760 - w / 2, y), (760 + w / 2, y)], fill=rgb(0xE9BD8A), width=2)

    d.ellipse([300, 596, 352, 648], fill=rgb(0xEDA100))               # marker buoy
    d.rectangle([322, 552, 330, 606], fill=rgb(0x1B3B52))
    d.polygon([(0, 748), (W, 716), (W, H), (0, H)], fill=rgb(0xD4B68C))
    return img


def la_jolla():
    """The Cove: sandstone cliffs, kelp-dark water, a bit of swell."""
    img = vgrad(rgb(0x4E86BE), rgb(0xE7D3B2), y1=380)
    d = draw_on(img)
    clouds(d, random.Random(23), 60, 250, rgb(0xFFFFFF), 6)

    # water first, so the cliffs sit in front of it
    band(d, 380, 560, rgb(0x1F6480), rgb(0x134458))
    band(d, 560, H, rgb(0x134458), rgb(0x0B2F41))
    shimmer(d, 384, 760, rgb(0x62B4CB), random.Random(29), 90)
    for i, y in enumerate((548, 620, 700)):                           # swell lines
        pts = [(x, y + math.sin(x / 150 + i * 1.3) * 13) for x in range(0, W + 1, 50)]
        d.line(pts, fill=rgb(0xCFE7EE), width=5 + i * 3, joint="curve")

    # headland: a sandstone bluff on the left, cut off square where it meets the cove
    top = [(0, 286), (120, 268), (250, 300), (352, 288)]
    d.polygon(top + [(374, 600), (300, 646), (0, 646)], fill=rgb(0xB88F60))      # shadowed face
    d.polygon(top + [(352, 396), (240, 420), (96, 392), (0, 404)], fill=rgb(0xD8B486))  # sunlit shoulder
    d.polygon([(0, 286), (120, 268), (250, 300), (352, 288), (352, 316), (240, 330),
               (110, 300), (0, 316)], fill=rgb(0x6E8C4F))                        # scrub along the rim
    for i, (x0, x1, y) in enumerate(((0, 300, 452), (0, 330, 508), (0, 352, 564))):
        d.line([(x0, y + 18), (x1, y)], fill=rgb(0xA57E54), width=7)             # a few strata, not ruled paper
    d.polygon([(0, 646), (300, 646), (374, 600), (392, 664), (250, 712), (0, 700)],
              fill=rgb(0x7C6444))                                                 # wet rock at the base
    d.polygon([(0, 700), (250, 712), (392, 664), (420, 700), (240, 756), (0, 752)],
              fill=rgb(0xE8F2F5))                                                 # foam against the rock
    for x, r in ((470, 24), (548, 17), (506, 11)):                                # rocks off the point
        d.ellipse([x, 664 - r, x + r * 2.2, 664 + r], fill=rgb(0x6F5B43))
        d.ellipse([x - 8, 664 + r - 4, x + r * 2.6, 664 + r + 8], fill=rgb(0xDCEAF0))
    return img


def gym():
    """Rack, bar, plates — the strength session, no brand anywhere."""
    img = canvas(rgb(0x232838))
    d = draw_on(img)
    band(d, 0, 600, rgb(0x2A3044), rgb(0x1E2333))
    d.polygon([(0, 600), (W, 600), (W, H), (0, H)], fill=rgb(0x3A3020))               # wood floor
    for x in range(-200, W + 200, 78):
        d.line([(x, 600), (x - 70, H)], fill=rgb(0x322B1C), width=4)

    rack = rgb(0x11151F)
    d.rectangle([250, 170, 292, 640], fill=rack)                                       # uprights
    d.rectangle([700, 170, 742, 640], fill=rack)
    d.rectangle([250, 170, 742, 206], fill=rack)                                       # crossbar
    for y in range(250, 620, 46):                                                      # holes
        d.ellipse([262, y, 280, y + 18], fill=rgb(0x2A3044))
        d.ellipse([712, y, 730, y + 18], fill=rgb(0x2A3044))

    d.rectangle([180, 392, 812, 412], fill=rgb(0xB9C0CC))                              # bar
    for cx in (262, 730):                                                              # plates
        for r, col in ((74, 0x2A78D6), (58, 0x17202E)):
            d.ellipse([cx - 22 - (0 if r > 60 else 0), 402 - r, cx + 22, 402 + r], fill=rgb(col))
    d.ellipse([196, 340, 240, 466], fill=rgb(0x1B2331))
    d.ellipse([754, 340, 798, 466], fill=rgb(0x1B2331))

    for i, (x, r) in enumerate(((880, 42), (980, 36), (1068, 30))):                    # dumbbells
        y = 700 - i * 8
        d.rectangle([x, y - 10, x + r * 2, y + 10], fill=rgb(0x9AA3B2))
        d.ellipse([x - 20, y - r, x + 20, y + r], fill=rgb(0x141A26))
        d.ellipse([x + r * 2 - 20, y - r, x + r * 2 + 20, y + r], fill=rgb(0x141A26))
    d.polygon([(70, 690), (230, 690), (250, 756), (50, 756)], fill=rgb(0x141A26))      # mat
    return img


def mountain():
    """Snowboard weekend: peaks, pines, cold blue light."""
    img = vgrad(rgb(0x2B4C7E), rgb(0xE6B98E), y1=360)
    d = draw_on(img)
    clouds(d, random.Random(41), 70, 230, rgb(0x7E8FB0), 5)
    img = sun(img, 250, 300, 44, rgb(0xFFE7BE))
    d = draw_on(img)

    # two ranges of sharp peaks, each capped with snow
    for seed, base, amp, col, snow, step in ((5, 330, 90, 0x54689A, 0xC6D5EA, 4),
                                             (9, 430, 110, 0x3B4F7D, 0xDCE7F5, 3)):
        rnd = random.Random(seed)
        pts = [(0, base)]
        n = step * 3
        for i in range(1, n + 1):
            x = W * i / n
            y = base - rnd.uniform(0.35, 1.0) * amp if i % 2 else base + rnd.uniform(0, 0.35) * amp
            pts.append((x, y))
        d.polygon(pts + [(W, H), (0, H)], fill=rgb(col))
        for i in range(1, len(pts) - 1):                                  # cap each summit
            x, y = pts[i]
            if y < base - amp * 0.3:
                drop = (base - y) * 0.42
                d.polygon([(x, y), (x + drop * 0.85, y + drop), (x + drop * 0.25, y + drop * 0.78),
                           (x - drop * 0.25, y + drop), (x - drop * 0.85, y + drop)], fill=rgb(snow))

    # snowfield rolling toward the viewer, with shadowed dips so it isn't a flat slab
    d.polygon([(0, 556), (W, 520), (W, H), (0, H)], fill=rgb(0xE7EFF8))
    for i, (y, c) in enumerate(((596, 0xD3DFEE), (664, 0xEDF3FA), (742, 0xDCE6F3))):
        pts = [(x, y + math.sin(x / 170 + i * 1.7) * 18) for x in range(0, W + 1, 60)]
        d.polygon(pts + [(W, H), (0, H)], fill=rgb(c))

    for x in range(-60, W + 80, 78):                                      # treeline, taller as it nears
        t = (x + 60) / (W + 140)
        pine(d, x, 572 + t * 150, 92 + t * 150 + (x * 733 % 40), rgb(0x22354B))
    rnd = random.Random(19)
    for _ in range(220):                                                  # falling snow
        x, y = rnd.randrange(W), rnd.randrange(H)
        r = rnd.choice((2, 2, 3, 4))
        d.ellipse([x, y, x + r, y + r], fill=rgb(0xF7FAFD))
    return img


def race_day():
    """Finish chute: arch, flags, barriers, a clean line of road."""
    img = vgrad(rgb(0x3D7AC0), rgb(0xFCE2BC), y1=420)
    d = draw_on(img)
    clouds(d, random.Random(51), 70, 250, rgb(0xFFFFFF), 6)
    d.polygon([(0, 420), (W, 400), (W, 470), (0, 486)], fill=rgb(0x4B6B52))

    d.polygon([(0, H), (440, 470), (760, 470), (W, H)], fill=rgb(0x4A4E57))   # road
    dashes(d, 476, H, rgb(0xF0F2F4))
    d.polygon([(380, 470), (440, 470), (140, H), (0, H)], fill=rgb(0x6F7562))
    d.polygon([(760, 470), (820, 470), (W, H), (1050, H)], fill=rgb(0x6F7562))

    # arch
    d.rectangle([300, 300, 348, 560], fill=rgb(0x1F2536))
    d.rectangle([852, 300, 900, 560], fill=rgb(0x1F2536))
    d.rectangle([300, 240, 900, 320], fill=rgb(0xEB6834))
    d.rectangle([300, 240, 900, 320], outline=rgb(0x1F2536), width=8)
    d.rectangle([420, 268, 780, 292], fill=rgb(0xFBDCC6))                     # banner text bar
    for i in range(14):                                                        # bunting
        x = 306 + i * 44
        d.polygon([(x, 320), (x + 36, 320), (x + 18, 356)],
                  fill=rgb(0xEDA100) if i % 2 else rgb(0x2A78D6))

    for side in (0, 1):                                                        # barriers
        for i in range(5):
            x = 250 - i * 56 if side == 0 else 950 + i * 56
            y = 520 + i * 44
            d.rectangle([x - 46, y, x + 46, y + 12], fill=rgb(0xD9DCE3))
            d.rectangle([x - 46, y + 12, x - 36, y + 52], fill=rgb(0xB9BFCB))
            d.rectangle([x + 36, y + 12, x + 46, y + 52], fill=rgb(0xB9BFCB))
    return img


# ---------------------------------------------------------------- more places

def trail_run():
    """Generic trail: dirt path through trees, morning light coming through."""
    img = vgrad(rgb(0x8FC4E8), rgb(0xF4E3C4), y1=380)
    d = draw_on(img)
    img = sun(img, 620, 330, 38, rgb(0xFFF0CE))
    d = draw_on(img)
    ridge(d, 380, 22, rgb(0x7E9A80), 31)
    ridge(d, 430, 26, rgb(0x5E7C62), 32)
    d.polygon([(0, 500), (W, 476), (W, H), (0, H)], fill=rgb(0x46603F))       # meadow
    pts = [(-40, H), (300, 760), (470, 660), (540, 588), (600, 520)]
    d.line(pts, fill=rgb(0xB89A6E), width=120, joint="curve")
    d.line(pts, fill=rgb(0xC9AC80), width=86, joint="curve")
    rnd = random.Random(44)
    for _ in range(26):                                                        # trees, near ones bigger
        x = rnd.randrange(-40, W + 40)
        t = rnd.random()
        base = 520 + t * 300
        pine(d, x, base, 150 + t * 260, rgb(0x24402C) if t > 0.4 else rgb(0x33543A))
    for _ in range(70):                                                        # scrub at the edges
        x, y = rnd.randrange(W), rnd.randrange(620, H)
        r = rnd.randint(6, 16)
        d.ellipse([x, y, x + r * 2, y + r], fill=rgb(0x35512F))
    return img


def mountain_road_bike():
    """The climbing day: switchbacks stacked up a bare mountainside."""
    img = vgrad(rgb(0x4C8FD0), rgb(0xE8D5B2), y1=340)
    d = draw_on(img)
    clouds(d, random.Random(61), 60, 220, rgb(0xFFFFFF), 5)
    ridge(d, 330, 40, rgb(0x8698A6), 71)
    ridge(d, 410, 34, rgb(0x6E7F7A), 72)
    d.polygon([(0, 470), (W, 430), (W, H), (0, H)], fill=rgb(0x7A7256))        # the mountainside
    d.polygon([(0, 470), (W, 430), (W, 540), (0, 586)], fill=rgb(0x8C8464))    # sunlit shoulder
    for i, (y, x0, x1) in enumerate(((560, -40, 900), (640, 260, 1240), (724, -40, 980))):
        d.line([(x0, y), (x1, y - 26)], fill=rgb(0x4B4F55), width=30)          # switchback legs
        d.line([(x0, y), (x1, y - 26)], fill=rgb(0xE8C77A), width=3)
    d.line([(880, 548), (300, 618)], fill=rgb(0x4B4F55), width=30)             # the hairpins
    d.line([(280, 636), (960, 706)], fill=rgb(0x4B4F55), width=30)
    rnd = random.Random(13)
    for _ in range(80):                                                        # dry scrub
        x, y = rnd.randrange(-20, W), rnd.randrange(480, H)
        r = rnd.randint(5, 14)
        d.ellipse([x, y, x + r * 2, y + r], fill=rgb(0x5E5C3C))
    return img


def open_water():
    """Open-water swim: buoy line, low sun, chop rather than glass."""
    img = vgrad(rgb(0x243A63), rgb(0xF0A472), y1=380)
    d = draw_on(img)
    clouds(d, random.Random(81), 110, 300, rgb(0x4E5580), 6)
    img = sun(img, 420, 362, 44, rgb(0xFFE3B0))
    d = draw_on(img)
    d.rectangle([0, 372, W, 396], fill=rgb(0x2E3752))
    band(d, 396, 600, rgb(0x275574), rgb(0x173B52))
    band(d, 600, H, rgb(0x173B52), rgb(0x0D2739))
    shimmer(d, 400, 760, rgb(0x71AFC9), random.Random(83), 110, 4)
    for y in range(398, 520, 6):
        w = 24 + (y - 398) * 1.6
        d.line([(420 - w / 2, y), (420 + w / 2, y)], fill=rgb(0xE7B382), width=2)
    for i, (x, y, r) in enumerate(((240, 560, 26), (620, 600, 34), (1010, 660, 44))):
        col = rgb(0xEB6834) if i % 2 == 0 else rgb(0xEDA100)                   # turn buoys
        d.polygon([(x, y - r * 1.6), (x + r, y), (x - r, y)], fill=col)
        d.ellipse([x - r, y - r * 0.3, x + r, y + r * 0.5], fill=col)
        d.ellipse([x - r * 1.3, y + r * 0.3, x + r * 1.3, y + r * 0.8], fill=rgb(0xC9E2EC))
    for i, y in enumerate((660, 730)):                                         # chop
        pts = [(x, y + math.sin(x / 90 + i) * 9) for x in range(0, W + 1, 40)]
        d.line(pts, fill=rgb(0x9FCEDF), width=4, joint="curve")
    return img


def golden_gate_park():
    """Park running paths: cypress and eucalyptus, fog sitting in the trees."""
    img = vgrad(rgb(0xB9C6C9), rgb(0xE8EDE6), y1=400)
    d = draw_on(img)
    clouds(d, random.Random(91), 40, 240, rgb(0xF4F7F4), 9)
    for depth, (base, col, n) in enumerate(((420, 0x7F9285, 16), (470, 0x5E7466, 13), (530, 0x3F5745, 10))):
        rnd = random.Random(100 + depth)
        for _ in range(n):
            x = rnd.randrange(-60, W + 60)
            h = 150 + rnd.randrange(0, 160) + depth * 40
            # Cypress: a dense flat-topped crown on a short trunk.
            d.rectangle([x - 7, base - h * 0.35, x + 7, base + 20], fill=rgb(col))
            d.ellipse([x - h * 0.34, base - h, x + h * 0.34, base - h * 0.30], fill=rgb(col))
            d.ellipse([x - h * 0.24, base - h * 1.12, x + h * 0.20, base - h * 0.62], fill=rgb(col))
    d.polygon([(0, 560), (W, 534), (W, H), (0, H)], fill=rgb(0x5E7A4B))        # lawn
    pts = [(-40, H), (330, 756), (560, 668), (700, 612), (820, 574)]
    d.line(pts, fill=rgb(0x54585F), width=76, joint="curve")                   # paved path
    d.line(pts, fill=rgb(0xCFD4D8), width=3, joint="curve")
    d.polygon([(0, 700), (240, 660), (300, 720), (60, 780)], fill=rgb(0x6F8E9A))  # a pond edge
    # fog lying over the middle distance
    for y in range(380, 560, 2):
        a = int(150 * (1 - abs(y - 460) / 100)) if abs(y - 460) < 100 else 0
        if a > 0:
            d.line([(0, y), (W, y)], fill=mix(rgb(0x5E7466), rgb(0xE9EEEA), a / 255))
    return img


def golden_gate_bridge():
    """The strait at dawn: towers in fog, water below — long-run scenery."""
    img = vgrad(rgb(0x6A7FA8), rgb(0xF6C79C), y1=420)
    d = draw_on(img)
    clouds(d, random.Random(101), 90, 300, rgb(0xD9CBD4), 7)
    img = sun(img, 980, 400, 40, rgb(0xFFE6BC))
    d = draw_on(img)

    hd = rgb(0xB4593B)                                                          # the towers
    deck_y = 470
    for tx in (330, 860):
        d.rectangle([tx - 34, 128, tx - 14, deck_y], fill=hd)
        d.rectangle([tx + 14, 128, tx + 34, deck_y], fill=hd)
        for cy in (190, 272, 354):
            d.rectangle([tx - 34, cy, tx + 34, cy + 16], fill=hd)
        d.polygon([(tx - 40, 128), (tx + 40, 128), (tx + 30, 106), (tx - 30, 106)], fill=hd)
    d.rectangle([0, deck_y, W, deck_y + 18], fill=hd)                           # deck
    # main cables: one long sagging span between the towers, shorter ones to each anchorage
    spans = [(0, 300, 330, 140, 110), (330, 140, 860, 140, 250), (860, 140, W, 300, 110)]
    for x0, y0, x1, y1, sag in spans:
        cable(d, x0, y0, x1, y1, sag, hd, width=8)

    def cable_y(x):
        for x0, y0, x1, y1, sag in spans:
            if x0 <= x <= x1:
                t = (x - x0) / (x1 - x0)
                return y0 + (y1 - y0) * t + sag * (1 - (2 * t - 1) ** 2)
        return y0

    for x in range(24, W, 34):                                                  # suspender ropes
        top = cable_y(x)
        if top < deck_y - 12 and not (300 < x < 360 or 830 < x < 890):
            d.line([(x, top), (x, deck_y)], fill=hd, width=2)

    d.rectangle([0, 488, W, 540], fill=rgb(0x4A5A6B))                           # far headland
    band(d, 540, 700, rgb(0x2C5670), rgb(0x1B3A4F))
    band(d, 700, H, rgb(0x1B3A4F), rgb(0x112B3C))
    shimmer(d, 544, 780, rgb(0x7BB0C8), random.Random(103), 80)
    for y in range(542, 640, 6):
        w = 22 + (y - 542) * 1.7
        d.line([(980 - w / 2, y), (980 + w / 2, y)], fill=rgb(0xE9BE8E), width=2)
    # fog rolling across the tower bases
    for y in range(400, 520, 2):
        a = int(170 * (1 - abs(y - 460) / 62)) if abs(y - 460) < 62 else 0
        if a > 0:
            d.line([(0, y), (W, y)], fill=mix(rgb(0x4A5A6B), rgb(0xE6E2E4), a / 255))
    return img


def ski_resort():
    """Snowboard weekend: groomed runs, a chairlift line, pines between."""
    img = vgrad(rgb(0x3E6FB4), rgb(0xCFE2F2), y1=300)
    d = draw_on(img)
    clouds(d, random.Random(111), 50, 200, rgb(0xFFFFFF), 5)
    for base, amp, col, snow in ((300, 80, 0x60769F, 0xD6E3F2), (380, 90, 0x47598A, 0xE6EEF8)):
        rnd = random.Random(base)
        pts = [(0, base)]
        for i in range(1, 10):
            x = W * i / 9
            y = base - rnd.uniform(0.4, 1.0) * amp if i % 2 else base + rnd.uniform(0, 0.3) * amp
            pts.append((x, y))
        d.polygon(pts + [(W, H), (0, H)], fill=rgb(col))
        for i in range(1, len(pts) - 1):
            x, y = pts[i]
            if y < base - amp * 0.3:
                drop = (base - y) * 0.45
                d.polygon([(x, y), (x + drop, y + drop), (x - drop, y + drop)], fill=rgb(snow))

    d.polygon([(0, 470), (W, 440), (W, H), (0, H)], fill=rgb(0xEDF3FA))         # the mountain face
    for x0, x1, c in ((-100, 520, 0xDCE7F4), (380, 1000, 0xF4F8FC), (820, 1400, 0xDCE7F4)):
        d.polygon([(x0, 470), (x1, 470), (x1 - 160, H), (x0 - 300, H)], fill=rgb(c))  # groomed runs
    for x in range(-40, W + 60, 62):                                            # trees between runs
        if 520 < x < 820 or x < 300:
            pine(d, x, 540 + (x % 5) * 26, 90 + (x * 733 % 70), rgb(0x22354B))

    cable = [(1160, 300), (820, 400), (470, 484), (120, 556)]                   # chairlift
    d.line(cable, fill=rgb(0x23303F), width=4, joint="curve")
    for i, (cx, cy) in enumerate(cable[:-1]):
        d.rectangle([cx - 5, cy, cx + 5, cy + 130], fill=rgb(0x23303F))         # towers
        d.rectangle([cx - 26, cy - 6, cx + 26, cy + 4], fill=rgb(0x23303F))
    for t in (0.2, 0.45, 0.72):                                                  # chairs
        i = int(t * 3)
        x = cable[i][0] + (cable[i + 1][0] - cable[i][0]) * ((t * 3) - i)
        y = cable[i][1] + (cable[i + 1][1] - cable[i][1]) * ((t * 3) - i)
        d.line([(x, y), (x, y + 26)], fill=rgb(0x23303F), width=3)
        d.rectangle([x - 15, y + 26, x + 15, y + 40], fill=rgb(0xEB6834))
    return img


def alpine_lake():
    """Tahoe-ish: a cold lake under snowy peaks, pines on the near shore."""
    img = vgrad(rgb(0x2E63A8), rgb(0xCFE4F4), y1=320)
    d = draw_on(img)
    clouds(d, random.Random(121), 50, 210, rgb(0xFFFFFF), 6)
    rnd = random.Random(7)
    pts = [(0, 340)]
    for i in range(1, 11):
        x = W * i / 10
        y = 340 - rnd.uniform(0.3, 1.0) * 95 if i % 2 else 340 + rnd.uniform(0, 0.3) * 60
        pts.append((x, y))
    d.polygon(pts + [(W, 470), (0, 470)], fill=rgb(0x4C6490))
    for i in range(1, len(pts) - 1):
        x, y = pts[i]
        if y < 300:
            drop = (340 - y) * 0.5
            d.polygon([(x, y), (x + drop, y + drop), (x - drop, y + drop)], fill=rgb(0xE9F0F8))
    for x in range(-30, W + 40, 26):                                             # far treeline
        pine(d, x, 486 + (x * 977 % 9), 52 + (x * 733 % 44), rgb(0x2C4A3E))

    band(d, 486, 640, rgb(0x2D7FA8), rgb(0x1A5578))                              # the lake
    band(d, 640, H, rgb(0x1A5578), rgb(0x123F5C))
    for i in range(1, len(pts) - 1):                                             # peaks reflected
        x, y = pts[i]
        if y < 300:
            drop = (340 - y) * 0.5
            d.polygon([(x, 486 + (486 - y) * 0.30), (x + drop, 486 + (486 - y) * 0.30 - drop * 0.5),
                       (x - drop, 486 + (486 - y) * 0.30 - drop * 0.5)], fill=rgb(0x3E7FA0))
    shimmer(d, 490, 780, rgb(0x8CCBE4), random.Random(123), 90)
    d.polygon([(0, 688), (340, 742), (W, 726), (W, H), (0, H)], fill=rgb(0xD9CBAE))   # granite shore
    d.polygon([(0, 688), (340, 742), (300, 770), (0, 724)], fill=rgb(0xC3B394))       # wet line
    for x, h in ((70, 200), (160, 155), (1110, 220), (1190, 165)):                    # shoreline pines
        pine(d, x, 756 if x < 400 else 744, h, rgb(0x1E3A2C))
    return img


def sierra_pass():
    """High alpine road: granite, thin air, a ribbon of tarmac over the pass."""
    img = vgrad(rgb(0x1F5FA8), rgb(0xBFDCF0), y1=300)
    d = draw_on(img)
    clouds(d, random.Random(131), 40, 180, rgb(0xFFFFFF), 4)
    ridge(d, 300, 50, rgb(0x7E8DA0), 141)
    ridge(d, 380, 44, rgb(0x66768A), 142)
    d.polygon([(0, 456), (W, 424), (W, H), (0, H)], fill=rgb(0x8C8A7E))          # granite slope
    d.polygon([(0, 456), (W, 424), (W, 512), (0, 556)], fill=rgb(0x9E9C8E))
    for _ in range(70):                                                           # snow patches
        rnd = random.Random()
        x, y = random.randrange(W), random.randrange(430, 640)
        w = random.randint(20, 80)
        d.ellipse([x, y, x + w, y + w * 0.3], fill=rgb(0xE8EEF4))
    pts = [(-40, H), (420, 750), (560, 660), (860, 618), (1240, 560)]
    d.line(pts, fill=rgb(0x45484F), width=44, joint="curve")
    d.line(pts, fill=rgb(0xE6E8EA), width=3, joint="curve")
    for x in range(-20, W, 140):                                                  # guard posts
        y = 740 - x * 0.12
        d.rectangle([x, y, x + 6, y + 26], fill=rgb(0xD9DCE3))
    for x, h in ((120, 120), (1080, 150), (980, 96)):
        pine(d, x, 600, h, rgb(0x2C4436))
    return img


def to_portrait(landscape, out_w=OUT_W, out_h=OUT_H, bias=HORIZON_BIAS, zoom=1.35):
    """Fit a landscape composition into a portrait frame.

    The scene is scaled past the frame width and centre-cropped, so more of the picture is real
    and less is invented. Above it the sky continues as flat rows whose colour extrapolates from
    the scene's own top band — row means, not per-pixel, because extending each column on its own
    turns every cloud into a vertical streak. Below it the bottom row carries down, which is
    ground or water in every scene and sits under the UI anyway.
    """
    w, h = landscape.size
    scale = out_w * zoom / w
    big = landscape.resize((int(round(w * scale)), int(round(h * scale))), Image.LANCZOS)
    left = (big.size[0] - out_w) // 2
    band = big.crop((left, 0, left + out_w, big.size[1]))
    a = np.asarray(band).astype(np.float32)
    band_h = a.shape[0]

    top = int(out_h * bias) - band_h // 2
    top = max(0, min(top, out_h - band_h)) if band_h <= out_h else 0

    out = np.zeros((out_h, out_w, 3), dtype=np.float32)
    keep = min(band_h, out_h - top)
    out[top:top + keep] = a[:keep]

    if top > 0:
        span = max(8, min(120, band_h // 4))
        near = a[:8].mean(axis=(0, 1))              # colour at the very top
        far = a[span - 8:span + 8].mean(axis=(0, 1))  # and a little way down
        slope = (near - far) / span                 # per row, continuing upward
        # Capped so a steep gradient doesn't run to white or black over a long extension.
        rows = np.minimum(np.arange(top, 0, -1), 420)[:, None]
        out[:top] = np.clip(near[None] + slope[None] * rows, 0, 255)[:, None, :]

    end = top + keep
    if end < out_h:
        out[end:] = a[keep - 1]

    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8))


SCENES = {
    "venue-bayshore-run": bayshore_run,
    "venue-imperial-beach": imperial_beach,
    "venue-silver-strand": silver_strand,
    "venue-bayshore-ride": bayshore_ride,
    "venue-otay-lakes": otay_lakes,
    "venue-pain-cave": pain_cave,
    "venue-pool": pool,
    "venue-ventura-cove": ventura_cove,
    "venue-la-jolla": la_jolla,
    "venue-gym": gym,
    "venue-mountain": mountain,
    "venue-race-day": race_day,
    "venue-trail-run": trail_run,
    "venue-mountain-road": mountain_road_bike,
    "venue-open-water": open_water,
    "venue-golden-gate-park": golden_gate_park,
    "venue-golden-gate-bridge": golden_gate_bridge,
    "venue-ski-resort": ski_resort,
    "venue-alpine-lake": alpine_lake,
    "venue-sierra-pass": sierra_pass,
}


def main():
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}, "properties": {"provides-namespace": False}}, f, indent=2)
    total = 0
    for name, fn in SCENES.items():
        wide = fn().convert("RGB")
        base = grain(to_portrait(wide), 4, hash(name) & 0xFF)
        sizes = []
        for phase in PHASES:
            asset = f"{name}-{phase}"
            folder = os.path.join(OUT, f"{asset}.imageset")
            os.makedirs(folder, exist_ok=True)
            path = os.path.join(folder, f"{asset}.jpg")
            grade(base, phase, seed=hash(name) & 0xFFFF).save(
                path, "JPEG", quality=76, optimize=True, progressive=True)
            with open(os.path.join(folder, "Contents.json"), "w") as f:
                json.dump({
                    "images": [{"filename": f"{asset}.jpg", "idiom": "universal"}],
                    "info": {"author": "xcode", "version": 1},
                }, f, indent=2)
            kb = os.path.getsize(path) // 1024
            sizes.append(kb)
            total += kb
        print(f"{name}: " + " / ".join(f"{p} {k}KB" for p, k in zip(PHASES, sizes)))
    print(f"--- {len(SCENES) * len(PHASES)} images, {total // 1024} MB")


if __name__ == "__main__":
    main()
