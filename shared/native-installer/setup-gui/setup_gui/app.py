# SPDX-License-Identifier: LGPL-2.1-or-later
#
# app.py -- Adw.Application + wizard window for snosi-setup. The window is
# the first-setup window.py pattern (page stack + Back/Next in a header
# bar, window.set_ready gating Next), built in code, no gresource.
#
# The app performs ZERO privileged operations itself beyond spawning
# `snosi-install` (progress page) and `systemctl reboot` (done page); it
# runs as root on the installer ISO because everything there is root, but
# the boundary stays clean.

import argparse
import json
import subprocess
import sys

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk  # noqa: E402

from . import model, pages  # noqa: E402

APP_ID = "org.frostyard.SnosiSetup"

# Fixture used ONLY by --self-check when no snosi-install is runnable (e.g.
# a dev host); a real run always loads live `snosi-install --print-defaults`
# output so the frontend can never drift from the backend.
_SELF_CHECK_DEFAULTS = {
    "proto": 1,
    "products": [
        {"name": "cayo-ab", "bare": "cayo", "minimum_disk_bytes": 16642998272,
         "core_flatpaks_default": False, "core_flatpaks_allowed": False},
        {"name": "snow-ab", "bare": "snow", "minimum_disk_bytes": 23085449216,
         "core_flatpaks_default": True, "core_flatpaks_allowed": True},
    ],
    "defaults": {"locale": "en_US.UTF-8", "timezone": "UTC", "keyboard": "us"},
    "origin_default": "https://repository.frostyard.org",
    "mok_cert_default": "/usr/lib/snosi/mok.crt",
    "regexes": {
        "username": "^[a-z][a-z0-9_-]{0,31}$",
        "hostname": "^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$",
        "locale": "^[A-Za-z][A-Za-z0-9_.@-]*$",
        "timezone": "^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+){0,2}$",
        "keyboard": "^[a-z0-9,]+(:[A-Za-z0-9,_-]*(:[A-Za-z0-9_-]+)?)?$",
        "feature": "^[A-Za-z0-9._-]+$",
    },
}


def load_defaults(installer):
    """Run `snosi-install --print-defaults` and parse it. Raises on any
    failure -- a frontend without the backend document must not guess."""
    proc = subprocess.run([installer, "--print-defaults"],
                          capture_output=True, text=True, timeout=60)
    if proc.returncode != 0:
        raise RuntimeError("%s --print-defaults failed (%d): %s" %
                           (installer, proc.returncode, proc.stderr.strip()))
    return model.Defaults.from_json(proc.stdout)


class SetupWindow(Adw.ApplicationWindow):
    """Page stack + Back/Next chrome. Navigation follows
    model.page_sequence(state.product) BY NAME (the sequence changes when a
    product without core-flatpaks support is chosen), so pages are looked up
    per hop, never by a frozen index."""

    def __init__(self, application, defaults, installer, fullscreen=True):
        super().__init__(application=application, title="Snosi Setup",
                         default_width=1024, default_height=700)
        self.defaults = defaults
        self.installer = installer
        self.state = model.SetupState()
        self.can_continue = False

        self.back_btn = Gtk.Button(icon_name="go-previous-symbolic",
                                   tooltip_text="Back")
        self.back_btn.connect("clicked", lambda *_: self.go_back())
        self.next_btn = Gtk.Button(label="Next")
        self.next_btn.add_css_class("suggested-action")
        self.next_btn.connect("clicked", lambda *_: self.finish_step())

        header = Adw.HeaderBar()
        header.pack_start(self.back_btn)
        header.pack_end(self.next_btn)

        self.stack = Gtk.Stack(
            transition_type=Gtk.StackTransitionType.SLIDE_LEFT_RIGHT,
            hexpand=True, vexpand=True)
        self.pages = {}
        for name in model.page_sequence(None):
            page = pages.PAGE_CLASSES[name](self)
            self.pages[name] = page
            self.stack.add_named(page, name)

        view = Adw.ToolbarView()
        view.add_top_bar(header)
        view.set_content(self.stack)
        self.set_content(view)

        self.current_name = model.PAGE_WELCOME
        self._show(self.current_name, activate=True)
        if fullscreen:
            self.fullscreen()

    # -- page protocol (first-setup window.py shape) -----------------------

    def page_by_name(self, name):
        return self.pages.get(name)

    def set_ready(self, ready=True):
        self.can_continue = ready
        self.next_btn.set_sensitive(ready)

    def _sequence(self):
        return model.page_sequence(self.state.product)

    def finish_step(self):
        if not self.can_continue:
            return
        self.advance()

    def advance(self):
        """Commit the current page and move forward (also driven
        programmatically: network skip, progress-page done event)."""
        page = self.pages[self.current_name]
        if not page.finish():
            self.set_ready(False)
            return
        seq = self._sequence()
        idx = seq.index(self.current_name)
        if idx + 1 < len(seq):
            self._show(seq[idx + 1])

    def go_back(self):
        seq = self._sequence()
        idx = seq.index(self.current_name)
        if idx > 0:
            self._show(seq[idx - 1])

    def _show(self, name, activate=True):
        old = self.pages.get(self.current_name)
        page = self.pages[name]
        self.current_name = name
        self.stack.set_visible_child_name(name)
        self.back_btn.set_visible(not page.no_back_button)
        self.next_btn.set_visible(not page.no_next_button)
        self.set_ready(False)
        if old is not None and old is not page:
            old.set_page_inactive()
        if activate:
            page.set_page_active()


class SetupApp(Adw.Application):
    def __init__(self, defaults, installer, fullscreen=True):
        super().__init__(application_id=APP_ID)
        self._defaults = defaults
        self._installer = installer
        self._fullscreen = fullscreen

    def do_activate(self):
        win = self.get_active_window()
        if win is None:
            win = SetupWindow(self, self._defaults, self._installer,
                              fullscreen=self._fullscreen)
        win.present()


def self_check(installer):
    """Construct the Application and every page without presenting anything
    (CI/dev smoke test; needs GTK to initialize, i.e. some display)."""
    if not Gtk.init_check():
        print("self-check: SKIP (no display available)", file=sys.stderr)
        return 0
    Adw.init()
    try:
        defaults = load_defaults(installer)
        source = installer
    except (OSError, RuntimeError, ValueError) as e:
        defaults = model.Defaults(json.loads(json.dumps(_SELF_CHECK_DEFAULTS)))
        source = "embedded fixture (%s)" % e
    app = SetupApp(defaults, installer, fullscreen=False)
    assert app.get_application_id() == APP_ID
    # application=None: attaching a window to a not-yet-started GApplication
    # triggers a Gtk-CRITICAL; construction coverage is identical.
    win = SetupWindow(None, defaults, installer, fullscreen=False)
    expected = set(model.page_sequence(None))
    built = set(win.pages)
    if built != expected:
        print("self-check: FAIL (pages %r != %r)" % (built, expected),
              file=sys.stderr)
        return 1
    # Exercise the welcome page's activation path (no subprocess spawns).
    win.pages[model.PAGE_WELCOME].set_page_active()
    print("self-check: OK (%d pages constructed; defaults from %s)" %
          (len(win.pages), source))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(prog="snosi-setup")
    parser.add_argument("--installer", default=None,
                        help="path to snosi-install (default: "
                             "$SNOSI_INSTALL or %s)" % model.INSTALLER_DEFAULT)
    parser.add_argument("--self-check", action="store_true",
                        help="construct the app + every page, then exit")
    parser.add_argument("--windowed", action="store_true",
                        help="do not fullscreen (development)")
    args = parser.parse_args(argv)

    import os
    installer = args.installer or os.environ.get("SNOSI_INSTALL") \
        or model.INSTALLER_DEFAULT

    if args.self_check:
        return self_check(installer)

    try:
        defaults = load_defaults(installer)
    except (OSError, RuntimeError, ValueError) as e:
        print("snosi-setup: cannot load installer defaults: %s" % e,
              file=sys.stderr)
        return 1
    app = SetupApp(defaults, installer, fullscreen=not args.windowed)
    return app.run(None)
