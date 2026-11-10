# Snow — Day/Night Wallpaper

Snow's default desktop wallpaper is a light/dark pair. GNOME shows the day
scene under the light style and the night scene under the dark style, which
is Snow's default ([ADR-0034](../../docs/adr/0034-snow-gtk-theme.md)).

| File (in `shared/snow/tree/usr/share/backgrounds/snow/`) | Scene |
| --- | --- |
| `snow-l.svg` | Day: brand cyan to ice sky, sun glow upper right, bright snow, wind shadows |
| `snow-d.svg` | Night: ink sky with the page glow, moon upper right, moonlit snow, snowfall |

- **Geometry:** the ridges are the hero series' `MAIN`, `MID`, `FAR` and
  `FIELD` polylines, imported from `../hero/generate_hero_backgrounds.py` and
  never redrawn. They sit 500 units lower on a 3:2 canvas (3440 x 2293,
  intrinsic 3840 x 2560). With GNOME's `zoom` option the horizon and summit
  stay inside the band that 16:10, 16:9 and 21:9 screens keep; Snowfield's
  3:2 Surface panels show the whole canvas.
- **Colour:** every paint is a frostyard/core design token (pinned copy:
  `test/fixtures/frostyard-design/colors.css`). Only opacity varies, so the
  wallpaper matches the Snow GTK theme. Easter eggs: a hexagon lattice in
  both scenes, a snowflake constellation at night, and a golden-ratio
  sparkle spiral by day.
- **Cost:** dots use `fill-opacity` and the lattice masks cover only their
  own box, so librsvg loads the pair in about 0.8 s and 0.4 s at full size.
  Recheck that time after adding blurred or masked elements.

## Regenerating

```bash
python3 artwork/wallpaper/generate_snow_wallpaper.py                    # write both SVGs
python3 artwork/wallpaper/generate_snow_wallpaper.py --check            # exit 1 if stale
python3 artwork/wallpaper/generate_snow_wallpaper.py --render /tmp/wp   # PNG previews (gi + GdkPixbuf)
```

Writing and checking need only the Python stdlib, and the output is
deterministic. Never edit the SVGs by hand: `test/snow-gtk-theme-test.py`
fails when they differ from the generator's output.
