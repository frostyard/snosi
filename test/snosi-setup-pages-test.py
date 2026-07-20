#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# GTK-level regression test for snosi-setup wizard pages
# (shared/native-installer/setup-gui/setup_gui/pages.py). The pure-logic
# core is covered no-GTK by test/snosi-setup-model-test.py; this test covers
# page behavior that only exists at the widget layer and therefore REQUIRES
# GTK4 + libadwaita + a usable display backend. When any of those are
# missing (e.g. CI runners), it skips cleanly with exit 0 so it can be wired
# anywhere without a GTK build dependency.
#
# Regression covered: the Features (sysext) page left the Next button
# permanently disabled -- the window disables Next on every page transition
# and each page's set_page_active() must re-enable it, but FeaturesPage's
# catalog-fetch override (df7bc6e) dropped the base class's set_ready(True).
# The page is entirely optional, so Next must be enabled immediately on
# entry, before and independent of the async catalog fetch.
#
# Usage: python3 test/snosi-setup-pages-test.py

import os
import sys
import time

try:
    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("Adw", "1")
    from gi.repository import Adw, GLib, Gtk
except (ImportError, ValueError) as e:
    print("skip - GTK4/libadwaita not available (%s)" % e)
    sys.exit(0)

if not Gtk.init_check():
    print("skip - no usable display backend for GTK")
    sys.exit(0)
Adw.init()

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
sys.path.insert(0, os.path.join(ROOT_DIR, "shared/native-installer/setup-gui"))
from setup_gui import model, pages  # noqa: E402

PASS = 0
FAIL = 0


def ok(desc, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print("ok - %s" % desc)
    else:
        FAIL += 1
        print("not ok - %s%s" % (desc, (" [%s]" % detail) if detail else ""))


# Minimal but structurally complete --print-defaults document (proto 1).
DEFAULTS_DOC = {
    "proto": 1,
    "products": [{
        "name": "snow-ab",
        "bare": "snow",
        "minimum_disk_bytes": 25769803776,
        "core_flatpaks_default": True,
        "core_flatpaks_allowed": True,
    }],
    "defaults": {"locale": "en_US.UTF-8", "timezone": "UTC",
                 "keyboard": "us::"},
    "origin_default": "https://repository.frostyard.org",
    "mok_cert_default": "/usr/lib/snosi/mok.crt",
    "regexes": {
        "username": "^[a-z_][a-z0-9_-]*$",
        "hostname": "^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$",
        "locale": "^[A-Za-z0-9_.@-]+$",
        "timezone": "^[A-Za-z0-9_+/-]+$",
        "keyboard": "^[A-Za-z0-9_,:()-]*$",
        "feature": "^[a-z0-9][a-z0-9._-]*$",
    },
}


class FakeWindow:
    """The slice of SetupWindow the Page protocol touches."""

    def __init__(self, installer):
        self.state = model.SetupState()
        self.defaults = model.Defaults(DEFAULTS_DOC)
        self.installer = installer
        self.can_continue = True

    def set_ready(self, ready=True):
        self.can_continue = ready


def enter_page(page, window):
    """What SetupWindow._show does around activation (app.py)."""
    window.set_ready(False)
    page.set_page_active()


def iterate_until(deadline_s, cond):
    ctx = GLib.MainContext.default()
    end = time.monotonic() + deadline_s
    while not cond() and time.monotonic() < end:
        ctx.iteration(False)
        time.sleep(0.01)
    return cond()


# -- Features page: Next must be enabled on entry, unconditionally ----------

# Case A: no product selected yet (no catalog fetch at all).
win = FakeWindow(installer="/bin/false")
page = pages.FeaturesPage(win)
enter_page(page, win)
ok("features page: Next enabled with no product", win.can_continue)

# Case B: product set; catalog fetch kicks off asynchronously and fails
# (installer is /bin/false). Next must be enabled immediately on entry...
win = FakeWindow(installer="/bin/false")
win.state.product = win.defaults.product("snow-ab")
page = pages.FeaturesPage(win)
enter_page(page, win)
ok("features page: Next enabled immediately while catalog fetch pending",
   win.can_continue)

# ...and still enabled after the fetch resolves into fallback mode.
resolved = iterate_until(10, lambda: page.fallback_banner.get_visible())
ok("features page: catalog failure resolved into manual fallback", resolved)
ok("features page: Next still enabled after fallback", win.can_continue)

# Case C: catalog loads successfully; Next stays enabled and finish()
# commits the checked switches.
catalog = (
    '{"proto": 1, "product": "snow-ab", "features": ['
    '{"name": "tailscale", "description": "VPN", "default": false},'
    '{"name": "docker", "description": "Containers", "default": false}]}'
)
stub = os.path.join(os.path.dirname(os.path.realpath(__file__)),
                    ".snosi-setup-pages-stub.sh")
with open(stub, "w") as f:
    f.write("#!/bin/sh\nprintf '%s'\n" % catalog.replace("'", "'\\''"))
os.chmod(stub, 0o755)
try:
    win = FakeWindow(installer=stub)
    win.state.product = win.defaults.product("snow-ab")
    page = pages.FeaturesPage(win)
    enter_page(page, win)
    ok("features page: Next enabled on entry (catalog mode)",
       win.can_continue)
    loaded = iterate_until(10, lambda: page._catalog_loaded_for == "snow-ab")
    ok("features page: catalog loaded", loaded)
    ok("features page: Next still enabled after catalog load",
       win.can_continue)
    if loaded:
        for name, row in page._switch_rows:
            if name == "tailscale":
                row.set_active(True)
        ok("features page: finish() commits selection", page.finish()
           and win.state.features == ["tailscale"])
finally:
    os.unlink(stub)

print("---")
print("%d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
