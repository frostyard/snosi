# SPDX-License-Identifier: LGPL-2.1-or-later
#
# pages.py -- the GTK4/libadwaita wizard pages of snosi-setup. All install
# decisions/validation/argv assembly/event parsing live in model.py (no GTK
# there); these classes only render state and mutate SetupState.
#
# Widget idioms (Adw.StatusPage + Adw.Clamp + PreferencesGroup/EntryRow/
# PasswordEntryRow, per-page set_page_active/set_page_inactive/finish with
# window.set_ready gating the Next button) are ported from first-setup's
# views (window.py + views/*.py); no Gtk.Template/gresource -- everything is
# built in code so there is no build step.

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, GLib, Gtk  # noqa: E402

from . import data, model  # noqa: E402


def _clamped(*children):
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
    for child in children:
        box.append(child)
    clamp = Adw.Clamp(maximum_size=560)
    clamp.set_child(box)
    return clamp


class Page(Adw.Bin):
    """Base page: window/state/defaults plumbing + the first-setup page
    protocol (set_page_active/set_page_inactive/finish)."""

    name = None
    title = ""
    no_back_button = False
    no_next_button = False

    def __init__(self, window):
        super().__init__()
        self.window = window
        self.state = window.state
        self.defaults = window.defaults
        self.build()

    def build(self):
        raise NotImplementedError

    def set_page_active(self):
        self.window.set_ready(True)

    def set_page_inactive(self):
        pass

    def finish(self):
        """Commit page state into SetupState; False blocks navigation."""
        return True


# ---------------------------------------------------------------------------
# 1. Welcome / product picker
# ---------------------------------------------------------------------------


class WelcomePage(Page):
    name = model.PAGE_WELCOME
    title = "Welcome"
    no_back_button = True

    def build(self):
        self._selected = None
        status = Adw.StatusPage(
            icon_name="computer-symbolic",
            title="Install Snosi Linux",
            description="Choose the product to install. The serial console "
                        "always offers the text-mode installer as well.")
        group = Adw.PreferencesGroup(title="Product")
        first_radio = None
        for product in self.defaults.products:
            row = Adw.ActionRow(
                title=product.name,
                subtitle="needs at least %s of disk" %
                         model.human_bytes(product.minimum_disk_bytes))
            radio = Gtk.CheckButton(valign=Gtk.Align.CENTER, focusable=False)
            if first_radio is None:
                first_radio = radio
            else:
                radio.set_group(first_radio)
            radio.connect("toggled", self._on_toggled, product.name)
            row.add_prefix(radio)
            row.set_activatable_widget(radio)
            group.add(row)
        status.set_child(_clamped(group))
        self.set_child(status)

    def _on_toggled(self, radio, name):
        if radio.get_active():
            self._selected = name
            self.window.set_ready(True)

    def set_page_active(self):
        self.window.set_ready(self._selected is not None)

    def finish(self):
        if self._selected is None:
            return False
        self.state.product = self.defaults.product(self._selected)
        return True


# ---------------------------------------------------------------------------
# 2. Network check (HEAD against the origin; skippable with a warning)
# ---------------------------------------------------------------------------


class NetworkPage(Page):
    name = model.PAGE_NETWORK
    title = "Network"

    def build(self):
        self._checking = False
        self._ok = False
        self.status = Adw.StatusPage(
            icon_name="network-wired-symbolic",
            title="Checking the download server…",
            description="The installer downloads the OS image from\n%s" %
                        self.defaults.origin_default)
        self.spinner = Gtk.Spinner(spinning=True, width_request=32,
                                   height_request=32,
                                   halign=Gtk.Align.CENTER)
        self.retry_btn = Gtk.Button(label="Check again",
                                    halign=Gtk.Align.CENTER, visible=False)
        self.retry_btn.connect("clicked", lambda *_: self._start_check())
        self.skip_btn = Gtk.Button(label="Continue anyway (install will "
                                         "fail without network)",
                                   halign=Gtk.Align.CENTER, visible=False)
        self.skip_btn.add_css_class("destructive-action")
        self.skip_btn.connect("clicked", self._on_skip)
        self.status.set_child(_clamped(self.spinner, self.retry_btn,
                                       self.skip_btn))
        self.set_child(self.status)

    def set_page_active(self):
        self.window.set_ready(self._ok)
        if not self._ok:
            self._start_check()

    def _start_check(self):
        if self._checking:
            return
        self._checking = True
        self.spinner.set_visible(True)
        self.spinner.start()
        self.retry_btn.set_visible(False)
        self.skip_btn.set_visible(False)
        self.status.set_title("Checking the download server…")
        try:
            # A literal HEAD request against the origin, async on the GLib
            # loop; curl ships on the ISO for snosi-install itself.
            proc = Gio.Subprocess.new(
                ["curl", "-fsI", "--connect-timeout", "10", "--max-time",
                 "20", self.defaults.origin_default],
                Gio.SubprocessFlags.STDOUT_SILENCE |
                Gio.SubprocessFlags.STDERR_SILENCE)
        except GLib.Error:
            self._finish_check(False)
            return
        proc.wait_async(None, self._on_check_done)

    def _on_check_done(self, proc, result):
        try:
            proc.wait_finish(result)
            ok = proc.get_successful()
        except GLib.Error:
            ok = False
        self._finish_check(ok)

    def _finish_check(self, ok):
        self._checking = False
        self._ok = ok
        self.spinner.stop()
        self.spinner.set_visible(False)
        if ok:
            self.status.set_icon_name("object-select-symbolic")
            self.status.set_title("Download server reachable")
            self.state.network_skipped = False
            self.window.set_ready(True)
        else:
            self.status.set_icon_name("network-wired-disconnected-symbolic")
            self.status.set_title("Cannot reach the download server")
            self.retry_btn.set_visible(True)
            self.skip_btn.set_visible(True)
            self.window.set_ready(False)

    def _on_skip(self, *_):
        self.state.network_skipped = True
        self._ok = True
        self.window.set_ready(True)
        self.window.advance()


# ---------------------------------------------------------------------------
# 3-5. Searchable choice pages (locale / keyboard / timezone)
# ---------------------------------------------------------------------------


class ChoicePage(Page):
    """Shared searchable single-select list, the shape of first-setup's
    language/keyboard/timezone pickers (search entry + rows, limit +
    'shortened' hint)."""

    icon_name = "preferences-desktop-locale-symbolic"
    description = ""
    RESULT_LIMIT = 60

    def load_choices(self):
        raise NotImplementedError  # -> [(code, display)]

    def default_code(self):
        raise NotImplementedError

    def commit(self, code):
        raise NotImplementedError

    def build(self):
        self._choices = None
        self._selected = None
        self._rows = []
        self.status = Adw.StatusPage(icon_name=self.icon_name,
                                     title=self.title,
                                     description=self.description)
        self.search = Gtk.SearchEntry(placeholder_text="Search…")
        self.search.connect("search-changed", lambda *_: self._refresh())
        self.listbox = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.listbox.add_css_class("boxed-list")
        self.listbox.connect("row-selected", self._on_row_selected)
        scrolled = Gtk.ScrolledWindow(min_content_height=320,
                                      max_content_height=420,
                                      propagate_natural_height=True,
                                      hscrollbar_policy=Gtk.PolicyType.NEVER)
        scrolled.set_child(self.listbox)
        self.hint = Gtk.Label(label="", halign=Gtk.Align.CENTER)
        self.hint.add_css_class("dim-label")
        self.status.set_child(_clamped(self.search, scrolled, self.hint))
        self.set_child(self.status)

    def set_page_active(self):
        if self._choices is None:
            self._choices = self.load_choices()
            if self._selected is None:
                self._selected = self.default_code()
            self._refresh()
        self.window.set_ready(self._selected is not None)

    def _refresh(self):
        matches, shortened = data.search_choices(
            self._choices, self.search.get_text(), self.RESULT_LIMIT)
        self.listbox.remove_all()
        self._rows = []
        select_row = None
        for code, display in matches:
            row = Gtk.ListBoxRow()
            label = Gtk.Label(label="%s  (%s)" % (display, code),
                              halign=Gtk.Align.START, margin_top=8,
                              margin_bottom=8, margin_start=12,
                              margin_end=12, ellipsize=3)  # PANGO_ELLIPSIZE_END
            row.set_child(label)
            row.code = code
            self.listbox.append(row)
            self._rows.append(row)
            if code == self._selected:
                select_row = row
        if select_row is not None:
            self.listbox.select_row(select_row)
        self.hint.set_label(
            "More matches than shown — refine the search." if shortened
            else "")

    def _on_row_selected(self, listbox, row):
        if row is not None:
            self._selected = row.code
        self.window.set_ready(self._selected is not None)

    def finish(self):
        if self._selected is None:
            return False
        self.commit(self._selected)
        return True


class LocalePage(ChoicePage):
    name = model.PAGE_LOCALE
    title = "Language & Locale"
    description = "System language and formats."

    def load_choices(self):
        return [(loc, data.locale_display_name(loc))
                for loc in data.load_locales()]

    def default_code(self):
        return self.defaults.defaults.get("locale")

    def commit(self, code):
        self.state.locale = code


class KeyboardPage(ChoicePage):
    name = model.PAGE_KEYBOARD
    title = "Keyboard"
    icon_name = "input-keyboard-symbolic"
    description = "Console and desktop keyboard layout."

    def load_choices(self):
        return data.load_keyboards()

    def default_code(self):
        return self.defaults.defaults.get("keyboard")

    def commit(self, code):
        self.state.keyboard = code


class TimezonePage(ChoicePage):
    name = model.PAGE_TIMEZONE
    title = "Timezone"
    icon_name = "preferences-system-time-symbolic"
    description = "System timezone."

    def load_choices(self):
        return [(tz, tz.replace("_", " ")) for tz in data.load_timezones()]

    def default_code(self):
        return self.defaults.defaults.get("timezone")

    def commit(self, code):
        self.state.timezone = code


# ---------------------------------------------------------------------------
# 6. Hostname
# ---------------------------------------------------------------------------


class HostnamePage(Page):
    name = model.PAGE_HOSTNAME
    title = "Hostname"

    def build(self):
        self._defaulted = False
        status = Adw.StatusPage(icon_name="network-server-symbolic",
                                title="Hostname",
                                description="The name this machine uses on "
                                            "the network.")
        group = Adw.PreferencesGroup()
        self.entry = Adw.EntryRow(title="Hostname")
        self.entry.connect("changed", lambda *_: self._validate())
        group.add(self.entry)
        self.error = Gtk.Label(
            label="Letters, digits and inner hyphens only (max 63).",
            halign=Gtk.Align.CENTER, opacity=0.0)
        self.error.add_css_class("dim-label")
        status.set_child(_clamped(group, self.error))
        self.set_child(status)

    def set_page_active(self):
        if not self._defaulted and self.state.product is not None:
            self.entry.set_text(self.state.product.bare)
            self._defaulted = True
        self._validate()

    def _validate(self):
        text = self.entry.get_text()
        ok = self.defaults.valid_hostname(text)
        if ok:
            self.entry.remove_css_class("error")
        else:
            self.entry.add_css_class("error")
        self.error.set_opacity(0.0 if ok else 1.0)
        self.window.set_ready(ok)
        return ok

    def finish(self):
        if not self._validate():
            return False
        self.state.hostname = self.entry.get_text()
        return True


# ---------------------------------------------------------------------------
# 7. First user
# ---------------------------------------------------------------------------


class UserPage(Page):
    name = model.PAGE_USER
    title = "First User"

    def build(self):
        status = Adw.StatusPage(
            icon_name="system-users-symbolic", title="Create Your User",
            description="An administrator account (sudo + desktop groups).")
        group = Adw.PreferencesGroup()
        self.fullname = Adw.EntryRow(title="Full name (optional)")
        self.username = Adw.EntryRow(title="Username")
        self.password = Adw.PasswordEntryRow(title="Password")
        self.password2 = Adw.PasswordEntryRow(title="Confirm password")
        for w in (self.fullname, self.username, self.password,
                  self.password2):
            w.connect("changed", lambda *_: self._validate())
            group.add(w)
        self.skip_user = Gtk.CheckButton(
            label="Do not create a user account (headless/server setup)")
        self.skip_user.connect("toggled", lambda *_: self._validate())
        self.error = Gtk.Label(label="", halign=Gtk.Align.CENTER)
        self.error.add_css_class("dim-label")
        status.set_child(_clamped(group, self.skip_user, self.error))
        self.set_child(status)

    def set_page_active(self):
        self._validate()

    def _problem(self):
        if self.skip_user.get_active():
            return ""
        username = self.username.get_text()
        if not username:
            return "Enter a username."
        if not self.defaults.valid_username(username):
            return ("Usernames start with a lowercase letter; lowercase, "
                    "digits, - and _ only (max 32).")
        if not self.password.get_text():
            return "Enter a password."
        if self.password.get_text() != self.password2.get_text():
            return "Passwords do not match."
        return ""

    def _validate(self):
        problem = self._problem()
        skip = self.skip_user.get_active()
        for w in (self.fullname, self.username, self.password,
                  self.password2):
            w.set_sensitive(not skip)
        bad_user = (not skip and self.username.get_text() and
                    not self.defaults.valid_username(self.username.get_text()))
        if bad_user:
            self.username.add_css_class("error")
        else:
            self.username.remove_css_class("error")
        self.error.set_label(problem)
        self.window.set_ready(problem == "")
        return problem == ""

    def finish(self):
        if not self._validate():
            return False
        if self.skip_user.get_active():
            self.state.username = None
            self.state.user_password = None
            self.state.user_fullname = ""
        else:
            self.state.username = self.username.get_text()
            self.state.user_password = self.password.get_text()
            self.state.user_fullname = self.fullname.get_text()
        return True


# ---------------------------------------------------------------------------
# 8. Sysext features
# ---------------------------------------------------------------------------


class FeaturesPage(Page):
    name = model.PAGE_FEATURES
    title = "Extensions"

    # Checkbox list from the product's build-time feature catalog, fetched
    # hash-verified via the signed index (`snosi-install --print-features`) --
    # nobody should have to know sysext ids by heart. When the catalog is
    # unavailable (release predating catalog publication, or offline), fall
    # back to the original manual-entry rows with an explanatory banner.

    def build(self):
        self._features = []          # manual-entry names (fallback mode)
        self._selected = set()       # checkbox selections (catalog mode)
        self._switch_rows = []       # (name, Adw.SwitchRow)
        self._catalog_loaded_for = None
        self.status = Adw.StatusPage(
            icon_name="application-x-addon-symbolic",
            title="System Extensions",
            description="Optional features to enable on first boot. "
                        "Everything here can also be enabled later.")
        self.spinner = Gtk.Spinner(spinning=False, halign=Gtk.Align.CENTER)
        self.catalog_group = Adw.PreferencesGroup()
        self.catalog_group.set_visible(False)
        self.fallback_banner = Gtk.Label(
            label="", halign=Gtk.Align.CENTER, wrap=True, visible=False)
        self.fallback_banner.add_css_class("dim-label")
        entry_group = Adw.PreferencesGroup()
        self.entry = Adw.EntryRow(title="Feature name")
        self.entry.connect("entry-activated", self._on_add)
        self.entry.connect("changed", lambda *_: self._validate_entry())
        add_btn = Gtk.Button(icon_name="list-add-symbolic",
                             valign=Gtk.Align.CENTER)
        add_btn.add_css_class("flat")
        add_btn.connect("clicked", self._on_add)
        self.entry.add_suffix(add_btn)
        entry_group.add(self.entry)
        self.entry_group = entry_group
        self.entry_group.set_visible(False)
        self.list_group = Adw.PreferencesGroup(title="Enabled at first boot")
        self.list_group.set_visible(False)
        self._rows = []
        self.status.set_child(_clamped(
            self.spinner, self.catalog_group, self.fallback_banner,
            self.entry_group, self.list_group))
        self.set_child(self.status)

    def set_page_active(self):
        # Everything on this page is optional, so Next is enabled
        # unconditionally -- before and independent of the catalog fetch.
        super().set_page_active()
        product = self.state.product.name if self.state.product else None
        if product and self._catalog_loaded_for != product:
            self._fetch_catalog(product)

    def _fetch_catalog(self, product):
        self.spinner.set_visible(True)
        self.spinner.start()
        argv = [self.window.installer, "--print-features", "--product", product]
        if self.state.origin is not None:
            argv += ["--origin", self.state.origin]
        try:
            proc = Gio.Subprocess.new(
                argv,
                Gio.SubprocessFlags.STDOUT_PIPE |
                Gio.SubprocessFlags.STDERR_SILENCE)
        except GLib.Error:
            self._enter_fallback("Could not run the feature catalog query.")
            return
        proc.communicate_utf8_async(None, None, self._on_catalog, product)

    def _on_catalog(self, proc, result, product):
        self.spinner.stop()
        self.spinner.set_visible(False)
        try:
            _ok, stdout, _stderr = proc.communicate_utf8_finish(result)
            if proc.get_exit_status() != 0:
                raise ValueError("catalog query failed")
            feats = model.parse_features(stdout)
        except (GLib.Error, ValueError, KeyError) as e:
            self._enter_fallback(
                "The feature catalog could not be loaded (%s). Enter feature "
                "names manually, or enable features after installation." % e)
            return
        self._catalog_loaded_for = product
        for _name, row in self._switch_rows:
            self.catalog_group.remove(row)
        self._switch_rows = []
        for feat in feats:
            row = Adw.SwitchRow(title=feat.name, subtitle=feat.description)
            row.set_active(feat.name in self._selected or feat.default)
            row.connect("notify::active", self._on_toggle, feat.name)
            self.catalog_group.add(row)
            self._switch_rows.append((feat.name, row))
        self.catalog_group.set_visible(bool(self._switch_rows))
        self.fallback_banner.set_visible(False)
        self.entry_group.set_visible(False)
        self.list_group.set_visible(False)

    def _on_toggle(self, row, _pspec, name):
        if row.get_active():
            self._selected.add(name)
        else:
            self._selected.discard(name)

    def _enter_fallback(self, message):
        self.spinner.stop()
        self.spinner.set_visible(False)
        self.catalog_group.set_visible(False)
        self.fallback_banner.set_label(message)
        self.fallback_banner.set_visible(True)
        self.entry_group.set_visible(True)
        self.list_group.set_visible(bool(self._rows))

    def _validate_entry(self):
        text = self.entry.get_text()
        if text and not self.defaults.valid_feature(text):
            self.entry.add_css_class("error")
        else:
            self.entry.remove_css_class("error")

    def _on_add(self, *_):
        text = self.entry.get_text().strip()
        if not text or not self.defaults.valid_feature(text):
            return
        if text in self._features:
            self.entry.set_text("")
            return
        self._features.append(text)
        row = Adw.ActionRow(title=text)
        remove = Gtk.Button(icon_name="list-remove-symbolic",
                            valign=Gtk.Align.CENTER)
        remove.add_css_class("flat")
        remove.connect("clicked", self._on_remove, row, text)
        row.add_suffix(remove)
        self.list_group.add(row)
        self._rows.append(row)
        self.list_group.set_visible(True)
        self.entry.set_text("")

    def _on_remove(self, _btn, row, text):
        self._features.remove(text)
        self.list_group.remove(row)
        self._rows.remove(row)
        self.list_group.set_visible(bool(self._rows))

    def finish(self):
        if self._catalog_loaded_for is not None:
            # Catalog mode: exactly the checked switches, in catalog order.
            self.state.features = [n for n, row in self._switch_rows
                                   if row.get_active()]
        else:
            self.state.features = list(self._features)
        return True


# ---------------------------------------------------------------------------
# 9. Core flatpaks (skipped entirely when the product disallows them)
# ---------------------------------------------------------------------------


class FlatpaksPage(Page):
    name = model.PAGE_FLATPAKS
    title = "Applications"

    def build(self):
        self._defaulted = False
        status = Adw.StatusPage(
            icon_name="system-software-install-symbolic",
            title="Core Applications",
            description="Install the core desktop Flatpak set on first "
                        "boot (browser and essential apps).")
        group = Adw.PreferencesGroup()
        self.switch = Adw.SwitchRow(title="Install core Flatpaks")
        group.add(self.switch)
        status.set_child(_clamped(group))
        self.set_child(status)

    def set_page_active(self):
        if not self._defaulted and self.state.product is not None:
            self.switch.set_active(self.state.product.core_flatpaks_default)
            self._defaulted = True
        self.window.set_ready(True)

    def finish(self):
        self.state.core_flatpaks = self.switch.get_active()
        return True


# ---------------------------------------------------------------------------
# 10. Disk selection
# ---------------------------------------------------------------------------


class DiskPage(Page):
    name = model.PAGE_DISK
    title = "Disk"

    def build(self):
        self._disks = []
        self._rows = []
        self._selected = None
        self.status = Adw.StatusPage(
            icon_name="drive-harddisk-symbolic", title="Select Target Disk",
            description="The ENTIRE selected disk will be erased.")
        self.group = Adw.PreferencesGroup()
        self.spinner = Gtk.Spinner(spinning=False, halign=Gtk.Align.CENTER)
        self.empty = Gtk.Label(label="", halign=Gtk.Align.CENTER,
                               visible=False)
        self.status.set_child(_clamped(self.spinner, self.group, self.empty))
        self.set_child(self.status)

    def set_page_active(self):
        self.window.set_ready(False)
        self._refresh()

    def _refresh(self):
        for row in self._rows:
            self.group.remove(row)
        self._rows = []
        self._selected = None
        self.empty.set_visible(False)
        self.spinner.set_visible(True)
        self.spinner.start()
        try:
            proc = Gio.Subprocess.new(
                [self.window.installer, "--list-disks-json",
                 "--product", self.state.product.name],
                Gio.SubprocessFlags.STDOUT_PIPE |
                Gio.SubprocessFlags.STDERR_SILENCE)
        except GLib.Error as e:
            self._show_empty("Could not run the disk scan: %s" % e.message)
            return
        proc.communicate_utf8_async(None, None, self._on_disks)

    def _on_disks(self, proc, result):
        try:
            _ok, stdout, _stderr = proc.communicate_utf8_finish(result)
            disks = model.parse_disks(stdout)
        except (GLib.Error, ValueError, KeyError) as e:
            self._show_empty("Disk scan failed: %s" % e)
            return
        self.spinner.stop()
        self.spinner.set_visible(False)
        self._disks = disks
        if not disks:
            self._show_empty("No disks found.")
            return
        first_radio = None
        for disk in disks:
            title = "%s — %s" % (disk.path, model.human_bytes(disk.size_bytes))
            bits = [b for b in (disk.model, disk.transport,
                                "serial: %s" % disk.serial if disk.serial
                                else "") if b]
            row = Adw.ActionRow(title=title, subtitle="  ·  ".join(bits))
            radio = Gtk.CheckButton(valign=Gtk.Align.CENTER, focusable=False)
            if first_radio is None:
                first_radio = radio
            else:
                radio.set_group(first_radio)
            if disk.installable:
                radio.connect("toggled", self._on_toggled, disk)
                row.add_prefix(radio)
                row.set_activatable_widget(radio)
            else:
                # Visible but not selectable, with the CLI's refusal reason.
                row.add_prefix(radio)
                row.set_subtitle("REFUSED: %s" % disk.refusal)
                row.set_sensitive(False)
            self.group.add(row)
            self._rows.append(row)

    def _show_empty(self, message):
        self.spinner.stop()
        self.spinner.set_visible(False)
        self.empty.set_label(message)
        self.empty.set_visible(True)
        self.window.set_ready(False)

    def _on_toggled(self, radio, disk):
        if radio.get_active():
            self._selected = disk
            self.window.set_ready(True)

    def finish(self):
        if self._selected is None or not self._selected.installable:
            return False
        if self.state.disk is not self._selected:
            # Changing disks invalidates a previously-typed confirmation.
            self.state.confirm_text = ""
        self.state.disk = self._selected
        return True


# ---------------------------------------------------------------------------
# 11. Typed erase confirmation
# ---------------------------------------------------------------------------


class ConfirmPage(Page):
    name = model.PAGE_CONFIRM
    title = "Confirm Erase"

    def build(self):
        self.status = Adw.StatusPage(
            icon_name="dialog-warning-symbolic",
            title="This Disk Will Be Erased",
            description="")
        group = Adw.PreferencesGroup()
        self.entry = Adw.EntryRow(title="Type the disk path or serial")
        self.entry.connect("changed", lambda *_: self._validate())
        group.add(self.entry)
        self.hint = Gtk.Label(label="", halign=Gtk.Align.CENTER)
        self.hint.add_css_class("dim-label")
        self.status.set_child(_clamped(group, self.hint))
        self.set_child(self.status)

    def set_page_active(self):
        disk = self.state.disk
        serial_bit = (" (serial %s)" % disk.serial) if disk.serial else ""
        self.status.set_description(
            "EVERYTHING on %s%s — %s, %s — will be permanently destroyed.\n"
            "To continue, type its path%s exactly." % (
                disk.path, serial_bit, disk.model or "unknown model",
                model.human_bytes(disk.size_bytes),
                " or serial" if disk.serial else ""))
        self.entry.set_text(self.state.confirm_text)
        self._validate()

    def _validate(self):
        typed = self.entry.get_text()
        # Exactly the CLI's confirm_typed_matches(): path, or non-empty
        # serial, exact string equality.
        ok = model.confirm_matches(typed, self.state.disk.path,
                                   self.state.disk.serial)
        self.hint.set_label("" if ok or not typed else "Does not match.")
        self.window.set_ready(ok)
        return ok

    def finish(self):
        if not self._validate():
            return False
        self.state.confirm_text = self.entry.get_text()
        return True


# ---------------------------------------------------------------------------
# 12. Recovery key acknowledgement
# ---------------------------------------------------------------------------


class RecoveryPage(Page):
    name = model.PAGE_RECOVERY
    title = "Recovery Key"

    def build(self):
        self.status = Adw.StatusPage(
            icon_name="dialog-password-symbolic",
            title="/var Encryption Recovery Passphrase",
            description="")
        self.ack = Gtk.CheckButton(
            label="I understand I must copy the recovery passphrase "
                  "somewhere OFF this machine before rebooting")
        self.ack.connect("toggled", lambda *_: self.window.set_ready(
            self.ack.get_active()))
        self.status.set_child(_clamped(self.ack))
        self.set_child(self.status)

    def set_page_active(self):
        if self.state.recovery_key_file is None:
            self.state.recovery_key_file = model.default_recovery_key_path(
                self.state.product.name)
        self.status.set_description(
            "Your data partition (/var) is encrypted. A recovery passphrase "
            "is generated during the install and is the ONLY way to unlock "
            "your data if the TPM is unavailable or replaced.\n\n"
            "It will be written to:\n%s\n\n"
            "The passphrase is shown on the final screen after the install "
            "completes. Copy it somewhere safe that is NOT this computer "
            "(password manager, phone, paper)." % self.state.recovery_key_file)
        self.window.set_ready(self.ack.get_active())

    def finish(self):
        if not self.ack.get_active():
            return False
        self.state.recovery_ack = True
        return True


# ---------------------------------------------------------------------------
# 13. MOK password
# ---------------------------------------------------------------------------


class MokPage(Page):
    name = model.PAGE_MOK
    title = "Secure Boot"

    def build(self):
        status = Adw.StatusPage(
            icon_name="security-high-symbolic",
            title="Secure Boot Enrollment Password",
            description="On the next boot a blue \"MOK Management\" screen "
                        "appears automatically. Choose \"Enroll MOK\", "
                        "continue, and re-enter THIS password there once. "
                        "The system cannot boot until that is done.")
        group = Adw.PreferencesGroup()
        self.password = Adw.PasswordEntryRow(title="One-time password")
        self.password2 = Adw.PasswordEntryRow(title="Confirm password")
        for w in (self.password, self.password2):
            w.connect("changed", lambda *_: self._validate())
            group.add(w)
        self.error = Gtk.Label(label="", halign=Gtk.Align.CENTER)
        self.error.add_css_class("dim-label")
        status.set_child(_clamped(group, self.error))
        self.set_child(status)

    def set_page_active(self):
        self._validate()

    def _problem(self):
        # The CLI requires a non-empty first line; min length 1.
        if not self.password.get_text():
            return "Enter a password."
        if self.password.get_text() != self.password2.get_text():
            return "Passwords do not match."
        return ""

    def _validate(self):
        problem = self._problem()
        self.error.set_label(problem)
        self.window.set_ready(problem == "")
        return problem == ""

    def finish(self):
        if not self._validate():
            return False
        self.state.mok_password = self.password.get_text()
        return True


# ---------------------------------------------------------------------------
# 14. Progress (the one privileged action: spawning snosi-install)
# ---------------------------------------------------------------------------


class ProgressPage(Page):
    name = model.PAGE_PROGRESS
    title = "Installing"
    no_back_button = True
    no_next_button = True   # window.advance() is driven by the done event

    def build(self):
        self._started = False
        self._finished = False
        self._secrets = None
        self._proc = None
        self.parser = None
        self._stderr_tail = []
        self._stdout_eof = False
        self._exited = False
        self._exit_ok = False
        self.status = Adw.StatusPage(icon_name="content-loading-symbolic",
                                     title="Installing…", description="")
        self.progress = Gtk.ProgressBar(show_text=False)
        buf = Gtk.TextBuffer()
        self.logview = Gtk.TextView(buffer=buf, editable=False,
                                    cursor_visible=False, monospace=True)
        self.logview.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        scrolled = Gtk.ScrolledWindow(min_content_height=220,
                                      max_content_height=280,
                                      propagate_natural_height=True)
        scrolled.set_child(self.logview)
        scrolled.add_css_class("card")
        self.quit_btn = Gtk.Button(label="Quit to console",
                                   halign=Gtk.Align.CENTER, visible=False)
        self.quit_btn.connect("clicked",
                              lambda *_: self.window.get_application().quit())
        self.status.set_child(_clamped(self.progress, scrolled,
                                       self.quit_btn))
        self.set_child(self.status)

    def set_page_active(self):
        self.window.set_ready(False)
        if not self._started:
            self._started = True
            self._start_install()
            GLib.timeout_add(150, self._pulse)

    def _pulse(self):
        if self._finished:
            return False
        self.progress.pulse()
        return True

    def _fail(self, message):
        self._finished = True
        if self._secrets is not None:
            self._secrets.cleanup()
            self._secrets = None
        self.status.set_icon_name("dialog-error-symbolic")
        self.status.set_title("Installation Failed")
        self.status.set_description(message)
        self.progress.set_visible(False)
        self.quit_btn.set_visible(True)
        self.window.set_ready(False)

    def _start_install(self):
        self.parser = model.ProgressParser()
        # Secrets: written 0600 under XDG_RUNTIME_DIR (fallback /run)
        # IMMEDIATELY before spawn; deleted in _on_exited (and _fail) no
        # matter how the process ends. Never on argv, never logged.
        self._secrets = model.SecretFiles()
        try:
            mok_file = self._secrets.add(self.state.mok_password, "mok")
            user_file = None
            if self.state.username is not None:
                user_file = self._secrets.add(self.state.user_password,
                                              "userpw")
            argv = model.build_install_argv(
                self.state, self.defaults, user_file, mok_file,
                installer=self.window.installer)
        except (model.StateError, OSError) as e:
            self._fail("Could not assemble the install command:\n%s" % e)
            return
        try:
            self._proc = Gio.Subprocess.new(
                argv,
                Gio.SubprocessFlags.STDOUT_PIPE |
                Gio.SubprocessFlags.STDERR_PIPE)
        except GLib.Error as e:
            self._fail("Could not start the installer:\n%s" % e.message)
            return
        out = Gio.DataInputStream.new(self._proc.get_stdout_pipe())
        err = Gio.DataInputStream.new(self._proc.get_stderr_pipe())
        out.read_line_async(GLib.PRIORITY_DEFAULT, None,
                            self._on_stdout_line)
        err.read_line_async(GLib.PRIORITY_DEFAULT, None,
                            self._on_stderr_line)
        self._proc.wait_async(None, self._on_exited)

    # -- stdout: the proto-1 JSON event stream (NEVER parse human text) ----
    def _on_stdout_line(self, stream, result):
        try:
            line, _len = stream.read_line_finish_utf8(result)
        except GLib.Error:
            line = None
        if line is None:
            # EOF. The verdict needs BOTH this and process exit: wait_async
            # can fire while buffered events (including "done") are still
            # unread, so deciding at exit alone mis-reports success as
            # failure (caught live by the headless drive-through).
            self._stdout_eof = True
            self._maybe_conclude()
            return
        ev = self.parser.feed_line(line)
        if ev is not None:
            self._render()
        stream.read_line_async(GLib.PRIORITY_DEFAULT, None,
                               self._on_stdout_line)

    # -- stderr: kept only as failure diagnostics, never parsed ------------
    def _on_stderr_line(self, stream, result):
        try:
            line, _len = stream.read_line_finish_utf8(result)
        except GLib.Error:
            return
        if line is None:
            return
        self._stderr_tail.append(line)
        del self._stderr_tail[:-30]
        stream.read_line_async(GLib.PRIORITY_DEFAULT, None,
                               self._on_stderr_line)

    def _render(self):
        p = self.parser
        if p.phase_title:
            self.status.set_title(p.phase_title)
        if p.version:
            self.status.set_description("%s %s" % (p.product or "",
                                                   p.version))
        buf = self.logview.get_buffer()
        buf.set_text("\n".join(p.log_tail))
        end = buf.get_end_iter()
        self.logview.scroll_to_iter(end, 0.0, False, 0.0, 1.0)

    def _on_exited(self, proc, result):
        try:
            proc.wait_finish(result)
        except GLib.Error:
            pass
        # Secrets are only needed while the installer can still read them.
        if self._secrets is not None:
            self._secrets.cleanup()
            self._secrets = None
        self._exited = True
        self._exit_ok = proc.get_successful()
        self._maybe_conclude()

    def _maybe_conclude(self):
        if self._finished or not (self._exited and self._stdout_eof):
            return
        if self._exit_ok and self.parser.succeeded:
            self._finished = True
            self.progress.set_fraction(1.0)
            self.window.advance()
        else:
            message = self.parser.error or "\n".join(self._stderr_tail[-8:]) \
                or "The installer exited unexpectedly."
            self._fail(message)


# ---------------------------------------------------------------------------
# 15. Done
# ---------------------------------------------------------------------------


class DonePage(Page):
    name = model.PAGE_DONE
    title = "Done"
    no_back_button = True
    no_next_button = True

    def build(self):
        self.status = Adw.StatusPage(icon_name="object-select-symbolic",
                                     title="Installation Complete",
                                     description="")
        self.key_label = Gtk.Label(label="", selectable=True, wrap=True,
                                   halign=Gtk.Align.CENTER)
        self.key_label.add_css_class("monospace")
        self.key_label.add_css_class("title-2")
        key_frame = Gtk.Frame()
        key_frame.set_child(self.key_label)
        self.key_note = Gtk.Label(label="", wrap=True,
                                  halign=Gtk.Align.CENTER)
        self.key_note.add_css_class("dim-label")
        reboot = Gtk.Button(label="Reboot", halign=Gtk.Align.CENTER)
        reboot.add_css_class("suggested-action")
        reboot.add_css_class("pill")
        reboot.connect("clicked", self._on_reboot)
        quit_btn = Gtk.Button(label="Quit to console",
                              halign=Gtk.Align.CENTER)
        quit_btn.add_css_class("flat")
        quit_btn.connect("clicked",
                         lambda *_: self.window.get_application().quit())
        self.status.set_child(_clamped(self.key_note, key_frame, reboot,
                                       quit_btn))
        self.set_child(self.status)

    def set_page_active(self):
        self.window.set_ready(False)
        done = {}
        progress_page = self.window.page_by_name(model.PAGE_PROGRESS)
        if progress_page is not None and progress_page.parser is not None \
                and progress_page.parser.done:
            done = progress_page.parser.done
        summary = "%s %s installed to %s." % (
            done.get("product", self.state.product.name if self.state.product
                     else "?"),
            done.get("version", ""), done.get("disk", ""))
        self.status.set_description(
            "%s\n\nOn the next boot, enroll the Secure Boot key in the blue "
            "MOK Management screen using the password you set." % summary)
        # The recovery passphrase: read from the file the installer wrote
        # (this app chose the path), displayed ONLY here, after the install.
        passphrase = None
        if self.state.recovery_key_file:
            try:
                with open(self.state.recovery_key_file, "r",
                          encoding="utf-8") as f:
                    passphrase = f.read().strip()
            except OSError:
                passphrase = None
        if passphrase:
            self.key_label.set_label(passphrase)
            self.key_note.set_label(
                "Your /var recovery passphrase (also at %s — that copy "
                "vanishes at reboot). WRITE IT DOWN NOW, off this machine:" %
                self.state.recovery_key_file)
        else:
            self.key_label.set_label("(recovery passphrase unavailable)")
            self.key_note.set_label(
                "Could not read %s — recover it from a console BEFORE "
                "rebooting." % (self.state.recovery_key_file or "?"))

    def _on_reboot(self, *_):
        try:
            Gio.Subprocess.new(["systemctl", "reboot"],
                               Gio.SubprocessFlags.NONE)
        except GLib.Error:
            pass


PAGE_CLASSES = {
    cls.name: cls for cls in (
        WelcomePage, NetworkPage, LocalePage, KeyboardPage, TimezonePage,
        HostnamePage, UserPage, FeaturesPage, FlatpaksPage, DiskPage,
        ConfirmPage, RecoveryPage, MokPage, ProgressPage, DonePage)
}
