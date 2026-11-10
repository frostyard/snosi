# 0034 — Theme Snow's GTK applications from the Frostyard design system

- **Status:** Proposed
- **Date:** 2026-11-09

## Context

frostyard/core holds the Frostyard design system
(`.agents/skills/frostyard-design/`). Its colour tokens
(`tokens/colors.css`) describe a dark-only language: near-black blue inks,
cold ice, sky and blue accents, mist-blue text and hairline borders, with
cold-shifted state colours for admin surfaces. Inter is its typeface. Snow
and Snowfield ship stock GNOME 48 colours with Cantarell.

- Nearly every application on Snow uses libadwaita 1.7 (Files, Settings,
  Text Editor, Ptyxis, ChairLift, Bazaar). libadwaita ignores the GTK theme
  setting: it forces GTK's empty theme and loads its own stylesheet. Its
  supported knobs are the colour scheme and one of nine fixed accent
  colours. Its stylesheet reads about 50 colour variables, such as
  `--window-bg-color` and `--accent-bg-color`, backed by GTK named colours
  of the same names.
- GTK 4 loads `~/.config/gtk-4.0/gtk.css` into every GTK 4 application,
  libadwaita ones included, at user priority. A rule there beats every theme
  and application rule regardless of selector specificity. A widget rule
  there, such as `button { border-radius: 4px; }`, therefore also overrides
  libadwaita's own exceptions (`.circular`, `.pill`, the flattened inner
  corners of `.linked` groups) and each application's stylesheet.
- libadwaita 1.7 paints two surfaces with a fixed grey rather than a
  variable: `banner` sets `--banner-color: #7d7d83` and `toast` sets
  `background: #505053`.
- GTK 4.18 has no `prefers-color-scheme` media query, so a user stylesheet
  cannot give light and dark values.
- GTK 3 applications (for example `remote-viewer`) and GTK 4 applications
  without libadwaita still use the GTK theme named by `gtk-theme`.
- Flatpak applications do not see the host's `/usr/share/themes` or
  `~/.config/gtk-4.0`; they follow the colour scheme and accent through the
  settings portal.
- Firn creates the installed system's only user with
  `useradd --create-home`, which copies the image's `/etc/skel`.
- Debian Trixie packages Inter as `fonts-inter-variable` (family
  `Inter Variable`), not `adw-gtk3` or Adwaita Sans.

## Decision

Snow and Snowfield ship a theme named Snow from `shared/snow/tree`, built
only from core's colour tokens.

- **libadwaita layer:** `/usr/share/themes/Snow/libadwaita/gtk.css` sets
  libadwaita's colour variables in `:root` and the matching
  `@define-color` named colours, plus `--window-radius: 8px`. Content sits
  on ink, chrome on deep and panel blues, the accent is sky with
  near-black text, and links are the token link colour. It contains no
  widget selectors except two rules that each set one property:
  `banner { --banner-color }` and `toast { background }`.
- **Delivery:** `/etc/skel/.config/gtk-4.0/gtk.css` holds a single
  `@import` of that file. A new account therefore follows the image's
  copy, and an image update changes its colours. Deleting the line opts out.
  Existing accounts are not changed; a user adopts the theme by copying the
  skel file.
- **GTK 3 theme:** `/usr/share/themes/Snow/gtk-3.0/gtk.css` imports GTK's
  built-in Adwaita dark stylesheet and repeats Adwaita's selectors for the
  surfaces, controls and states it recolours. `gtk-dark.css` imports the
  same file.
- **GTK 4 theme:** `/usr/share/themes/Snow/gtk-4.0/gtk.css` imports GTK's
  built-in dark theme, so a GTK 4 application without libadwaita is dark
  too.
- **Defaults:** `zz0-01-snowlinux-desktop.gschema.override` sets
  `color-scheme='prefer-dark'`, `gtk-theme='Snow'`, `accent-color='blue'`
  (the fixed accent nearest sky, which GNOME Shell and Flatpak apps use),
  and `font-name` and `document-font-name` to `'Inter Variable 11'`.
  `shared/packages/snow/mkosi.conf` installs `fonts-inter-variable`.
- **Guard:** `test/fixtures/frostyard-design/colors.css` is a sha256-pinned
  byte copy of core's tokens. `test/snow-gtk-theme-test.py`, run in
  `validate.yml`, requires every colour the theme writes to be one of those
  tokens. It also requires the libadwaita layer to keep the shape above,
  each named colour to equal its variable, the skel file to be the single
  import, and the gschema font to have its package.

## Consequences

- libadwaita applications started from a new account's session take
  Frostyard colours, and each image update can change them without touching
  home directories.
- The theme is dark only. While the import is in place, Settings'
  light style changes GNOME Shell but not the applications' colours. When
  Snow reaches GTK 4.20, light values can sit behind a
  `prefers-color-scheme` query.
- The user's accent choice in Settings no longer reaches libadwaita
  applications that load the layer; the layer pins the sky accent.
- libadwaita controls keep their own radii (9px buttons, 12px cards); only
  the window corner follows the nearly-square design.
- Flatpak applications are not recoloured. They follow the dark scheme and
  the blue accent. The Shell is not themed.
- Each libadwaita release can add a variable or a fixed grey. Snosi must
  recheck the layer when libadwaita changes, by diffing its
  `defaults-dark.css` and the fixed colours in `base.css`.
- A user whose skel import names a missing file gets a GTK import warning
  in every GTK 4 application. Removing or renaming
  `/usr/share/themes/Snow/libadwaita/gtk.css` therefore needs a migration.
- When core's tokens change, the copy and its pin move together, and the
  theme follows only through a reviewed change.

## Alternatives considered

- **Supported knobs only (dark scheme, a fixed accent):** robust, but
  libadwaita applications would keep Adwaita's neutral greys, and no fixed
  accent equals sky.
- **Widget rules in the user stylesheet (square buttons, hairline cards):**
  at user priority they break libadwaita's own exceptions and applications'
  styles.
- **A full stylesheet copied into each home:** home copies never receive
  updates. The import keeps the stylesheet in `/usr`.
- **`GTK_THEME` in the session environment:** it overrides the GTK theme for
  every application and is a GTK debugging aid, not a theming interface.
- **A generated GTK 3 theme (rewriting Adwaita's compiled stylesheet):**
  full coverage, but a large generated file tied to one GTK release. The
  hand-written layer is reviewable, and Snow ships few GTK 3 applications.
- **A GNOME Shell theme:** it needs the user-themes extension. It is left for
  a later decision.

## References

- Shapes: [design/overview.md](../design/overview.md#snow-gtk-theme),
  [design/testing.md](../design/testing.md)
- Builds on: frostyard/core
  [`frostyard-design` tokens](https://github.com/frostyard/core/blob/67fc05436bb7b58be1781ed1a55bef765607da7f/.agents/skills/frostyard-design/tokens/colors.css)
