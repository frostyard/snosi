# Snow — Hero Backgrounds

Four cohesive ultrawide (3440×1440) hero/wallpaper backgrounds for the Snow
brand. All four share **byte-identical mountain silhouette geometry** — the
ridges are generated once (seeded midpoint displacement over hand-placed
control points in `generate_hero_backgrounds.py`) and reused verbatim in
every scene, so the horizon, peak arrangement, and perspective never drift.

| File | Scene |
| --- | --- |
| `snow-hero-01-moonlit-summit.svg` | Deep-navy night, realistic starfield, moonlit snow, drifting snowfall |
| `snow-hero-02-alpine-morning.svg` | Crisp daylight, glacier blues, clean minimalist atmosphere |
| `snow-hero-03-blueprint.svg` | Slate blueprint, white technical line art, topo contours, annotations, circuit traces |
| `snow-hero-04-frozen-reflection.svg` | Blue-hour twilight, silhouette mirrored in a glassy frozen lake |

`render/` holds 3440×1440 PNG rasterizations of each.

## Composition constants

- Canvas 3440×1440 (~21:9), horizon/waterline at y=1150.
- Main summit apex at **x=2126 = 3440 × 0.618** (golden-ratio placement —
  annotated as `P1 · x/W = 0.618` on the blueprint).
- Two hazed background ranges for depth; the left third stays low and the
  upper-left quadrant is deliberately empty negative space for branding.
- Light source is upper-right in every scene (moon / morning sun / Venus and
  twilight glow) for cross-set cohesion.

## Easter eggs (all intentionally understated)

- Six-fold **snowflake constellation** + a small dipper-like asterism in the
  night sky (01).
- **Hexagon lattices** faded into the sky near the moon (01), pressed into the
  snowfield (02), gridded into the blueprint sky with an `R = 52.0` note (03),
  and frozen into the ice (04).
- **Binary digits**: tiny 0/1 glyphs disguised as stars (01), shaded into the
  snow (02), and trapped as ice bubbles (04). The blueprint's ground contour
  carries `01010011 01101110 01101111 01110111` — "Snow" in ASCII — and the
  summit dimension reads `ELEV 3440 · 0b110101110000` (= 3440). The title
  block's `REV 0x0D70` is also 3440.
- The word **"Snow" etched into the lake ice** (04), engraved double-stroke at
  ~10% opacity — only noticeable up close.
- Blueprint extras: slope angle `θ = 30.2°` (the summit's true west-face
  angle), `∂z/∂x = 0.62`, datum line, peak crosshairs, title block.

## Regenerating

```bash
python3 generate_hero_backgrounds.py            # writes SVGs + render/*.png
```

SVG generation needs only the Python stdlib. PNG rasterization uses
GObject-introspected librsvg (`gi` + `Rsvg`, present on Debian/GNOME systems;
no `rsvg-convert` or pycairo↔gi bridge required). Output is deterministic —
all randomness is seeded.

Text uses DejaVu Sans / DejaVu Sans Mono (annotations and etching). For
pixel-identical rasters, render on a host with the DejaVu fonts installed
(standard on Debian).
