#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Generate Snow's day/night desktop wallpaper pair (docs/adr/0034-snow-gtk-theme.md).

The two scenes reuse the hero series' ridge geometry verbatim
(artwork/hero/generate_hero_backgrounds.py: MAIN, MID, FAR, FIELD), as the
Frostyard design system asks: crop or reuse the alpine ridgelines, never
redraw them. Every colour is a token of frostyard/core's design system
(pinned copy: test/fixtures/frostyard-design/colors.css), so the wallpaper
matches the Snow GTK theme; only opacity varies.

  snow-d.svg  night: ink sky, moon upper right, moonlit snow, snowfall
  snow-l.svg  day:   sky-to-ice daylight, sun glow upper right, bright snow

The canvas is 3:2 (Snowfield's Surface panels show all of it). GNOME's
"zoom" option crops it to 16:10, 16:9 or 21:9 from the middle, so the
horizon and summit sit inside the band every one of those keeps. The SVG's
intrinsic size is 3840x2560, which mutter rasterises once: a 4K 16:9
monitor needs no upscaling.

Usage:
  generate_snow_wallpaper.py            write both SVGs into shared/snow/tree
  generate_snow_wallpaper.py --check    exit 1 if a committed SVG differs
  generate_snow_wallpaper.py --render DIR
                                        also rasterise PNG previews (needs gi + GdkPixbuf)

Only the Python stdlib is needed to write or check the SVGs. Output is
deterministic: all randomness is seeded.
"""

import importlib.util
import math
import random
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "shared/snow/tree/usr/share/backgrounds/snow"

_spec = importlib.util.spec_from_file_location(
    "hero", REPO / "artwork/hero/generate_hero_backgrounds.py")
hero = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(hero)

W = hero.W                    # 3440, the hero series' width
CH = W * 2 / 3                # 3:2 canvas height (2293.3)
DY = 500                      # hero y + DY = canvas y; horizon at 1650 (0.72)
PX_W, PX_H = 3840, 2560       # intrinsic raster size
fnum = hero.fnum

# frostyard/core design tokens used below (colors.css names)
INK, DEEP, PANEL, PANEL_BRIGHT = "#06111d", "#081b2d", "#0d263b", "#0d2a41"
ON_PRIMARY = "#02131f"
ICE, SKY, BLUE = "#aee9ff", "#47b8ef", "#168bd0"
TEXT, MIST, MIST_BRIGHT, DIM, EYEBROW, FOOTER = (
    "#edf8ff", "#b6d0df", "#c7dce8", "#a6c1d0", "#82b6d0", "#7799ab")
MONO_ACCENT, TAG_TEXT, LINE_STRONG = "#8ddbf8", "#b9e9fb", "#2c6380"
PAGE_GLOW = "#104164"                                  # --gradient-page glow
CARD_ALT, CARD_ALT_END = "#17445e", "#0a1f31"          # --gradient-card-alt
CARD_DEEP = "#12364c"                                  # --gradient-card-deep
PANEL_GRAD = "#0d2d45"                                 # --gradient-panel
SIGNAL_END = "#0b2034"                                 # --gradient-signal
PRIMARY_END = "#1584ca"                                # --gradient-primary


def svg_open(title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{PX_W}" height="{PX_H}" '
            f'viewBox="0 0 {W} {fnum(CH)}"><title>{title}</title><defs>'
            '<filter id="soft1" x="-40%" y="-40%" width="180%" height="180%">'
            '<feGaussianBlur stdDeviation="1.2"/></filter>'
            '<filter id="soft2" x="-80%" y="-80%" width="260%" height="260%">'
            '<feGaussianBlur stdDeviation="3"/></filter>'
            '<filter id="soft3" x="-80%" y="-80%" width="260%" height="260%">'
            '<feGaussianBlur stdDeviation="4.5"/></filter>'
            '<filter id="soft6" x="-60%" y="-60%" width="220%" height="220%">'
            '<feGaussianBlur stdDeviation="8"/></filter>')


def full_rect(fill, opacity=None, extra=""):
    op = f' opacity="{opacity}"' if opacity is not None else ""
    return f'<rect width="{W}" height="{fnum(CH)}" fill="{fill}"{op}{extra}/>'


def hex_region(pid, cx, cy, r, opacity):
    """A hexagon lattice faded in around (cx, cy). The mask and the rect
    cover only the circle's box: a canvas-sized mask doubles the load time."""
    box = f'x="{cx - r}" y="{cy - r}" width="{2 * r}" height="{2 * r}"'
    return (f'<mask id="{pid}m" maskUnits="userSpaceOnUse" {box}>'
            f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="url(#{pid}mg)"/></mask>'
            f'<rect {box} fill="url(#{pid})" opacity="{opacity}" mask="url(#{pid}m)"/>')


def hex_defs(pid, stroke):
    return (hero.hex_pattern_def(pid, stroke, 1.0)
            + hero.radial_def(f"{pid}mg", [(0, TEXT, 1), (1, TEXT, 0)]))


def dot(x, y, r, colour, alpha, filt=None):
    """fill-opacity, not opacity: librsvg draws it without a layer per dot."""
    f = f' filter="url(#{filt})"' if filt else ""
    return (f'<circle cx="{fnum(x)}" cy="{fnum(y)}" r="{fnum(r)}" fill="{colour}" '
            f'fill-opacity="{alpha:.2f}"{f}/>')


def stars(seed, n, ymax, palette, fade_from=None):
    """The hero series' star field (same distribution), drawn with dot()."""
    rng = random.Random(seed)
    out = []
    for _ in range(n):
        x, y = rng.uniform(0, W), rng.uniform(0, ymax)
        r = 0.5 + rng.random() ** 2.2 * 1.5
        op = 0.2 + rng.random() * 0.72
        if fade_from is not None and y > fade_from:
            op *= max(0.0, 1 - (y - fade_from) / (ymax - fade_from))
        if op < 0.03:
            continue
        c = rng.choice(palette)
        out.append(dot(x, y, r, c, op))
        if rng.random() < 0.03:  # rare bright star with glow
            out.append(dot(x, y, r * 4, c, op * 0.16, "soft2"))
    return "".join(out)


def ridge_layer(parts):
    """Hero-coordinate artwork, moved down onto the taller canvas."""
    return f'<g transform="translate(0,{DY})">{"".join(parts)}</g>'


def closed(pts):
    return hero.closed_d(pts, bottom=fnum(CH - DY + 4))


def clips():
    return (f'<clipPath id="clipMain"><path d="{closed(hero.MAIN)}"/></clipPath>'
            f'<clipPath id="clipMid"><path d="{closed(hero.MID)}"/></clipPath>'
            f'<clipPath id="clipFar"><path d="{closed(hero.FAR)}"/></clipPath>')


def hero_rect(fill, opacity=None):
    """A rect covering the canvas in hero coordinates (inside ridge_layer)."""
    op = f' opacity="{opacity}"' if opacity is not None else ""
    return f'<rect y="{-DY}" width="{W}" height="{fnum(CH)}" fill="{fill}"{op}/>'


def snowfall(seed, colour):
    """Near flakes sharp, mid flakes soft, a few blurred bokeh flakes."""
    rng = random.Random(seed)
    groups = [(110, 0.9, 1.9, 0.26, 0.5, None),
              (80, 1.8, 3.0, 0.12, 0.26, None),
              (20, 3.6, 6.0, 0.07, 0.16, "soft3")]
    out = []
    for n, r0, r1, o0, o1, filt in groups:
        for _ in range(n):
            x, y, r = rng.uniform(0, W), rng.uniform(0, CH), rng.uniform(r0, r1)
            out.append(dot(x, y, r, colour, rng.uniform(o0, o1), filt))
    return "".join(out)


def sparkles(seed, n, y0, y1, colour, op_lo, op_hi, r_lo=0.6, r_hi=1.5):
    rng = random.Random(seed)
    out = []
    for _ in range(n):
        x, y = rng.uniform(0, W), rng.uniform(y0, y1)
        out.append(dot(x, y, rng.uniform(r_lo, r_hi), colour, rng.uniform(op_lo, op_hi)))
    return "".join(out)


# ------------------------------------------------------------------- night --

def scene_night():
    p = [svg_open("Snow — Night")]
    p.append(hero.lin_def("sky", 0, 0, 0, 1, [
        (0, ON_PRIMARY, 1), (0.3, INK, 1), (0.52, CARD_ALT_END, 1),
        (0.68, CARD_DEEP, 1), (1, PANEL, 1)]))
    p.append(f'<radialGradient id="pageglow" cx="0.82" cy="0.02" r="0.55">'
             f'<stop offset="0" stop-color="{PAGE_GLOW}" stop-opacity="0.55"/>'
             f'<stop offset="1" stop-color="{PAGE_GLOW}" stop-opacity="0"/></radialGradient>')
    p.append(hero.radial_def("moonglow", [(0, TEXT, 0.5), (0.35, ICE, 0.14), (1, ICE, 0)]))
    p.append(hero.lin_def("moonlight", 1, 0, 0, 1, [(0, MIST_BRIGHT, 0.3), (0.55, MIST_BRIGHT, 0)]))
    p.append(hero.lin_def("snow", 0, 330, 0, hero.HORIZON, [
        (0, DIM, 1), (0.42, LINE_STRONG, 1), (1, PANEL, 1)], user=True))
    p.append(hero.lin_def("shade", 0, 0, 1, 0, [(0, ON_PRIMARY, 0.55), (0.5, ON_PRIMARY, 0)]))
    p.append(hero.lin_def("caps", 0, 330, 0, 780, [(0, TEXT, 0.6), (1, TEXT, 0)], user=True))
    p.append(hero.lin_def("haze", 0, 690, 0, hero.HORIZON, [
        (0, EYEBROW, 0), (1, EYEBROW, 0.26)], user=True))
    p.append(hero.lin_def("field", 0, 0, 0, 1, [(0, PANEL, 1), (1, ON_PRIMARY, 1)]))
    p.append(hero.radial_def("vig", [(0.62, ON_PRIMARY, 0), (1, ON_PRIMARY, 1)]))
    p.append(hex_defs("hexn", ICE))
    p.append(clips())
    p.append("</defs>")

    p.append(full_rect("url(#sky)"))
    p.append(full_rect("url(#pageglow)"))
    p.append(stars(101, 620, DY + 1080, [TEXT, TEXT, MIST_BRIGHT, TAG_TEXT]))
    p.append(hex_region("hexn", 2560, 560, 680, 0.05))
    p.append(hero.constellation_snowflake(2420, 470, 104, 0.07, 0.5, color=MIST_BRIGHT))
    # moon, upper right like every scene in the series
    p.append('<circle cx="2960" cy="500" r="380" fill="url(#moonglow)"/>')
    p.append(f'<circle cx="2960" cy="500" r="46" fill="{TEXT}"/>')
    p.append(f'<circle cx="2960" cy="500" r="46" fill="none" stroke="{TEXT}" '
             'stroke-width="1.5" opacity="0.5"/>')

    MAIN, MID, FAR, FIELD = hero.MAIN, hero.MID, hero.FAR, hero.FIELD
    p.append(ridge_layer([
        f'<path d="{closed(FAR)}" fill="{CARD_DEEP}"/>',
        f'<g clip-path="url(#clipFar)">{hero_rect("url(#moonlight)", 0.35)}</g>',
        hero_rect("url(#haze)", 0.35),
        f'<path d="{closed(MID)}" fill="{PANEL_BRIGHT}"/>',
        f'<g clip-path="url(#clipMid)">{hero_rect("url(#moonlight)", 0.55)}'
        f'{hero_rect("url(#caps)", 0.26)}</g>',
        f'<path d="{hero.poly_d(MID)}" fill="none" stroke="{MIST}" stroke-width="2" opacity="0.16"/>',
        hero_rect("url(#haze)", 0.25),
        f'<path d="{closed(MAIN)}" fill="url(#snow)"/>',
        f'<g clip-path="url(#clipMain)">{hero_rect("url(#shade)")}'
        f'{hero_rect("url(#moonlight)")}{hero_rect("url(#caps)")}</g>',
        f'<path d="{hero.poly_d(MAIN)}" fill="none" stroke="{MIST_BRIGHT}" stroke-width="5" '
        'opacity="0.22" filter="url(#soft2)"/>',
        f'<path d="{hero.poly_d(MAIN)}" fill="none" stroke="{TEXT}" stroke-width="2.2" opacity="0.45"/>',
        hero_rect("url(#haze)", 0.15),
        f'<path d="{closed(FIELD)}" fill="url(#field)"/>',
    ]))
    p.append(sparkles(103, 60, DY + 1180, CH - 12, MIST_BRIGHT, 0.08, 0.24))
    p.append(snowfall(104, TEXT))
    p.append(full_rect("url(#vig)", 0.34))
    p.append("</svg>")
    return "".join(p)


# --------------------------------------------------------------------- day --

def scene_day():
    p = [svg_open("Snow — Day")]
    p.append(hero.lin_def("sky", 0, 0, 0, 1, [
        (0, PRIMARY_END, 1), (0.34, SKY, 1), (0.56, MONO_ACCENT, 1),
        (0.7, MIST_BRIGHT, 1), (1, TEXT, 1)]))
    p.append(hero.radial_def("sunglow", [(0, TEXT, 0.8), (0.4, TEXT, 0.24), (1, TEXT, 0)]))
    p.append(hero.lin_def("snow", 0, 330, 0, hero.HORIZON, [
        (0, TEXT, 1), (0.5, MIST_BRIGHT, 1), (1, DIM, 1)], user=True))
    p.append(hero.lin_def("sunlight", 1, 0, 0, 1, [(0, TEXT, 0.7), (0.55, TEXT, 0)]))
    p.append(hero.lin_def("shade", 0, 0, 1, 0, [(0, FOOTER, 0.5), (0.5, FOOTER, 0)]))
    p.append(hero.lin_def("haze", 0, 700, 0, hero.HORIZON, [(0, TEXT, 0), (1, TEXT, 0.4)], user=True))
    p.append(hero.lin_def("field", 0, 0, 0, 1, [(0, TEXT, 1), (1, MIST_BRIGHT, 1)]))
    p.append(hex_defs("hexd", EYEBROW))
    p.append(clips())
    p.append("</defs>")

    p.append(full_rect("url(#sky)"))
    p.append('<circle cx="3080" cy="430" r="560" fill="url(#sunglow)"/>')
    for cx, cy, rx, ry, op in [(880, 470, 430, 13, 0.22), (1560, 360, 300, 9, 0.16),
                               (2440, 620, 360, 11, 0.14), (520, 900, 520, 14, 0.12)]:
        p.append(f'<ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}" fill="{TEXT}" '
                 f'opacity="{op}" filter="url(#soft6)"/>')

    MAIN, MID, FAR, FIELD = hero.MAIN, hero.MID, hero.FAR, hero.FIELD
    p.append(ridge_layer([
        f'<path d="{closed(FAR)}" fill="{MIST}"/>',
        hero_rect("url(#haze)", 0.4),
        f'<path d="{closed(MID)}" fill="{EYEBROW}"/>',
        f'<g clip-path="url(#clipMid)">{hero_rect("url(#sunlight)", 0.5)}</g>',
        hero_rect("url(#haze)", 0.35),
        f'<path d="{closed(MAIN)}" fill="url(#snow)"/>',
        f'<g clip-path="url(#clipMain)">{hero_rect("url(#shade)")}{hero_rect("url(#sunlight)")}</g>',
        f'<path d="{hero.poly_d(MAIN)}" fill="none" stroke="{TEXT}" stroke-width="2.4" opacity="0.85"/>',
        hero_rect("url(#haze)", 0.25),
        f'<path d="{closed(FIELD)}" fill="url(#field)"/>',
    ]))
    # wind-shaped shadows and a hexagon lattice pressed into the snowfield
    for cx, cy, rx, ry, op in [(700, 1790, 1250, 70, 0.12), (2120, 1900, 1500, 84, 0.10),
                               (3080, 1760, 950, 56, 0.12), (1400, 2120, 1700, 90, 0.08)]:
        p.append(f'<ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}" fill="{DIM}" '
                 f'opacity="{op}" filter="url(#soft6)"/>')
    p.append(hex_region("hexd", 900, 1900, 640, 0.06))
    p.append(sparkles(203, 90, DY + 1170, CH - 10, TEXT, 0.4, 0.85, 0.7, 1.6))
    # eight sparkles trace a golden-ratio spiral, as in Alpine Morning
    phi = (1 + math.sqrt(5)) / 2
    for i in range(8):
        a, r = i * 0.9, 14 * phi ** (i * 0.55)
        x, y = 2620 + r * math.cos(a), 1880 + r * math.sin(a) * 0.35
        p.append(dot(x, y, 1.6, TEXT, 0.6))
    p.append("</svg>")
    return "".join(p)


SCENES = {"snow-d.svg": scene_night, "snow-l.svg": scene_day}


def render_png(svg_path, png_path):
    """Load the SVG the way mutter does (GdkPixbuf's librsvg loader, at the
    intrinsic size) and save it as a PNG preview."""
    import gi
    gi.require_version("GdkPixbuf", "2.0")
    from gi.repository import GdkPixbuf
    GdkPixbuf.Pixbuf.new_from_file(str(svg_path)).savev(str(png_path), "png", [], [])


def main(argv):
    if "--check" in argv:
        stale = [name for name, scene in SCENES.items()
                 if not (OUT / name).is_file() or (OUT / name).read_text() != scene()]
        for name in stale:
            print(f"stale: {OUT / name} (run {Path(__file__).relative_to(REPO)})")
        return 1 if stale else 0
    OUT.mkdir(parents=True, exist_ok=True)
    for name, scene in SCENES.items():
        svg = scene()
        (OUT / name).write_text(svg)
        print(f"wrote {OUT / name} ({len(svg) / 1024:.0f} KiB)")
    if "--render" in argv:
        outdir = Path(argv[argv.index("--render") + 1])
        outdir.mkdir(parents=True, exist_ok=True)
        for name in SCENES:
            png = outdir / name.replace(".svg", ".png")
            render_png(OUT / name, png)
            print(f"wrote {png}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
