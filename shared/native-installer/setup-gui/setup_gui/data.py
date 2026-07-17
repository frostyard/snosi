# SPDX-License-Identifier: LGPL-2.1-or-later
#
# data.py -- locale / keyboard / timezone choice tables for snosi-setup.
# NO GTK imports (see __init__.py).
#
# Ported PATTERNS (not code imported at runtime) from first-setup
# (/home/bjk/projects/frostyard/first-setup) snow_first_setup/core/
# {languages,keyboard,timezones}.py:
#   - locales: parse /usr/share/i18n/SUPPORTED for UTF-8 locales, resolve a
#     display name from the lang_name field of /usr/share/i18n/locales/<loc>
#     (languages.py did the same, eagerly; we do it lazily with a cache).
#   - keyboards: first-setup used GnomeDesktop.XkbInfo; the ISO should not
#     need GnomeDesktop, so the same layout/variant inventory is read from
#     /usr/share/X11/xkb/rules/evdev.lst (the file XkbInfo itself is fed
#     from). Specs are LAYOUT or LAYOUT:VARIANT, matching snosi-install's
#     KEYBOARD_RE triplet grammar.
#   - timezones: first-setup used pytz + GWeather geolocation; the ISO
#     needs neither -- Python's stdlib zoneinfo enumerates the system tzdata
#     (fallback: /usr/share/zoneinfo/zone.tab), and there is no network
#     geolocation lookup on an installer.
#   - search_*: the same multi-term case-insensitive substring match with a
#     result limit + "list shortened" flag as first-setup's search helpers.
#
# Every loader has a small embedded fallback so the wizard never renders an
# empty picker even on a host missing the data files.

import os

SUPPORTED_PATH = "/usr/share/i18n/SUPPORTED"
LOCALES_DIR = "/usr/share/i18n/locales"
EVDEV_LST_PATH = "/usr/share/X11/xkb/rules/evdev.lst"
ZONE_TAB_PATH = "/usr/share/zoneinfo/zone.tab"

FALLBACK_LOCALES = [
    "en_US.UTF-8", "en_GB.UTF-8", "de_DE.UTF-8", "fr_FR.UTF-8",
    "es_ES.UTF-8", "it_IT.UTF-8", "pt_BR.UTF-8", "nl_NL.UTF-8",
    "pl_PL.UTF-8", "ru_RU.UTF-8", "ja_JP.UTF-8", "ko_KR.UTF-8",
    "zh_CN.UTF-8", "zh_TW.UTF-8", "sv_SE.UTF-8", "nb_NO.UTF-8",
    "da_DK.UTF-8", "fi_FI.UTF-8", "cs_CZ.UTF-8", "tr_TR.UTF-8",
]

# (spec, display name); specs match snosi-install's KEYBOARD_RE.
FALLBACK_KEYBOARDS = [
    ("us", "English (US)"), ("gb", "English (UK)"), ("de", "German"),
    ("fr", "French"), ("es", "Spanish"), ("it", "Italian"),
    ("br", "Portuguese (Brazil)"), ("pt", "Portuguese (Portugal)"),
    ("nl", "Dutch"), ("pl", "Polish"), ("ru", "Russian"),
    ("jp", "Japanese"), ("kr", "Korean"), ("se", "Swedish"),
    ("no", "Norwegian"), ("dk", "Danish"), ("fi", "Finnish"),
    ("cz", "Czech"), ("tr", "Turkish"), ("ch", "German (Switzerland)"),
]

FALLBACK_TIMEZONES = [
    "UTC", "America/New_York", "America/Chicago", "America/Denver",
    "America/Los_Angeles", "America/Sao_Paulo", "Europe/London",
    "Europe/Berlin", "Europe/Paris", "Europe/Madrid", "Europe/Rome",
    "Europe/Amsterdam", "Europe/Warsaw", "Europe/Moscow", "Asia/Tokyo",
    "Asia/Seoul", "Asia/Shanghai", "Asia/Kolkata", "Australia/Sydney",
    "Pacific/Auckland",
]

_locale_display_cache = {}


def load_locales():
    """UTF-8 locale codes from /usr/share/i18n/SUPPORTED (first-setup
    languages.py pattern), or the fallback list."""
    locales = []
    try:
        with open(SUPPORTED_PATH, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                parts = line.split()
                if len(parts) < 2 or "UTF-8" not in parts[1]:
                    continue
                loc = parts[0]
                if loc not in locales:
                    locales.append(loc)
    except OSError:
        pass
    return locales or list(FALLBACK_LOCALES)


def locale_display_name(loc):
    """\"<lang_name> -- <code>\" when the locale definition file carries a
    lang_name (same extraction first-setup languages.py performs), else the
    bare code. Lazy + cached: only the rows actually rendered pay the file
    read."""
    if loc in _locale_display_cache:
        return _locale_display_cache[loc]
    name = ""
    filename = os.path.join(LOCALES_DIR, loc.split(".")[0])
    try:
        with open(filename, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("lang_name"):
                    parts = line.split(None, 1)
                    if len(parts) == 2:
                        name = parts[1].strip().strip('"')
                    break
    except OSError:
        pass
    display = "%s — %s" % (name, loc) if name else loc
    _locale_display_cache[loc] = display
    return display


def load_keyboards():
    """[(spec, display)] from evdev.lst's `! layout` and `! variant`
    sections; specs are LAYOUT or LAYOUT:VARIANT. Falls back to the
    embedded table."""
    layouts = []       # (code, name)
    variants = []      # (layout:variant, name)
    section = None
    try:
        with open(EVDEV_LST_PATH, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("!"):
                    section = line[1:].strip()
                    continue
                line = line.rstrip("\n")
                if not line.strip():
                    continue
                if section == "layout":
                    parts = line.split(None, 1)
                    if len(parts) == 2:
                        layouts.append((parts[0], parts[1].strip()))
                elif section == "variant":
                    parts = line.split(None, 1)
                    if len(parts) != 2:
                        continue
                    variant = parts[0]
                    rest = parts[1].strip()
                    # "<layout>: <display name>"
                    if ":" not in rest:
                        continue
                    layout, disp = rest.split(":", 1)
                    variants.append(("%s:%s" % (layout.strip(), variant),
                                     disp.strip()))
    except OSError:
        pass
    if not layouts:
        return list(FALLBACK_KEYBOARDS)
    return layouts + variants


def load_timezones():
    """Sorted IANA timezone names, UTC first. stdlib zoneinfo enumerates the
    system tzdata; zone.tab is the fallback for stripped systems, the
    embedded list the last resort."""
    names = set()
    try:
        import zoneinfo
        names = {n for n in zoneinfo.available_timezones()
                 if "/" in n or n == "UTC"}
    except Exception:
        pass
    if not names:
        try:
            with open(ZONE_TAB_PATH, "r", encoding="utf-8",
                      errors="replace") as f:
                for line in f:
                    if line.startswith("#"):
                        continue
                    parts = line.split("\t")
                    if len(parts) >= 3:
                        names.add(parts[2].strip())
        except OSError:
            pass
    if not names:
        return list(FALLBACK_TIMEZONES)
    ordered = sorted(names)
    if "UTC" in names:
        ordered.remove("UTC")
        ordered.insert(0, "UTC")
    return ordered


def search_choices(choices, term, limit=50):
    """first-setup's search pattern: every whitespace-separated term must
    substring-match (case-insensitive) the display text or the code.
    Returns (matches, shortened). Empty term returns the head of the list."""
    term_parts = term.lower().split()
    matches = []
    shortened = False
    for code, display in choices:
        if len(matches) >= limit:
            shortened = True
            break
        hay = ("%s %s" % (code, display)).lower()
        if all(p in hay for p in term_parts):
            matches.append((code, display))
    return matches, shortened
