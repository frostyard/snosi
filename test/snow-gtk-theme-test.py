#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Static guard for the Snow GTK theme (docs/adr/0034-snow-gtk-theme.md).

Snow and Snowfield ship the Snow theme from shared/snow/tree:
  usr/share/themes/Snow/{index.theme,gtk-3.0,gtk-4.0,libadwaita}
  etc/skel/.config/gtk-4.0/gtk.css   (a new account's import of the
                                      libadwaita layer)
and select it in zz0-01-snowlinux-desktop.gschema.override.

This test checks that:
  1. test/fixtures/frostyard-design/colors.css is the byte copy of
     frostyard/core's design tokens at the pinned commit;
  2. every colour the theme writes is one of those tokens (an alpha may
     change, the colour may not);
  3. the libadwaita layer, which GTK loads at user priority where a rule
     beats every theme and app rule regardless of specificity, holds only
     :root variables, @define-color lines and the two allowlisted rules for
     libadwaita's fixed greys, and each named colour equals its variable;
  4. the skel file only imports the shipped libadwaita layer, so the colours
     update with the image;
  5. the gschema override names the shipped theme and a font the image
     installs;
  6. GTK 3 flat buttons stay transparent in backdrop and disabled states.
Checks 2 and 3 also run on bad fixtures, and check 6's resolver runs on a
fixture with the old backdrop rule, so the guard is shown to fail.

No root, no network, no GTK, no image build.
"""

import hashlib
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
TREE = REPO / "shared/snow/tree"
THEME = TREE / "usr/share/themes/Snow"
LIBADWAITA = THEME / "libadwaita/gtk.css"
SKEL = TREE / "etc/skel/.config/gtk-4.0/gtk.css"
OVERRIDE = TREE / "usr/share/glib-2.0/schemas/zz0-01-snowlinux-desktop.gschema.override"
PACKAGES = REPO / "shared/packages/snow/mkosi.conf"
TOKENS = REPO / "test/fixtures/frostyard-design/colors.css"

# Byte copy of frostyard/core .agents/skills/frostyard-design/tokens/colors.css
# at its last change, core commit 67fc054 (unchanged at core main 8dc26fa,
# 2026-11-09). A change to the copy must change this pin.
CORE_COMMIT = "67fc05436bb7b58be1781ed1a55bef765607da7f"
TOKENS_SHA256 = "7c3026520376af0091b7d05f5213499e458cd6befcce118d39235e3de520e624"

SKEL_IMPORT = '@import url("file:///usr/share/themes/Snow/libadwaita/gtk.css");'
GTK3_BASE = 'resource:///org/gtk/libgtk/theme/Adwaita/gtk-contained-dark.css'
GTK4_BASE = 'resource:///org/gtk/libgtk/theme/Default/Default-dark.css'
# libadwaita 1.7 paints these two with a fixed grey instead of a variable;
# each allowlisted rule may set only the one property named here.
ALLOWED_RULES = {"banner": "--banner-color", "toast": "background"}
# The interface font family -> the package that ships it.
FONT_PACKAGES = {"Inter Variable": "fonts-inter-variable"}

PASS = 0
FAIL = 0


def check(description, ok, detail=""):
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"ok - {description}")
    else:
        FAIL += 1
        print(f"not ok - {description}{': ' + detail if detail else ''}", file=sys.stderr)


def strip_comments(css):
    return re.sub(r"/\*.*?\*/", "", css, flags=re.S)


def hex_rgb(value):
    value = value.lstrip("#")
    if len(value) in (3, 4):
        value = "".join(c * 2 for c in value[:3])
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


HEX = re.compile(r"#([0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3,4})\b")
RGB = re.compile(r"\brgba?\(\s*(\d+)[\s,]+(\d+)[\s,]+(\d+)", re.I)


def colours(css):
    """Every (r, g, b) a stylesheet writes, with the text that wrote it."""
    css = strip_comments(css)
    found = [(hex_rgb(m.group(1)), m.group(0)) for m in HEX.finditer(css)]
    found += [((int(m.group(1)), int(m.group(2)), int(m.group(3))), m.group(0))
              for m in RGB.finditer(css)]
    return found


def token_palette(css):
    return {rgb for rgb, _ in colours(css)}


def off_palette(css, palette):
    return sorted({text for rgb, text in colours(css) if rgb not in palette})


def layer_problems(css):
    """Rule-shape problems in a libadwaita layer (check 3)."""
    problems = []
    body = strip_comments(css)
    defines = {}
    for match in re.finditer(r"@define-color\s+([a-z_]+)\s+([^;]+);", body):
        defines[match.group(1)] = " ".join(match.group(2).split())
    body = re.sub(r"@define-color\s+[a-z_]+\s+[^;]+;", "", body)
    if "@import" in body:
        problems.append("imports another stylesheet")
    variables = {}
    for match in re.finditer(r"([^{}]+)\{([^{}]*)\}", body):
        selector = " ".join(match.group(1).split())
        declarations = [d.strip() for d in match.group(2).split(";") if d.strip()]
        names = [d.split(":", 1)[0].strip() for d in declarations]
        if selector == ":root":
            for declaration in declarations:
                name, _, value = declaration.partition(":")
                name = name.strip()
                if not name.startswith("--"):
                    problems.append(f":root sets {name}, not a variable")
                variables[name] = " ".join(value.split())
        elif selector in ALLOWED_RULES:
            if names != [ALLOWED_RULES[selector]]:
                problems.append(f"{selector} sets {names}, only {ALLOWED_RULES[selector]} is allowed")
        else:
            problems.append(f"selector {selector!r} is not :root or an allowlisted rule")
    leftover = re.sub(r"([^{}]+)\{([^{}]*)\}", "", body).strip()
    if leftover:
        problems.append(f"unparsed text {leftover[:40]!r}")
    for name, value in defines.items():
        variable = "--" + name.replace("_", "-")
        if variable not in variables:
            problems.append(f"@define-color {name} has no {variable} variable")
        elif variables[variable] != value:
            problems.append(f"@define-color {name} {value} differs from {variable} {variables[variable]}")
    return problems


def split_selectors(text):
    """Split on commas outside parentheses."""
    start = depth = 0
    for i, char in enumerate(text):
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        elif char == "," and depth == 0:
            yield text[start:i].strip()
            start = i + 1
    yield text[start:].strip()


def compound(selector):
    """Parse only element/class/pseudo compounds and simple :not arguments."""
    if re.search(r"\s|[>+~]", selector):
        return None
    element = re.match(r"[a-zA-Z_][\w-]*|\*", selector)
    name = element.group() if element else None
    rest = selector[element.end():] if element else selector
    classes, pseudos, negations = set(), set(), []
    count = 0
    while rest:
        token = re.match(r":not\(([.:])([\w-]+)\)|([.:])([\w-]+)", rest)
        if not token:
            return None
        if token.group(1):
            negations.append((token.group(1), token.group(2)))
        else:
            target = classes if token.group(3) == "." else pseudos
            target.add(token.group(4))
        count += 1
        rest = rest[token.end():]
    return name, classes, pseudos, negations, (0, count, int(name not in (None, "*")))


def resolve(css, element, classes, pseudos, prop):
    """Resolve one property in Snow's local GTK 3 compound-selector rules.

    Imports are not expanded; combinators and unsupported syntax are ignored.
    """
    body = re.sub(r"@(import|define-color)\b[^;]*;", "", strip_comments(css))
    winner, value = None, None
    for order, rule in enumerate(re.finditer(r"([^{}]+)\{([^{}]*)\}", body)):
        declarations = {}
        for declaration in rule.group(2).split(";"):
            key, sep, val = declaration.partition(":")
            if sep:
                declarations[key.strip()] = val.strip()
        if prop not in declarations:
            continue
        for selector in split_selectors(rule.group(1)):
            parsed = compound(selector)
            if parsed is None:
                continue
            name, required_classes, required_pseudos, negations, specificity = parsed
            if name not in (None, "*", element):
                continue
            if not required_classes <= classes or not required_pseudos <= pseudos:
                continue
            if any(arg in (classes if kind == "." else pseudos)
                   for kind, arg in negations):
                continue
            rank = (specificity, order)
            if winner is None or rank >= winner:
                winner, value = rank, declarations[prop]
    return value


def check_flat_buttons(css):
    """Check 6, also callable against the old CSS for a regression test."""
    states = [({"flat"}, set())]
    for classes, pseudos_list in [
        ({"flat"}, [{"backdrop"}, {"backdrop", "disabled"}, {"disabled"}]),
        ({"titlebutton"}, [{"backdrop"}, {"backdrop", "disabled"}, {"disabled"}]),
        ({"sidebar-button"}, [{"backdrop"}, {"backdrop", "disabled"}, {"disabled"}]),
        ({"suggested-action", "flat"}, [{"backdrop"}, {"backdrop", "disabled"}, {"disabled"}]),
        ({"destructive-action", "flat"}, [{"backdrop"}, {"backdrop", "disabled"}, {"disabled"}]),
    ]:
        states.extend((classes, pseudos) for pseudos in pseudos_list)
    for classes, pseudos in states:
        label = ".".join(["button"] + sorted(classes))
        label += "".join(":" + p for p in sorted(pseudos))
        check(f"GTK 3 {label} has no background image",
              resolve(css, "button", classes, pseudos, "background-image") == "none")
        if pseudos:
            check(f"GTK 3 {label} has a transparent border",
                  resolve(css, "button", classes, pseudos, "border-color") == "transparent")
    check(f"GTK 3 flat-button transparency covers {len(states)} widget states", len(states) == 16)
    plain = resolve(css, "button", set(), {"backdrop"}, "background-image")
    check("a plain GTK 3 backdrop button retains its fill", plain not in (None, "none"))
    buggy = ("button:backdrop, button:backdrop.flat { background-image: image(@snow_panel_bright); }"
             "button.flat { background-image: none; }")
    check("the resolver detects the old flat backdrop fill",
          resolve(buggy, "button", {"flat"}, {"backdrop"}, "background-image")
          == "image(@snow_panel_bright)")
    fixture = ("button.flat { color: first; } button { color: later; }"
               "button.flat { border-color: first; } .flat { border-color: less-specific; }"
               "button.flat { border-color: last; }")
    check("cascade specificity beats source order",
          resolve(fixture, "button", {"flat"}, set(), "color") == "first")
    check("cascade source order breaks a specificity tie",
          resolve(fixture, "button", {"flat"}, set(), "border-color") == "last")


def main():
    # 1. the pinned token copy
    digest = hashlib.sha256(TOKENS.read_bytes()).hexdigest()
    check(f"colors.css is the byte copy of core {CORE_COMMIT[:7]}", digest == TOKENS_SHA256,
          f"sha256 {digest}")
    palette = token_palette(TOKENS.read_text())
    check("the pinned tokens yield a palette", len(palette) >= 20, f"{len(palette)} colours")

    # Theme layout
    expected = ["index.theme", "gtk-3.0/gtk.css", "gtk-3.0/gtk-dark.css", "gtk-4.0/gtk.css",
                "libadwaita/gtk.css"]
    for rel in expected:
        check(f"Snow ships {rel}", (THEME / rel).is_file())
    index = (THEME / "index.theme").read_text()
    check("index.theme names GtkTheme=Snow", re.search(r"^GtkTheme=Snow$", index, re.M) is not None)
    gtk3 = (THEME / "gtk-3.0/gtk.css").read_text()
    check("the GTK 3 theme builds on Adwaita dark",
          strip_comments(gtk3).lstrip().startswith(f'@import url("{GTK3_BASE}");'))
    gtk4 = (THEME / "gtk-4.0/gtk.css").read_text()
    check("the GTK 4 theme imports GTK's dark built-in theme",
          strip_comments(gtk4).strip() == f'@import url("{GTK4_BASE}");')

    # 2. every theme colour is a token
    sheets = sorted(THEME.rglob("*.css")) + [SKEL]
    for sheet in sheets:
        rel = sheet.relative_to(REPO)
        bad = off_palette(sheet.read_text(), palette)
        check(f"{rel} uses only design-token colours", not bad, ", ".join(bad))
    check("an off-token colour fails the palette check",
          off_palette("a { color: #3584e4; background: rgb(0 0 6 / 36%); }", palette)
          == ["#3584e4", "rgb(0 0 6"])
    check("token colours with any alpha pass the palette check",
          not off_palette("a { color: #47b8ef; border-color: rgba(162, 222, 255, .18); }", palette))

    # 3. the libadwaita layer only recolours
    problems = layer_problems(LIBADWAITA.read_text())
    check("the libadwaita layer holds only variables, named colours and allowlisted rules",
          not problems, "; ".join(problems))
    fixtures = {
        "a widget selector": ":root { --x: #47b8ef; } button { border-radius: 4px; }",
        "a non-variable :root property": ":root { color: #47b8ef; }",
        "an allowlisted rule with another property": "toast { background: #17445e; border: none; }",
        "a named colour that differs from its variable":
            ":root { --accent-bg-color: #47b8ef; } @define-color accent_bg_color #168bd0;",
        "a named colour without a variable": "@define-color accent_bg_color #47b8ef;",
        "an import": '@import url("other.css"); :root { --x: #47b8ef; }',
    }
    for name, css in fixtures.items():
        check(f"the layer check rejects {name}", bool(layer_problems(css)))
    check("the layer check accepts a minimal valid layer",
          not layer_problems(":root { --accent-bg-color: #47b8ef; }\n"
                             "@define-color accent_bg_color #47b8ef;\n"
                             "banner { --banner-color: #b6d0df; }"))

    # 4. the skel file only imports the shipped layer
    skel = strip_comments(SKEL.read_text()).strip()
    check("the skel gtk.css only imports the libadwaita layer", skel == SKEL_IMPORT, skel[:80])
    imported = re.search(r'file://(/[^"]+)', SKEL_IMPORT).group(1)
    check(f"the imported {imported} ships in the snow tree", (TREE / imported.lstrip("/")).is_file())

    # 5. the defaults name the shipped theme and an installed font
    override = OVERRIDE.read_text()
    section = re.search(r"^\[org\.gnome\.desktop\.interface\]\n(.*?)(?=^\[|\Z)", override, re.M | re.S)
    keys = dict(re.findall(r"^([a-z-]+)=(.*)$", section.group(1) if section else "", re.M))
    check("gtk-theme is 'Snow'", keys.get("gtk-theme") == "'Snow'", keys.get("gtk-theme", "unset"))
    check("color-scheme is 'prefer-dark'", keys.get("color-scheme") == "'prefer-dark'",
          keys.get("color-scheme", "unset"))
    packages = "\n".join(line for line in PACKAGES.read_text().splitlines()
                         if not line.lstrip().startswith("#"))
    for key in ("font-name", "document-font-name"):
        value = keys.get(key, "")
        family = re.sub(r"^'(.*?)\s+\d+(\.\d+)?'$", r"\1", value)
        package = FONT_PACKAGES.get(family)
        check(f"{key} {value} has a known font package", package is not None)
        if package:
            check(f"shared/packages/snow installs {package} for {key}",
                  re.search(rf"(^Packages=|^\s+){re.escape(package)}\s*$", packages, re.M)
                  is not None)

    # 6. local GTK 3 rules preserve undecorated backdrop/disabled buttons
    check_flat_buttons(gtk3)

    print(f"# {PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
