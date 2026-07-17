#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Static, non-root, no-GTK regression test for the snosi-setup frontend's
# pure-logic core (shared/native-installer/setup-gui/setup_gui/model.py; T2,
# docs/plans/2026-07-17-graphical-installer-plan.md). Covers:
#
#   - the --print-defaults document (parsed from an embedded FIXTURE that is
#     a verbatim capture of the real script's output, plus a live-drift
#     check against the in-tree snosi-install when it is runnable)
#   - validation against the regexes the CLI itself enforces
#   - install command assembly (exact argv, secrets only ever via --*-file)
#   - --json-progress proto-1 event-stream parsing (start/phase/log/error/
#     done, unknown-event and non-JSON tolerance)
#   - --list-disks-json parsing with refusal handling
#   - the typed-erase confirmation matcher (CLI confirm_typed_matches port)
#   - secret tmpfile creation/permissions/cleanup
#   - page-flow sequencing (core-flatpaks page dropped for cayo-ab)
#   - py_compile of every setup-gui file (+ pyflakes when available)
#
# Usage: python3 test/snosi-setup-model-test.py

import json
import os
import py_compile
import stat
import subprocess
import sys
import tempfile

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
SETUP_GUI_DIR = os.path.join(ROOT_DIR, "shared/native-installer/setup-gui")
INSTALLER = os.path.join(ROOT_DIR,
                         "shared/native-installer/tree/usr/libexec/"
                         "snosi-install")

sys.path.insert(0, SETUP_GUI_DIR)
from setup_gui import data, model  # noqa: E402

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


def eq(desc, actual, expected):
    ok(desc, actual == expected,
       "expected %r, got %r" % (expected, actual))


# ---------------------------------------------------------------------------
# FIXTURE: verbatim `snosi-install --print-defaults` output (captured
# 2026-07-17 from shared/native-installer/tree/usr/libexec/snosi-install).
# The live-drift check below fails when the real script diverges.
# ---------------------------------------------------------------------------
FIXTURE_DEFAULTS = r"""
{
  "proto": 1,
  "products": [
    {
      "name": "cayo-ab",
      "bare": "cayo",
      "minimum_disk_bytes": 16642998272,
      "core_flatpaks_default": false,
      "core_flatpaks_allowed": false
    },
    {
      "name": "snow-ab",
      "bare": "snow",
      "minimum_disk_bytes": 23085449216,
      "core_flatpaks_default": true,
      "core_flatpaks_allowed": true
    },
    {
      "name": "snowfield-ab",
      "bare": "snowfield",
      "minimum_disk_bytes": 23085449216,
      "core_flatpaks_default": true,
      "core_flatpaks_allowed": true
    }
  ],
  "defaults": {
    "locale": "en_US.UTF-8",
    "timezone": "UTC",
    "keyboard": "us"
  },
  "origin_default": "https://repository.frostyard.org",
  "mok_cert_default": "/usr/lib/snosi/mok.crt",
  "regexes": {
    "username": "^[a-z][a-z0-9_-]{0,31}$",
    "hostname": "^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$",
    "locale": "^[A-Za-z][A-Za-z0-9_.@-]*$",
    "timezone": "^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+){0,2}$",
    "keyboard": "^[a-z0-9,]+(:[A-Za-z0-9,_-]*(:[A-Za-z0-9_-]+)?)?$",
    "feature": "^[A-Za-z0-9._-]+$"
  }
}
"""

FIXTURE_DISKS = r"""
[
  {"path": "/dev/vda", "model": "TestDisk", "serial": "SER123",
   "size_bytes": 34359738368, "transport": "virtio", "refusal": null},
  {"path": "/dev/vdb", "model": "SmallDisk", "serial": "",
   "size_bytes": 1073741824, "transport": "virtio",
   "refusal": "smaller than the 15.5 GiB minimum for this product"},
  {"path": "/dev/vdc", "model": "BootMedium", "serial": "ISOSER",
   "size_bytes": 34359738368, "transport": "usb",
   "refusal": "this is the installer's own boot medium"}
]
"""

# ---------------------------------------------------------------------------
# 0. py_compile every shipped file (+ pyflakes when available)
# ---------------------------------------------------------------------------
files = [
    os.path.join(SETUP_GUI_DIR, "snosi-setup"),
    os.path.join(SETUP_GUI_DIR, "setup_gui/__init__.py"),
    os.path.join(SETUP_GUI_DIR, "setup_gui/__main__.py"),
    os.path.join(SETUP_GUI_DIR, "setup_gui/model.py"),
    os.path.join(SETUP_GUI_DIR, "setup_gui/data.py"),
    os.path.join(SETUP_GUI_DIR, "setup_gui/pages.py"),
    os.path.join(SETUP_GUI_DIR, "setup_gui/app.py"),
]
for f in files:
    try:
        py_compile.compile(f, doraise=True,
                           cfile=os.path.join(tempfile.mkdtemp(), "c.pyc"))
        ok("py_compile %s" % os.path.relpath(f, ROOT_DIR), True)
    except py_compile.PyCompileError as e:
        ok("py_compile %s" % os.path.relpath(f, ROOT_DIR), False, str(e))

try:
    import pyflakes  # noqa: F401
    have_pyflakes = True
except ImportError:
    have_pyflakes = False
if have_pyflakes:
    r = subprocess.run([sys.executable, "-m", "pyflakes"] + files,
                       capture_output=True, text=True)
    ok("pyflakes clean", r.returncode == 0, r.stdout + r.stderr)
else:
    print("# pyflakes not available; skipping (not a failure)")

# ---------------------------------------------------------------------------
# 1. Defaults document
# ---------------------------------------------------------------------------
d = model.Defaults.from_json(FIXTURE_DEFAULTS)
eq("defaults proto", d.proto, 1)
eq("three products", d.product_names(), ["cayo-ab", "snow-ab",
                                         "snowfield-ab"])
eq("cayo core flatpaks not allowed",
   d.product("cayo-ab").core_flatpaks_allowed, False)
eq("snow core flatpaks default on",
   d.product("snow-ab").core_flatpaks_default, True)
eq("cayo min disk bytes", d.product("cayo-ab").minimum_disk_bytes,
   16642998272)
eq("snow bare name", d.product("snow-ab").bare, "snow")
eq("origin default", d.origin_default, "https://repository.frostyard.org")
try:
    d.product("nope-ab")
    ok("unknown product raises", False)
except KeyError:
    ok("unknown product raises", True)
try:
    model.Defaults({"proto": 2, "products": []})
    ok("unknown proto rejected", False)
except ValueError:
    ok("unknown proto rejected", True)

# Live drift check: the embedded fixture must equal the real script's
# current output whenever the script is runnable on this host.
try:
    live = subprocess.run([INSTALLER, "--print-defaults"],
                          capture_output=True, text=True, timeout=60)
    runnable = live.returncode == 0
except (OSError, subprocess.TimeoutExpired):
    runnable = False
if runnable:
    eq("fixture matches live --print-defaults output",
       json.loads(live.stdout), json.loads(FIXTURE_DEFAULTS))
else:
    print("# %s not runnable here; skipping live drift check" % INSTALLER)

# ---------------------------------------------------------------------------
# 2. Validation (regexes come from the fixture document, not hardcoded)
# ---------------------------------------------------------------------------
ok("username valid", d.valid_username("bjk"))
ok("username valid with -_ digits", d.valid_username("a0_b-c"))
ok("username rejects uppercase", not d.valid_username("Bjk"))
ok("username rejects leading digit", not d.valid_username("0abc"))
ok("username rejects empty", not d.valid_username(""))
ok("username rejects 33 chars", not d.valid_username("a" * 33))
ok("username accepts 32 chars", d.valid_username("a" * 32))
ok("hostname valid", d.valid_hostname("snow"))
ok("hostname valid single char", d.valid_hostname("a"))
ok("hostname valid inner hyphen", d.valid_hostname("my-host-01"))
ok("hostname rejects leading hyphen", not d.valid_hostname("-host"))
ok("hostname rejects trailing hyphen", not d.valid_hostname("host-"))
ok("hostname rejects 64 chars", not d.valid_hostname("a" * 64))
ok("hostname accepts 63 chars", d.valid_hostname("a" * 63))
ok("hostname rejects dot", not d.valid_hostname("a.b"))
ok("locale valid", d.valid_locale("en_US.UTF-8"))
ok("locale valid with @", d.valid_locale("ca_ES@valencia"))
ok("locale rejects leading digit", not d.valid_locale("8bit"))
ok("timezone UTC valid", d.valid_timezone("UTC"))
ok("timezone Area/City valid", d.valid_timezone("America/New_York"))
ok("timezone 3-part valid", d.valid_timezone("America/Argentina/Ushuaia"))
ok("timezone rejects space", not d.valid_timezone("America/New York"))
ok("timezone rejects 4 parts", not d.valid_timezone("a/b/c/d"))
ok("keyboard layout valid", d.valid_keyboard("us"))
ok("keyboard layout:variant valid", d.valid_keyboard("us:altgr-intl"))
ok("keyboard triplet valid", d.valid_keyboard("us:altgr-intl:pc105"))
ok("keyboard empty variant valid", d.valid_keyboard("de:"))
ok("keyboard rejects uppercase layout", not d.valid_keyboard("US"))
ok("feature valid", d.valid_feature("docker"))
ok("feature valid dotted", d.valid_feature("1password-cli"))
ok("feature rejects space", not d.valid_feature("doc ker"))
ok("feature rejects slash", not d.valid_feature("a/b"))

# ---------------------------------------------------------------------------
# 3. Disk-list parsing + refusal handling
# ---------------------------------------------------------------------------
disks = model.parse_disks(FIXTURE_DISKS)
eq("three disks parsed", len(disks), 3)
ok("first disk installable", disks[0].installable)
eq("first disk serial", disks[0].serial, "SER123")
ok("small disk refused", not disks[1].installable)
ok("refusal reason preserved", "minimum" in disks[1].refusal)
ok("boot medium refused", not disks[2].installable)
eq("installable subset", [x.path for x in disks if x.installable],
   ["/dev/vda"])
eq("human_bytes GiB", model.human_bytes(34359738368), "32.0 GiB")

# ---------------------------------------------------------------------------
# 4. Typed-confirmation matcher (CLI confirm_typed_matches port)
# ---------------------------------------------------------------------------
ok("confirm matches path", model.confirm_matches("/dev/vda", "/dev/vda",
                                                 "SER123"))
ok("confirm matches serial", model.confirm_matches("SER123", "/dev/vda",
                                                   "SER123"))
ok("confirm rejects other text", not model.confirm_matches("vda", "/dev/vda",
                                                           "SER123"))
ok("confirm rejects empty", not model.confirm_matches("", "/dev/vda",
                                                      "SER123"))
ok("confirm empty serial never matches",
   not model.confirm_matches("", "/dev/vda", ""))
ok("confirm serial exact only", not model.confirm_matches("ser123",
                                                          "/dev/vda",
                                                          "SER123"))

# ---------------------------------------------------------------------------
# 5. Command assembly
# ---------------------------------------------------------------------------


def full_state(product="snow-ab"):
    st = model.SetupState()
    st.product = d.product(product)
    st.locale = "en_US.UTF-8"
    st.timezone = "Europe/Berlin"
    st.keyboard = "de:nodeadkeys"
    st.hostname = "myhost"
    st.username = "bjk"
    st.user_fullname = "Brian K"
    st.user_password = "hunter2secret"
    st.features = ["docker", "tailscale"]
    st.core_flatpaks = True
    st.disk = disks[0]
    st.confirm_text = "/dev/vda"
    st.recovery_ack = True
    st.recovery_key_file = "/root/snow-ab-recovery-key-20260717000000.txt"
    st.mok_password = "mok-secret-word"
    return st


st = full_state()
argv = model.build_install_argv(st, d, "/run/snosi-setup/userpw-x",
                                "/run/snosi-setup/mok-x",
                                installer="/usr/libexec/snosi-install")
eq("full argv exact", argv, [
    "/usr/libexec/snosi-install",
    "--non-interactive",
    "--json-progress",
    "--product", "snow-ab",
    "--disk", "/dev/vda",
    "--confirm", "/dev/vda",
    "--encrypt-var",
    "--recovery-key-file", "/root/snow-ab-recovery-key-20260717000000.txt",
    "--acknowledge-recovery-saved",
    "--mok-password-file", "/run/snosi-setup/mok-x",
    "--hostname", "myhost",
    "--locale", "en_US.UTF-8",
    "--timezone", "Europe/Berlin",
    "--keyboard", "de:nodeadkeys",
    "--username", "bjk",
    "--user-password-file", "/run/snosi-setup/userpw-x",
    "--user-fullname", "Brian K",
    "--enable-feature", "docker",
    "--enable-feature", "tailscale",
    "--core-flatpaks",
])
ok("user password never on argv",
   all("hunter2secret" not in a for a in argv))
ok("mok password never on argv",
   all("mok-secret-word" not in a for a in argv))

st2 = full_state("cayo-ab")
st2.username = None
st2.user_password = None
st2.user_fullname = ""
st2.core_flatpaks = None
st2.features = []
st2.confirm_text = "SER123"          # serial-based confirmation
argv2 = model.build_install_argv(st2, d, None, "/run/s/mok",
                                 installer="/usr/libexec/snosi-install")
ok("cayo argv has --no-create-user", "--no-create-user" in argv2)
ok("cayo argv has no user flags", "--username" not in argv2 and
   "--user-password-file" not in argv2 and "--user-fullname" not in argv2)
ok("cayo argv forces --no-core-flatpaks", "--no-core-flatpaks" in argv2)
ok("cayo argv never has --core-flatpaks", "--core-flatpaks" not in argv2)
eq("serial confirm on argv", argv2[argv2.index("--confirm") + 1], "SER123")

st3 = full_state()
st3.core_flatpaks = False
argv3 = model.build_install_argv(st3, d, "u", "m")
ok("snow opt-out gives --no-core-flatpaks", "--no-core-flatpaks" in argv3)
st4 = full_state()
st4.core_flatpaks = None
argv4 = model.build_install_argv(st4, d, "u", "m")
ok("snow None leaves flatpak choice to the CLI",
   "--core-flatpaks" not in argv4 and "--no-core-flatpaks" not in argv4)

# Invalid states must raise, not build a broken command line.
for mutate, desc in [
    (lambda s: setattr(s, "recovery_ack", False), "missing recovery ack"),
    (lambda s: setattr(s, "mok_password", None), "missing MOK password"),
    (lambda s: setattr(s, "confirm_text", "nope"), "bad confirmation"),
    (lambda s: setattr(s, "disk", disks[1]), "refused disk"),
    (lambda s: setattr(s, "hostname", "-bad-"), "invalid hostname"),
    (lambda s: setattr(s, "username", "Bad"), "invalid username"),
    (lambda s: setattr(s, "features", ["ok", "no good"]),
     "invalid feature"),
    (lambda s: setattr(s, "core_flatpaks", True) or
     setattr(s, "product", d.product("cayo-ab")),
     "core flatpaks on cayo"),
]:
    s = full_state()
    mutate(s)
    try:
        model.build_install_argv(s, d, "u", "m")
        ok("StateError on %s" % desc, False)
    except model.StateError:
        ok("StateError on %s" % desc, True)

# username without a password file is a hard error
s = full_state()
try:
    model.build_install_argv(s, d, None, "m")
    ok("StateError on missing user password file", False)
except model.StateError:
    ok("StateError on missing user password file", True)

# ---------------------------------------------------------------------------
# 6. --json-progress proto-1 event stream
# ---------------------------------------------------------------------------
p = model.ProgressParser()
lines = [
    '{"event":"phase","id":"index","title":"Fetching and verifying the '
    'signed release index"}',
    '{"event":"start","proto":1,"product":"snow-ab",'
    '"version":"20260717010101"}',
    '{"event":"log","level":"info","message":"Version: 20260717010101"}',
    '{"event":"log","level":"warning","message":"No TPM device found"}',
    "",                                   # blank: ignored
    "not json at all",                    # non-JSON: ignored
    '{"no_event_key": true}',             # JSON without event: ignored
    '{"event":"progress","phase":"download","bytes":5,"total":10}',  # unknown
    '{"event":"phase","id":"download","title":"Downloading and writing '
    'the disk image"}',
]
kinds = [ev.kind if ev else None for ev in (p.feed_line(x) for x in lines)]
eq("event kinds", kinds, ["phase", "start", "log", "log", None, None, None,
                          "unknown", "phase"])
ok("saw start", p.saw_start)
eq("proto from start", p.proto, 1)
eq("version from start", p.version, "20260717010101")
eq("current phase id", p.phase_id, "download")
eq("current phase title", p.phase_title,
   "Downloading and writing the disk image")
eq("log tail contents", p.log_tail,
   ["Version: 20260717010101", "Warning: No TPM device found"])
ok("not done yet", not p.succeeded and p.done is None and p.error is None)

p.feed_line('{"event":"done","product":"snow-ab",'
            '"version":"20260717010101","disk":"/dev/vda"}')
ok("done recorded", p.done is not None and p.succeeded)
eq("done disk", p.done["disk"], "/dev/vda")

perr = model.ProgressParser()
perr.feed_line('{"event":"error","message":"signature verification FAILED"}')
perr.feed_line('{"event":"error","message":"second error"}')
eq("first error wins", perr.error, "signature verification FAILED")
ok("errored stream never succeeded", not perr.succeeded)
perr.feed_line('{"event":"done","product":"x","version":"y","disk":"z"}')
ok("done after error still not success", not perr.succeeded)

pbound = model.ProgressParser()
for i in range(model.ProgressParser.LOG_TAIL_MAX + 50):
    pbound.feed_line(json.dumps({"event": "log", "level": "info",
                                 "message": "line %d" % i}))
eq("log tail bounded", len(pbound.log_tail), model.ProgressParser.LOG_TAIL_MAX)
eq("log tail keeps newest", pbound.log_tail[-1],
   "line %d" % (model.ProgressParser.LOG_TAIL_MAX + 49))

# ---------------------------------------------------------------------------
# 7. Page flow
# ---------------------------------------------------------------------------
seq_none = model.page_sequence(None)
seq_snow = model.page_sequence(d.product("snow-ab"))
seq_cayo = model.page_sequence(d.product("cayo-ab"))
eq("full sequence has 15 pages", len(seq_none), 15)
ok("snow sequence keeps flatpaks page", model.PAGE_FLATPAKS in seq_snow)
ok("cayo sequence drops flatpaks page",
   model.PAGE_FLATPAKS not in seq_cayo)
eq("cayo sequence otherwise identical",
   [x for x in seq_snow if x != model.PAGE_FLATPAKS], seq_cayo)
eq("first page is welcome", seq_none[0], model.PAGE_WELCOME)
eq("last pages are progress, done", seq_none[-2:],
   [model.PAGE_PROGRESS, model.PAGE_DONE])
ok("confirm comes after disk",
   seq_none.index(model.PAGE_CONFIRM) > seq_none.index(model.PAGE_DISK))
ok("recovery ack before progress",
   seq_none.index(model.PAGE_RECOVERY) < seq_none.index(model.PAGE_PROGRESS))

# ---------------------------------------------------------------------------
# 8. Secret files
# ---------------------------------------------------------------------------
with tempfile.TemporaryDirectory() as td:
    with model.SecretFiles(directory=td) as sf:
        path = sf.add("s3cret", "mok")
        ok("secret file exists", os.path.isfile(path))
        eq("secret file mode 0600",
           stat.S_IMODE(os.stat(path).st_mode), 0o600)
        with open(path) as f:
            eq("secret file content (newline-terminated for head -1)",
               f.read(), "s3cret\n")
        path2 = sf.add("other", "userpw")
        ok("distinct secret paths", path != path2)
    ok("secrets deleted on context exit",
       not os.path.exists(path) and not os.path.exists(path2))

env_backup = os.environ.get("XDG_RUNTIME_DIR")
try:
    with tempfile.TemporaryDirectory() as td:
        os.environ["XDG_RUNTIME_DIR"] = td
        sdir = model.runtime_secrets_dir()
        ok("secrets dir under XDG_RUNTIME_DIR", sdir.startswith(td))
        eq("secrets dir mode 0700", stat.S_IMODE(os.stat(sdir).st_mode),
           0o700)
finally:
    if env_backup is None:
        os.environ.pop("XDG_RUNTIME_DIR", None)
    else:
        os.environ["XDG_RUNTIME_DIR"] = env_backup

# ---------------------------------------------------------------------------
# 9. Recovery key path + data.py sanity (fallbacks make these host-neutral)
# ---------------------------------------------------------------------------
rk = model.default_recovery_key_path("snow-ab", now=0)
eq("recovery key path shape", rk,
   "/root/snow-ab-recovery-key-19700101000000.txt")
ok("recovery key path under /root", rk.startswith("/root/"))

locales = data.load_locales()
ok("locale table non-empty", len(locales) > 0)
ok("locale table is UTF-8 only",
   all(d.valid_locale(loc) for loc in locales[:50]))
keyboards = data.load_keyboards()
ok("keyboard table non-empty", len(keyboards) > 0)
ok("keyboard specs satisfy the CLI regex",
   all(d.valid_keyboard(spec) for spec, _ in keyboards))
timezones = data.load_timezones()
ok("timezone table non-empty", len(timezones) > 0)
eq("UTC first", timezones[0], "UTC")
ok("timezones satisfy the CLI regex",
   all(d.valid_timezone(tz) for tz in timezones))
matches, shortened = data.search_choices(keyboards, "us", limit=5)
ok("search limits results", len(matches) <= 5)
matches, _ = data.search_choices([("us", "English (US)")], "english us")
eq("multi-term search matches", matches, [("us", "English (US)")])
matches, _ = data.search_choices([("us", "English (US)")], "german")
eq("non-matching search empty", matches, [])

# ---------------------------------------------------------------------------
print("\n%d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
