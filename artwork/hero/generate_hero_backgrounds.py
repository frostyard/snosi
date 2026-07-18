#!/usr/bin/env python3
"""Generate the four Snow brand hero backgrounds (3440x1440, 21:9-ish).

All four scenes share EXACTLY the same mountain silhouette geometry: the
ridge polylines below are generated once (seeded midpoint displacement over
hand-placed control points) and reused verbatim in every scene. Only fills,
lighting, atmosphere, and easter eggs change per scene.

Scenes:
  01 moonlit-summit    - navy night, stars, moonlight, drifting snow
  02 alpine-morning    - crisp daylight, glacier blues
  03 blueprint         - slate blueprint, white line art, contours, circuits
  04 frozen-reflection - blue-hour twilight, mirrored frozen lake, etched "Snow"

Easter eggs (all understated): snowflake constellation, hexagon lattices,
binary digits ("Snow" in ASCII binary on the blueprint; 0b110101110000 = 3440),
golden-ratio summit placement (x = 2126 = 3440 * 0.618).

Usage: python3 generate_hero_backgrounds.py [outdir]
Requires only the Python stdlib to emit SVGs. PNG rendering (render_png)
uses pycairo + gi/Rsvg when available.
"""

import math
import random
import sys
from pathlib import Path

W, H = 3440, 1440
HORIZON = 1150
SUMMIT = (2126, 356)  # x = 3440 * (1 - 1/phi) -- golden ratio placement

# ---------------------------------------------------------------- geometry --

MAIN_CTRL = [
    (0, 1010), (170, 962), (360, 995), (545, 905), (750, 940),
    (960, 806), (1150, 848), (1345, 645), (1520, 706), (1700, 566),
    (1930, 470), SUMMIT,
    (2270, 468), (2410, 432), (2580, 562), (2770, 524),
    (2960, 648), (3140, 622), (3300, 724), (3440, 692),
]
MID_CTRL = [
    (0, 942), (230, 880), (470, 912), (720, 806), (980, 850),
    (1240, 760), (1520, 820), (1800, 700), (2060, 760), (2350, 690),
    (2640, 752), (2930, 700), (3200, 762), (3440, 730),
]
FAR_CTRL = [
    (0, 880), (260, 812), (520, 846), (800, 762), (1060, 800),
    (1330, 742), (1620, 778), (1900, 726), (2180, 768), (2500, 736),
    (2820, 780), (3040, 742), (3260, 668), (3440, 706),
]
FIELD_CTRL = [
    (0, 1136), (400, 1128), (900, 1140), (1500, 1130),
    (2100, 1142), (2700, 1132), (3100, 1140), (3440, 1134),
]


def subdivide(pts, iters, seed, amp=0.045, ymin=340, ymax=HORIZON - 6):
    rng = random.Random(seed)
    pts = list(pts)
    for _ in range(iters):
        out = [pts[0]]
        for a, b in zip(pts, pts[1:]):
            mx = (a[0] + b[0]) / 2.0
            my = (a[1] + b[1]) / 2.0 + rng.uniform(-1, 1) * (b[0] - a[0]) * amp
            out.append((mx, max(ymin, min(ymax, my))))
            out.append(b)
        pts = out
    return pts


MAIN = subdivide(MAIN_CTRL, 3, seed=41)
MID = subdivide(MID_CTRL, 3, seed=42, amp=0.035)
FAR = subdivide(FAR_CTRL, 3, seed=43, amp=0.028)
FIELD = subdivide(FIELD_CTRL, 2, seed=44, amp=0.004, ymin=1120, ymax=1148)


def fnum(v):
    s = f"{v:.1f}"
    return s[:-2] if s.endswith(".0") else s


def poly_d(pts):
    return "M" + "L".join(f"{fnum(x)},{fnum(y)}" for x, y in pts)


def closed_d(pts, bottom=H + 4):
    return (f"M-4,{fnum(pts[0][1])}L" + poly_d(pts)[1:]
            + f"L{W + 4},{fnum(pts[-1][1])}L{W + 4},{bottom}L-4,{bottom}Z")


def height_at(pts, x):
    if x <= pts[0][0]:
        return pts[0][1]
    for a, b in zip(pts, pts[1:]):
        if a[0] <= x <= b[0]:
            t = (x - a[0]) / (b[0] - a[0]) if b[0] > a[0] else 0
            return a[1] + t * (b[1] - a[1])
    return pts[-1][1]


def intervals_above(pts, level, step=6):
    """x-intervals where the ridge skyline is above (smaller y than) level."""
    spans, start, x = [], None, 0
    while x <= W:
        above = height_at(pts, x) < level
        if above and start is None:
            start = x
        elif not above and start is not None:
            spans.append((start, x))
            start = None
        x += step
    if start is not None:
        spans.append((start, W))
    return [(a, b) for a, b in spans if b - a > 24]


# ------------------------------------------------------------------ pieces --

def stars(seed, n, ymax=1080, base_op=1.0, fade_from=None, palette=None):
    rng = random.Random(seed)
    palette = palette or ["#dbe7fa", "#dbe7fa", "#cfe0ff", "#fdf6e8"]
    out = []
    for _ in range(n):
        x, y = rng.uniform(0, W), rng.uniform(0, ymax)
        r = 0.5 + rng.random() ** 2.2 * 1.5
        op = (0.2 + rng.random() * 0.72) * base_op
        if fade_from is not None and y > fade_from:
            op *= max(0.0, 1 - (y - fade_from) / (ymax - fade_from))
        if op < 0.03:
            continue
        c = rng.choice(palette)
        out.append(f'<circle cx="{fnum(x)}" cy="{fnum(y)}" r="{fnum(r)}" '
                   f'fill="{c}" opacity="{op:.2f}"/>')
        if rng.random() < 0.03:  # rare bright star with glow
            out.append(f'<circle cx="{fnum(x)}" cy="{fnum(y)}" r="{fnum(r * 4)}" '
                       f'fill="{c}" opacity="{op * 0.16:.2f}" filter="url(#soft2)"/>')
    return "".join(out)


def binary_flecks(seed, n, box, fill, op_lo=0.07, op_hi=0.15, size=13):
    """Tiny 0/1 glyphs that read as specks until you zoom in."""
    rng = random.Random(seed)
    x0, y0, x1, y1 = box
    out = []
    for _ in range(n):
        x, y = rng.uniform(x0, x1), rng.uniform(y0, y1)
        out.append(
            f'<text x="{fnum(x)}" y="{fnum(y)}" font-family="DejaVu Sans Mono,monospace" '
            f'font-size="{size}" fill="{fill}" opacity="{rng.uniform(op_lo, op_hi):.2f}"'
            f'>{rng.choice("01")}</text>')
    return "".join(out)


def hex_pattern_def(pid, stroke, width=1.0, r=52):
    hh = math.sqrt(3) * r / 2
    pts = [(r, 0), (r / 2, hh), (-r / 2, hh), (-r, 0), (-r / 2, -hh), (r / 2, -hh)]
    d = "M" + "L".join(f"{fnum(px)},{fnum(py)}" for px, py in pts) + "Z"
    tw, th = 3 * r, 2 * hh
    cells = [(0, 0), (tw, 0), (0, th), (tw, th), (1.5 * r, hh)]
    hexes = "".join(
        f'<path d="{d}" transform="translate({fnum(cx)},{fnum(cy)})" '
        f'fill="none" stroke="{stroke}" stroke-width="{width}"/>' for cx, cy in cells)
    return (f'<pattern id="{pid}" width="{fnum(tw)}" height="{fnum(th)}" '
            f'patternUnits="userSpaceOnUse">{hexes}</pattern>')


def hex_region(pid, mid, cx, cy, r, opacity):
    return (f'<mask id="{mid}"><rect width="{W}" height="{H}" fill="black"/>'
            f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="url(#{mid}g)"/></mask>'
            f'<rect width="{W}" height="{H}" fill="url(#{pid})" opacity="{opacity}" '
            f'mask="url(#{mid})"/>')


def radial_def(gid, stops):
    s = "".join(f'<stop offset="{o}" stop-color="{c}" stop-opacity="{a}"/>'
                for o, c, a in stops)
    return f'<radialGradient id="{gid}">{s}</radialGradient>'


def lin_def(gid, x1, y1, x2, y2, stops, user=False):
    u = ' gradientUnits="userSpaceOnUse"' if user else ""
    s = "".join(f'<stop offset="{o}" stop-color="{c}" stop-opacity="{a}"/>'
                for o, c, a in stops)
    return (f'<linearGradient id="{gid}" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}"{u}>'
            f'{s}</linearGradient>')


def snowfall(seed):
    rng = random.Random(seed)
    groups = [(85, 0.9, 1.9, 0.28, 0.52, None),
              (65, 1.8, 3.0, 0.18, 0.36, "soft1"),
              (16, 3.6, 6.0, 0.08, 0.18, "soft3")]
    out = []
    for n, r0, r1, o0, o1, filt in groups:
        f = f' filter="url(#{filt})"' if filt else ""
        for _ in range(n):
            out.append(f'<circle cx="{fnum(rng.uniform(0, W))}" '
                       f'cy="{fnum(rng.uniform(0, H))}" '
                       f'r="{fnum(rng.uniform(r0, r1))}" fill="#eaf2ff" '
                       f'opacity="{rng.uniform(o0, o1):.2f}"{f}/>')
    return "".join(out)


def constellation_snowflake(cx, cy, r, line_op, star_op, color="#dbe7fa"):
    """Six-fold snowflake drawn as a faint constellation: lines + node stars."""
    out, nodes = [], []
    for k in range(6):
        a = math.radians(60 * k - 90)
        tip = (cx + r * math.cos(a), cy + r * math.sin(a))
        mid = (cx + 0.52 * r * math.cos(a), cy + 0.52 * r * math.sin(a))
        out.append(f'<path d="M{fnum(cx)},{fnum(cy)}L{fnum(tip[0])},{fnum(tip[1])}" '
                   f'stroke="{color}" stroke-width="1" opacity="{line_op}" fill="none"/>')
        for side in (-1, 1):  # small branch off each spoke
            b = a + side * math.radians(52)
            bx, by = mid[0] + 0.30 * r * math.cos(b), mid[1] + 0.30 * r * math.sin(b)
            out.append(f'<path d="M{fnum(mid[0])},{fnum(mid[1])}L{fnum(bx)},{fnum(by)}" '
                       f'stroke="{color}" stroke-width="1" opacity="{line_op}" fill="none"/>')
            nodes.append((bx, by, 1.1))
        nodes += [(tip[0], tip[1], 1.7), (mid[0], mid[1], 1.2)]
    nodes.append((cx, cy, 1.9))
    for x, y, rr in nodes:
        out.append(f'<circle cx="{fnum(x)}" cy="{fnum(y)}" r="{rr}" '
                   f'fill="{color}" opacity="{star_op}"/>')
    return "".join(out)


def vignette(gid, opacity):
    return (f'<rect width="{W}" height="{H}" fill="url(#{gid})" opacity="{opacity}" '
            f'pointer-events="none"/>')


def svg_open(title):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
            f'viewBox="0 0 {W} {H}"><title>{title}</title>'
            '<defs>'
            '<filter id="soft1" x="-40%" y="-40%" width="180%" height="180%">'
            '<feGaussianBlur stdDeviation="1.2"/></filter>'
            '<filter id="soft2" x="-80%" y="-80%" width="260%" height="260%">'
            '<feGaussianBlur stdDeviation="3"/></filter>'
            '<filter id="soft3" x="-80%" y="-80%" width="260%" height="260%">'
            '<feGaussianBlur stdDeviation="4.5"/></filter>'
            '<filter id="soft6" x="-60%" y="-60%" width="220%" height="220%">'
            '<feGaussianBlur stdDeviation="8"/></filter>')


def clips():
    return (f'<clipPath id="clipMain"><path d="{closed_d(MAIN)}"/></clipPath>'
            f'<clipPath id="clipMid"><path d="{closed_d(MID)}"/></clipPath>'
            f'<clipPath id="clipFar"><path d="{closed_d(FAR)}"/></clipPath>'
            f'<clipPath id="clipLake"><rect x="0" y="{HORIZON}" width="{W}" '
            f'height="{H - HORIZON}"/></clipPath>')


# ------------------------------------------------------------------ scenes --

def scene_moonlit():
    p = [svg_open("Snow — Moonlit Summit")]
    p.append(lin_def("sky", 0, 0, 0, 1, [
        (0, "#050b1a", 1), (0.5, "#0a1530", 1), (0.82, "#122242", 1), (1, "#1b3054", 1)]))
    p.append(lin_def("fieldg", 0, 0, 0, 1, [(0, "#12203c", 1), (1, "#080f20", 1)]))
    p.append(lin_def("moonlight", 1, 0, 0, 1, [
        (0, "#b9d2f2", 0.30), (0.55, "#b9d2f2", 0.0)]))
    p.append(lin_def("msnow1", 0, 330, 0, HORIZON, [
        (0, "#b7cfec", 1), (0.42, "#55719e", 1), (1, "#23355b", 1)], user=True))
    p.append(lin_def("nshade", 0, 0, 1, 0, [
        (0, "#0a1630", 0.5), (0.5, "#0a1630", 0.0)]))
    p.append(lin_def("caps", 0, 330, 0, 780, [
        (0, "#e7f1fd", 0.65), (1, "#e7f1fd", 0.0)], user=True))
    p.append(lin_def("hazen", 0, 690, 0, HORIZON, [
        (0, "#7f9cc4", 0.0), (1, "#7f9cc4", 0.28)], user=True))
    p.append(radial_def("moonglow", [(0, "#e8f1ff", 0.55), (0.35, "#c6dbf7", 0.16),
                                     (1, "#c6dbf7", 0.0)]))
    p.append(radial_def("vig", [(0.62, "#000000", 0.0), (1, "#02060f", 1)]))
    p.append(hex_pattern_def("hexn", "#cfe0ff", 1.0))
    p.append(radial_def("hexnmg", [(0, "#ffffff", 1), (1, "#ffffff", 0)]))
    p.append(clips())
    p.append("</defs>")

    p.append(f'<rect width="{W}" height="{H}" fill="url(#sky)"/>')
    p.append(stars(101, 470))
    p.append(binary_flecks(102, 24, (60, 60, W - 60, 860), "#cfe0ff"))
    # faint hexagon lattice blended into the sky near the moon
    p.append(hex_region("hexn", "hexnm", 2540, 330, 620, 0.05))
    # constellation easter eggs
    p.append(constellation_snowflake(2410, 240, 96, 0.07, 0.5))
    p.append('<g opacity="0.75">')
    dip = [(430, 545), (556, 512), (688, 528), (812, 480), (872, 560), (996, 585),
           (1096, 530)]
    p.append(f'<path d="{poly_d(dip)}" stroke="#dbe7fa" stroke-width="1" '
             f'opacity="0.06" fill="none"/>')
    for x, y in dip:
        p.append(f'<circle cx="{x}" cy="{y}" r="1.5" fill="#dbe7fa" opacity="0.4"/>')
    p.append("</g>")
    # moon
    p.append('<circle cx="2950" cy="255" r="340" fill="url(#moonglow)"/>')
    p.append('<circle cx="2950" cy="255" r="42" fill="#eef4ff"/>')
    p.append('<circle cx="2950" cy="255" r="42" fill="none" stroke="#ffffff" '
             'stroke-width="1.5" opacity="0.5"/>')

    # ridges, far to near
    p.append(f'<path d="{closed_d(FAR)}" fill="#223a5f"/>')
    p.append(f'<g clip-path="url(#clipFar)"><rect width="{W}" height="{H}" '
             f'fill="url(#moonlight)" opacity="0.35"/></g>')
    p.append(f'<rect width="{W}" height="{H}" fill="url(#hazen)" opacity="0.35"/>')
    p.append(f'<path d="{closed_d(MID)}" fill="#182c4c"/>')
    p.append(f'<g clip-path="url(#clipMid)"><rect width="{W}" height="{H}" '
             f'fill="url(#moonlight)" opacity="0.55"/>'
             f'<rect width="{W}" height="{H}" fill="url(#caps)" opacity="0.28"/></g>')
    p.append(f'<path d="{poly_d(MID)}" fill="none" stroke="#9db9de" '
             f'stroke-width="2" opacity="0.18"/>')
    p.append(f'<rect width="{W}" height="{H}" fill="url(#hazen)" opacity="0.25"/>')
    p.append(f'<path d="{closed_d(MAIN)}" fill="url(#msnow1)"/>')
    p.append(f'<g clip-path="url(#clipMain)">'
             f'<rect width="{W}" height="{H}" fill="url(#nshade)"/>'
             f'<rect width="{W}" height="{H}" fill="url(#moonlight)"/>'
             f'<rect width="{W}" height="{H}" fill="url(#caps)"/></g>')
    p.append(f'<path d="{poly_d(MAIN)}" fill="none" stroke="#cfe2fa" '
             f'stroke-width="5" opacity="0.22" filter="url(#soft2)"/>')
    p.append(f'<path d="{poly_d(MAIN)}" fill="none" stroke="#dbe9fb" '
             f'stroke-width="2.2" opacity="0.5"/>')
    p.append(f'<rect width="{W}" height="{H}" fill="url(#hazen)" opacity="0.15"/>')

    # snowfield foreground
    p.append(f'<path d="{closed_d(FIELD)}" fill="url(#fieldg)"/>')
    rng = random.Random(103)
    for _ in range(38):  # field sparkles
        p.append(f'<circle cx="{fnum(rng.uniform(0, W))}" '
                 f'cy="{fnum(rng.uniform(1180, H - 12))}" r="{fnum(rng.uniform(0.6, 1.4))}" '
                 f'fill="#dbe7fa" opacity="{rng.uniform(0.08, 0.24):.2f}"/>')
    p.append(snowfall(104))
    p.append(vignette("vig", 0.34))
    p.append("</svg>")
    return "".join(p)


def scene_morning():
    p = [svg_open("Snow — Alpine Morning")]
    p.append(lin_def("sky", 0, 0, 0, 1, [
        (0, "#5093c9", 1), (0.45, "#96c2e4", 1), (0.8, "#d3e8f6", 1), (1, "#eef7fc", 1)]))
    p.append(lin_def("fieldg", 0, 0, 0, 1, [(0, "#f6fbfe", 1), (1, "#dcebf6", 1)]))
    p.append(lin_def("mainsnow", 0, 330, 0, HORIZON, [
        (0, "#ffffff", 1), (0.5, "#ecf4fa", 1), (1, "#cfe2f1", 1)], user=True))
    p.append(lin_def("sunlight", 1, 0, 0, 1, [
        (0, "#ffffff", 0.7), (0.55, "#ffffff", 0.0)]))
    p.append(lin_def("shade", 0, 0, 1, 0, [
        (0, "#6d9cc4", 0.5), (0.5, "#6d9cc4", 0.0)]))
    p.append(lin_def("hazed", 0, 700, 0, HORIZON, [
        (0, "#ffffff", 0.0), (1, "#ffffff", 0.4)], user=True))
    p.append(radial_def("sunglow", [(0, "#ffffff", 0.75), (0.4, "#ffffff", 0.22),
                                    (1, "#ffffff", 0.0)]))
    p.append(hex_pattern_def("hexd", "#9fc2dd", 1.0))
    p.append(radial_def("hexdmg", [(0, "#ffffff", 1), (1, "#ffffff", 0)]))
    p.append(clips())
    p.append("</defs>")

    p.append(f'<rect width="{W}" height="{H}" fill="url(#sky)"/>')
    p.append('<circle cx="3080" cy="185" r="520" fill="url(#sunglow)"/>')
    # wisps of cirrus
    p.append('<ellipse cx="880" cy="215" rx="430" ry="13" fill="#ffffff" '
             'opacity="0.20" filter="url(#soft6)"/>')
    p.append('<ellipse cx="1560" cy="128" rx="300" ry="9" fill="#ffffff" '
             'opacity="0.14" filter="url(#soft6)"/>')
    p.append('<ellipse cx="2440" cy="330" rx="360" ry="11" fill="#ffffff" '
             'opacity="0.12" filter="url(#soft6)"/>')

    p.append(f'<path d="{closed_d(FAR)}" fill="#b6d1e9"/>')
    p.append(f'<rect width="{W}" height="{H}" fill="url(#hazed)" opacity="0.4"/>')
    p.append(f'<path d="{closed_d(MID)}" fill="#93b9dc"/>')
    p.append(f'<g clip-path="url(#clipMid)"><rect width="{W}" height="{H}" '
             f'fill="url(#sunlight)" opacity="0.5"/></g>')
    p.append(f'<rect width="{W}" height="{H}" fill="url(#hazed)" opacity="0.35"/>')
    p.append(f'<path d="{closed_d(MAIN)}" fill="url(#mainsnow)"/>')
    p.append(f'<g clip-path="url(#clipMain)">'
             f'<rect width="{W}" height="{H}" fill="url(#shade)"/>'
             f'<rect width="{W}" height="{H}" fill="url(#sunlight)"/></g>')
    p.append(f'<path d="{poly_d(MAIN)}" fill="none" stroke="#ffffff" '
             f'stroke-width="2.4" opacity="0.85"/>')
    p.append(f'<rect width="{W}" height="{H}" fill="url(#hazed)" opacity="0.25"/>')

    p.append(f'<path d="{closed_d(FIELD)}" fill="url(#fieldg)"/>')
    # soft wind-shaped shadows in the snowfield
    for cx, cy, rx, ry, op in [(700, 1265, 1250, 64, 0.10), (2120, 1350, 1500, 76, 0.09),
                               (3080, 1240, 950, 52, 0.10)]:
        p.append(f'<ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}" fill="#b9d3e8" '
                 f'opacity="{op}" filter="url(#soft6)"/>')
    # hexagon lattice pressed faintly into the snow
    p.append(hex_region("hexd", "hexdm", 900, 1290, 560, 0.06))
    # sparkles; eight of them trace a golden-ratio spiral (quiet math egg)
    rng = random.Random(203)
    for _ in range(54):
        p.append(f'<circle cx="{fnum(rng.uniform(0, W))}" '
                 f'cy="{fnum(rng.uniform(1170, H - 10))}" r="{fnum(rng.uniform(0.7, 1.6))}" '
                 f'fill="#ffffff" opacity="{rng.uniform(0.3, 0.8):.2f}"/>')
    phi = (1 + math.sqrt(5)) / 2
    for i in range(8):
        a, r = i * 0.9, 14 * phi ** (i * 0.55)
        x, y = 2620 + r * math.cos(a), 1300 + r * math.sin(a) * 0.35
        p.append(f'<circle cx="{fnum(x)}" cy="{fnum(y)}" r="1.6" fill="#ffffff" '
                 f'opacity="0.55"/>')
    p.append(binary_flecks(204, 12, (1500, 1315, 2500, 1395), "#8fb5d4",
                           0.10, 0.16, 12))
    p.append("</svg>")
    return "".join(p)


def scene_blueprint():
    ink, faint = "#e8f2fb", "#cfe3f5"
    p = [svg_open("Snow — Blueprint Edition")]
    p.append(lin_def("bp", 0, 0, 0, H, [
        (0, "#2b4d70", 1), (1, "#1d3854", 1)], user=True))
    p.append(radial_def("vig", [(0.6, "#000000", 0.0), (1, "#101f31", 1)]))
    p.append(hex_pattern_def("hexb", faint, 1.0))
    p.append(radial_def("hexbmg", [(0, "#ffffff", 1), (1, "#ffffff", 0)]))
    p.append(clips())
    p.append("</defs>")
    p.append(f'<rect width="{W}" height="{H}" fill="url(#bp)"/>')

    # engineering grid
    minor = "".join(f'<path d="M{x},0V{H}" />' for x in range(0, W + 1, 40)) + \
            "".join(f'<path d="M0,{y}H{W}" />' for y in range(0, H + 1, 40))
    major = "".join(f'<path d="M{x},0V{H}" />' for x in range(0, W + 1, 200)) + \
            "".join(f'<path d="M0,{y}H{W}" />' for y in range(0, H + 1, 200))
    p.append(f'<g stroke="{ink}" stroke-width="1" opacity="0.035" fill="none">{minor}</g>')
    p.append(f'<g stroke="{ink}" stroke-width="1" opacity="0.06" fill="none">{major}</g>')
    p.append(hex_region("hexb", "hexbm", 2860, 300, 560, 0.05))
    p.append(f'<text x="3252" y="586" font-family="DejaVu Sans Mono,monospace" '
             f'font-size="18" fill="{faint}" opacity="0.4">R = 52.0</text>')

    def hatch(ridge, levels, op, clip):
        segs = []
        for lv in levels:
            for a, b in intervals_above(ridge, lv):
                segs.append(f'<path d="M{fnum(a + 8)},{lv}L{fnum(b - 8)},{lv}"/>')
        return (f'<g clip-path="url(#{clip})" stroke="{ink}" stroke-width="1" '
                f'opacity="{op}" fill="none">{"".join(segs)}</g>')

    # far / mid / main line-art with bg-fill occlusion
    p.append(f'<path d="{closed_d(FAR)}" fill="url(#bp)"/>')
    p.append(f'<path d="{poly_d(FAR)}" fill="none" stroke="{ink}" '
             f'stroke-width="1.4" opacity="0.30"/>')
    p.append(f'<path d="{closed_d(MID)}" fill="url(#bp)"/>')
    p.append(f'<path d="{poly_d(MID)}" fill="none" stroke="{ink}" '
             f'stroke-width="1.6" opacity="0.45"/>')
    p.append(hatch(MID, range(720, 1140, 52), 0.05, "clipMid"))
    p.append(f'<path d="{closed_d(MAIN)}" fill="url(#bp)"/>')
    p.append(f'<path d="{closed_d(MAIN)}" fill="#ffffff" opacity="0.02"/>')
    p.append(hatch(MAIN, range(430, 1140, 52), 0.09, "clipMain"))
    # nested topo contours converging on the three named peaks
    p.append('<g clip-path="url(#clipMain)">')
    for ax, ay, span in [(2126, 356, 330), (1345, 645, 250), (2410, 432, 210)]:
        win = [pt for pt in MAIN if ax - span <= pt[0] <= ax + span]
        for t in (0.74, 0.5, 0.28):
            sc = [(ax + t * (x - ax), ay + t * (y - ay)) for x, y in win]
            p.append(f'<path d="{poly_d(sc)}" fill="none" stroke="{ink}" '
                     f'stroke-width="1" opacity="0.20"/>')
    p.append("</g>")
    p.append(f'<path d="{poly_d(MAIN)}" fill="none" stroke="{ink}" '
             f'stroke-width="2.4" opacity="0.95"/>')

    # datum line + ground contours
    p.append(f'<path d="M0,{HORIZON}H{W}" stroke="{ink}" stroke-width="1.2" '
             f'opacity="0.3" stroke-dasharray="14 10" fill="none"/>')
    rngc = random.Random(303)
    for i, y0 in enumerate(range(1204, 1420, 48)):
        pts, x = [], -10
        while x <= W + 10:
            pts.append((x, y0 + math.sin(x / 260 + i * 1.7) * (7 + i * 2)
                        + rngc.uniform(-2, 2)))
            x += 80
        p.append(f'<path d="{poly_d(pts)}" fill="none" stroke="{ink}" '
                 f'stroke-width="1" opacity="{0.18 - i * 0.02:.2f}"/>')
    # "Snow" in ASCII binary, riding the first ground contour
    word = "01010011 01101110 01101111 01110111"  # S n o w
    for i, ch in enumerate(word):
        x = 340 + i * 46
        y = 1246 + math.sin(x / 260) * 7
        p.append(f'<text x="{x}" y="{fnum(y)}" font-family="DejaVu Sans Mono,monospace" '
                 f'font-size="16" fill="{faint}" opacity="0.16">{ch}</text>')

    # circuit traces surfacing through the landscape
    traces = [
        ("M240,1444V1330H420V1268", (420, 1268)),
        ("M520,1444V1372H760V1310H900", (900, 1310)),
        ("M2660,1444V1380H2520V1330", (2520, 1330)),
        ("M-4,1230H240V1180H380", (380, 1180)),
        ("M-4,1052H210V1092H460V1058", (460, 1058)),
        ("M1560,1444V1396H1720V1352", (1720, 1352)),
    ]
    for d, (px, py) in traces:
        p.append(f'<path d="{d}" fill="none" stroke="#9fc6e8" stroke-width="1.6" '
                 f'opacity="0.14"/>')
        p.append(f'<circle cx="{px}" cy="{py}" r="5" fill="none" stroke="#9fc6e8" '
                 f'stroke-width="1.4" opacity="0.2"/>')
        p.append(f'<circle cx="{px}" cy="{py}" r="1.8" fill="#9fc6e8" opacity="0.25"/>')

    mono = 'font-family="DejaVu Sans Mono,monospace"'
    # summit dimension: extension lines, dimension line, arrowheads, label
    p.append(f'<g stroke="{faint}" stroke-width="1.1" opacity="0.5" fill="none">'
             f'<path d="M2136,356H2252"/><path d="M{W - 1200},{HORIZON}"/>'
             f'<path d="M2246,368V{HORIZON - 10}"/>'
             f'<path d="M2246,368l-5,12M2246,368l5,12"/>'
             f'<path d="M2246,{HORIZON - 10}l-5,-12M2246,{HORIZON - 10}l5,-12"/></g>')
    p.append(f'<text transform="translate(2274,742) rotate(-90)" {mono} '
             f'font-size="21" fill="{faint}" opacity="0.55" text-anchor="middle"'
             f'>ELEV 3440 · 0b110101110000</text>')
    # summit + secondary peak markers
    for x, y, label, anchor in [
            (2126, 356, "P1 · x/W = 0.618", "start"),
            (1345, 645, "P2 (1345, 645)", "end")]:
        p.append(f'<g stroke="{faint}" stroke-width="1" opacity="0.5" fill="none">'
                 f'<circle cx="{x}" cy="{y}" r="9"/>'
                 f'<path d="M{x - 15},{y}H{x + 15}M{x},{y - 15}V{y + 15}"/></g>')
        dx = 26 if anchor == "start" else -26
        p.append(f'<text x="{x + dx}" y="{y - 14}" {mono} font-size="19" '
                 f'fill="{faint}" opacity="0.5" text-anchor="{anchor}">{label}</text>')
    # slope angle annotation on the summit's west face
    p.append(f'<path d="M1930,470 h120" stroke="{faint}" stroke-width="1" '
             f'opacity="0.4" stroke-dasharray="5 5" fill="none"/>')
    p.append(f'<path d="M2028,470 A98,98 0 0 0 2016,420" stroke="{faint}" '
             f'stroke-width="1" opacity="0.45" fill="none"/>')
    p.append(f'<text x="2044" y="452" {mono} font-size="18" fill="{faint}" '
             f'opacity="0.5">θ = 30.2°</text>')
    p.append(f'<text x="2980" y="1178" {mono} font-size="19" fill="{faint}" '
             f'opacity="0.5">DATUM 0.000 · REF MSL</text>')
    p.append(f'<text x="120" y="1082" {mono} font-size="18" fill="{faint}" '
             f'opacity="0.42">∂z/∂x = 0.62</text>')

    # title block
    p.append(f'<g stroke="{faint}" stroke-width="1.2" opacity="0.35" fill="none">'
             f'<rect x="2952" y="1296" width="440" height="116"/>'
             f'<path d="M2952,1334H3392M2952,1372H3392"/></g>')
    for i, line in enumerate(["SNOW · ALPINE SERIES", "SHEET 03 / 04 · BLUEPRINT",
                              "SCALE 1:1440 · REV 0x0D70"]):
        p.append(f'<text x="2972" y="{1322 + i * 38}" {mono} font-size="18" '
                 f'fill="{faint}" opacity="0.55">{line}</text>')
    p.append(vignette("vig", 0.22))
    p.append("</svg>")
    return "".join(p)


def scene_reflection():
    p = [svg_open("Snow — Frozen Reflection")]
    p.append(lin_def("sky", 0, 0, 0, 1, [
        (0, "#0a1428", 1), (0.4, "#16294b", 1), (0.7, "#2e4a77", 1),
        (0.92, "#52709f", 1), (1, "#6c86ad", 1)]))
    p.append(lin_def("lakeg", 0, HORIZON, 0, H, [
        (0, "#6480ac", 1), (0.5, "#4d6b9d", 1), (1, "#3c5a8a", 1)], user=True))
    p.append(lin_def("caps4", 0, 330, 0, 760, [
        (0, "#93aed6", 0.34), (1, "#93aed6", 0.0)], user=True))
    p.append(lin_def("haze4", 0, 760, 0, HORIZON, [
        (0, "#5d7aa8", 0.0), (1, "#5d7aa8", 0.4)], user=True))
    p.append(lin_def("reflfade", 0, HORIZON, 0, H, [
        (0, "#0c1731", 0.0), (1, "#0c1731", 0.14)], user=True))
    p.append(radial_def("vig", [(0.6, "#000000", 0.0), (1, "#040a16", 1)]))
    p.append(radial_def("venus", [(0, "#f2f6ff", 0.8), (0.25, "#cfdcf7", 0.2),
                                  (1, "#cfdcf7", 0.0)]))
    p.append(hex_pattern_def("hexi", "#cfe0f2", 1.0))
    p.append(radial_def("heximg", [(0, "#ffffff", 1), (1, "#ffffff", 0)]))
    p.append(clips())
    p.append("</defs>")

    p.append(f'<rect width="{W}" height="{H}" fill="url(#sky)"/>')
    p.append(f'<g id="sky4stars">{stars(401, 230, ymax=980, fade_from=380)}</g>')
    p.append(binary_flecks(402, 10, (100, 80, W - 100, 500), "#cfe0f2", 0.06, 0.11))
    p.append('<circle cx="2700" cy="298" r="42" fill="url(#venus)"/>')
    p.append('<circle cx="2700" cy="298" r="2.6" fill="#f5f8ff" opacity="0.95"/>')

    ridges = (f'<path d="{closed_d(FAR)}" fill="#2c4670"/>'
              f'<path d="{closed_d(MID)}" fill="#1d3358"/>'
              f'<g clip-path="url(#clipMid)"><rect width="{W}" height="{H}" '
              f'fill="url(#caps4)" opacity="0.5"/></g>'
              f'<path d="{closed_d(MAIN)}" fill="#12213f"/>'
              f'<g clip-path="url(#clipMain)"><rect width="{W}" height="{H}" '
              f'fill="url(#caps4)"/></g>')
    p.append(f'<g id="ridges4">{ridges}</g>')
    p.append(f'<path d="{poly_d(MAIN)}" fill="none" stroke="#8fa9cf" '
             f'stroke-width="2" opacity="0.3"/>')
    p.append(f'<rect width="{W}" height="{H}" fill="url(#haze4)"/>')

    # ---- frozen lake ----
    p.append(f'<rect x="0" y="{HORIZON}" width="{W}" height="{H - HORIZON}" '
             f'fill="url(#lakeg)"/>')
    p.append(f'<g clip-path="url(#clipLake)">')
    p.append(f'<ellipse cx="2126" cy="1442" rx="860" ry="130" fill="#93a9cd" opacity="0.22" filter="url(#soft6)"/>')
    # mirror of the ridge stack about the waterline, vertically compressed so
    # the reflected summit lands inside the lake band (classic panorama cheat)
    refl_t = f'translate(0,{HORIZON}) scale(1,-0.3) translate(0,{-HORIZON})'
    p.append(f'<g transform="{refl_t}" opacity="0.8" filter="url(#soft2)">{ridges}'
             f'<path d="{poly_d(MAIN)}" fill="none" stroke="#8fa9cf" '
             f'stroke-width="3" opacity="0.5"/></g>')
    p.append(f'<g transform="{refl_t}" opacity="0.12" '
             f'filter="url(#soft1)"><use href="#sky4stars"/></g>')
    p.append(f'<rect width="{W}" height="{H}" fill="url(#reflfade)"/>')
    # ice sheen streaks
    rng = random.Random(403)
    for _ in range(30):
        y = rng.uniform(HORIZON + 8, H - 12)
        x0 = rng.uniform(-200, W - 300)
        ln = rng.uniform(300, 1500)
        p.append(f'<rect x="{fnum(x0)}" y="{fnum(y)}" width="{fnum(ln)}" '
                 f'height="{fnum(rng.uniform(1, 2.2))}" fill="#dfeaf8" '
                 f'opacity="{rng.uniform(0.03, 0.09):.2f}"/>')
    # hairline cracks
    cracks = [
        [(300, 1444), (420, 1352), (395, 1290), (505, 1224), (492, 1186)],
        [(505, 1224), (628, 1214), (700, 1236)],
        [(2160, 1444), (2266, 1372), (2258, 1300), (2380, 1252), (2372, 1206)],
        [(3020, 1444), (2930, 1380), (2952, 1330), (2872, 1282)],
    ]
    for c in cracks:
        p.append(f'<path d="{poly_d(c)}" fill="none" stroke="#cfe0f2" '
                 f'stroke-width="1.3" opacity="0.14"/>')
    # hexagonal freeze pattern + trapped bubbles, a few of them binary
    p.append(hex_region("hexi", "hexim", 2620, 1300, 620, 0.05))
    for _ in range(26):
        p.append(f'<circle cx="{fnum(rng.uniform(500, 1500))}" '
                 f'cy="{fnum(rng.uniform(1240, 1420))}" '
                 f'r="{fnum(rng.uniform(0.8, 2.6))}" fill="none" stroke="#cfe0f2" '
                 f'stroke-width="0.7" opacity="{rng.uniform(0.06, 0.13):.2f}"/>')
    p.append(binary_flecks(404, 14, (560, 1250, 1480, 1420), "#cfe0f2", 0.05, 0.1, 12))
    # "Snow" etched into the ice - engraved double-stroke, only seen up close
    etch = ('font-family="DejaVu Sans,sans-serif" font-size="104" '
            'font-weight="200" letter-spacing="26"')
    p.append(f'<g transform="translate(890,1330) skewX(-6)" filter="url(#soft1)">'
             f'<text x="1.8" y="1.8" {etch} fill="none" stroke="#060d1c" '
             f'stroke-width="1.6" opacity="0.20">Snow</text>'
             f'<text {etch} fill="none" stroke="#dfeaf8" stroke-width="1.4" '
             f'opacity="0.10">Snow</text></g>')
    p.append("</g>")  # end lake clip
    p.append(vignette("vig", 0.34))
    p.append("</svg>")
    return "".join(p)


# ------------------------------------------------------------------ output --

SCENES = [
    ("snow-hero-01-moonlit-summit", scene_moonlit),
    ("snow-hero-02-alpine-morning", scene_morning),
    ("snow-hero-03-blueprint", scene_blueprint),
    ("snow-hero-04-frozen-reflection", scene_reflection),
]


def render_png(svg_path, png_path):
    """Rasterize at intrinsic size via librsvg's pixbuf API (no pycairo/gi
    bridge needed, which matters on immutable hosts missing python3-gi-cairo)."""
    import gi
    gi.require_version("Rsvg", "2.0")
    from gi.repository import Rsvg
    handle = Rsvg.Handle.new_from_file(str(svg_path))
    pixbuf = handle.get_pixbuf()
    pixbuf.savev(str(png_path), "png", [], [])


def main():
    outdir = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).parent)
    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "render").mkdir(exist_ok=True)
    for name, fn in SCENES:
        svg = fn()
        svg_path = outdir / f"{name}.svg"
        svg_path.write_text(svg)
        print(f"wrote {svg_path} ({len(svg) / 1024:.0f} KiB)")
        try:
            png_path = outdir / "render" / f"{name}.png"
            render_png(svg_path, png_path)
            print(f"wrote {png_path}")
        except Exception as e:  # SVGs are still valid without renders
            print(f"  (png render skipped: {e})")


if __name__ == "__main__":
    main()
