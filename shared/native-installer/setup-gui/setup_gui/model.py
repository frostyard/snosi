# SPDX-License-Identifier: LGPL-2.1-or-later
#
# model.py -- pure-logic core of snosi-setup (NO GTK imports, ever; see
# __init__.py). Everything a page needs to decide, validate, assemble, or
# parse lives here so test/snosi-setup-model-test.py can cover it without a
# display or GI bindings:
#
#   - Defaults / Product: the `snosi-install --print-defaults` document
#     (proto 1), including the validation regexes the CLI itself enforces.
#   - Disk / parse_disks: the `snosi-install --list-disks-json` document.
#   - confirm_matches: byte-for-byte port of the CLI's
#     confirm_typed_matches() (path exact-match, or non-empty serial
#     exact-match) so the GUI's typed-erase gate can never accept something
#     the CLI would then reject.
#   - SetupState + build_install_argv: the one place the
#     `snosi-install --non-interactive --json-progress ...` command line is
#     assembled. Secrets NEVER appear on argv -- only --*-file paths.
#   - ProgressParser: the --json-progress proto-1 line-delimited event
#     stream (start/phase/log/error/done; unknown events and non-JSON lines
#     are tolerated per the contract comment in snosi-install).
#   - page_sequence: the wizard page order, with product-conditional skips.
#   - write_secret_file / SecretFiles: 0600 tmpfiles under XDG_RUNTIME_DIR
#     (fallback /run), created immediately before spawn and deleted in a
#     finally block by the caller.

import json
import os
import re
import secrets as _secrets
import stat

INSTALLER_DEFAULT = "/usr/libexec/snosi-install"

# ---------------------------------------------------------------------------
# --print-defaults document (proto 1)
# ---------------------------------------------------------------------------


class Product:
    def __init__(self, obj):
        self.name = obj["name"]                      # e.g. "snow-ab"
        self.bare = obj["bare"]                      # e.g. "snow"
        self.minimum_disk_bytes = int(obj["minimum_disk_bytes"])
        self.core_flatpaks_default = bool(obj["core_flatpaks_default"])
        self.core_flatpaks_allowed = bool(obj["core_flatpaks_allowed"])


class Defaults:
    """Parsed `snosi-install --print-defaults` document."""

    def __init__(self, doc):
        proto = doc.get("proto")
        if proto != 1:
            raise ValueError("unsupported defaults document proto: %r" % (proto,))
        self.proto = proto
        self.products = [Product(p) for p in doc["products"]]
        self.defaults = dict(doc["defaults"])        # locale/timezone/keyboard
        self.origin_default = doc["origin_default"]
        self.mok_cert_default = doc["mok_cert_default"]
        self.regexes = dict(doc["regexes"])          # raw ERE strings

    @classmethod
    def from_json(cls, text):
        return cls(json.loads(text))

    def product(self, name):
        for p in self.products:
            if p.name == name:
                return p
        raise KeyError("unknown product: %r" % (name,))

    def product_names(self):
        return [p.name for p in self.products]

    # -- validation -------------------------------------------------------
    # snosi-install validates with bash `[[ =~ ]]` (POSIX ERE); the shipped
    # patterns use only constructs Python's `re` interprets identically, and
    # they carry their own ^...$ anchors, so re.search() mirrors bash.

    def _matches(self, key, value):
        return re.search(self.regexes[key], value) is not None

    def valid_username(self, v):
        return self._matches("username", v)

    def valid_hostname(self, v):
        return self._matches("hostname", v)

    def valid_locale(self, v):
        return self._matches("locale", v)

    def valid_timezone(self, v):
        return self._matches("timezone", v)

    def valid_keyboard(self, v):
        return self._matches("keyboard", v)

    def valid_feature(self, v):
        return self._matches("feature", v)


# ---------------------------------------------------------------------------
# --list-disks-json document
# ---------------------------------------------------------------------------


class Disk:
    def __init__(self, obj):
        self.path = obj["path"]
        self.model = obj.get("model") or ""
        self.serial = obj.get("serial") or ""
        self.size_bytes = int(obj["size_bytes"])
        self.transport = obj.get("transport") or ""
        self.refusal = obj.get("refusal")            # None == installable

    @property
    def installable(self):
        return self.refusal is None


def parse_disks(text):
    return [Disk(d) for d in json.loads(text)]


# ---------------------------------------------------------------------------
# --print-features document (proto 1): the product-curated sysext feature
# catalog, generated at image build time and fetched hash-verified via the
# signed index. Receivers tolerate unknown keys (forward compatibility).
# ---------------------------------------------------------------------------


class Feature:
    def __init__(self, obj):
        self.name = obj["name"]
        self.description = obj.get("description") or obj["name"]
        self.documentation = obj.get("documentation") or ""
        self.default = bool(obj.get("default", False))


def parse_features(text):
    """Parse a `snosi-install --print-features` catalog. Raises ValueError on
    a document that is not a proto-1 feature catalog."""
    doc = json.loads(text)
    if doc.get("proto") != 1:
        raise ValueError("feature catalog proto %r is not 1" % (doc.get("proto"),))
    feats = doc.get("features")
    if not isinstance(feats, list):
        raise ValueError("feature catalog has no features array")
    return [Feature(f) for f in feats]


def human_bytes(n):
    """Binary-unit pretty printer for disk sizes (display only)."""
    n = float(n)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or unit == "TiB":
            if unit == "B":
                return "%d %s" % (int(n), unit)
            return "%.1f %s" % (n, unit)
        n /= 1024
    raise AssertionError("unreachable")


def confirm_matches(typed, path, serial):
    """Exact port of snosi-install confirm_typed_matches(): the typed value
    must equal the resolved disk's path, or (when the serial is non-empty)
    its serial. An empty typed value never matches."""
    if typed == "" or path == "":
        return False
    if typed == path:
        return True
    if serial != "" and typed == serial:
        return True
    return False


# ---------------------------------------------------------------------------
# Wizard state + page flow
# ---------------------------------------------------------------------------

PAGE_WELCOME = "welcome"
PAGE_NETWORK = "network"
PAGE_LOCALE = "locale"
PAGE_KEYBOARD = "keyboard"
PAGE_TIMEZONE = "timezone"
PAGE_HOSTNAME = "hostname"
PAGE_USER = "user"
PAGE_FEATURES = "features"
PAGE_FLATPAKS = "flatpaks"
PAGE_DISK = "disk"
PAGE_CONFIRM = "confirm"
PAGE_RECOVERY = "recovery"
PAGE_MOK = "mok"
PAGE_PROGRESS = "progress"
PAGE_DONE = "done"

_ALL_PAGES = [
    PAGE_WELCOME, PAGE_NETWORK, PAGE_LOCALE, PAGE_KEYBOARD, PAGE_TIMEZONE,
    PAGE_HOSTNAME, PAGE_USER, PAGE_FEATURES, PAGE_FLATPAKS, PAGE_DISK,
    PAGE_CONFIRM, PAGE_RECOVERY, PAGE_MOK, PAGE_PROGRESS, PAGE_DONE,
]


def page_sequence(product=None):
    """The wizard page order. The core-flatpaks page is dropped entirely for
    products where core_flatpaks_allowed is false (the CLI dies on
    --core-flatpaks for cayo-ab; the GUI never shows the choice)."""
    pages = list(_ALL_PAGES)
    if product is not None and not product.core_flatpaks_allowed:
        pages.remove(PAGE_FLATPAKS)
    return pages


class SetupState:
    """Everything the wizard collects. Plain data; pages mutate it, and
    build_install_argv() consumes it."""

    def __init__(self):
        self.product = None            # Product
        self.network_skipped = False
        self.locale = None             # str or None (None == image default)
        self.timezone = None
        self.keyboard = None
        self.hostname = None
        self.username = None           # None == no first user
        self.user_fullname = ""
        self.user_password = None      # secret; NEVER placed on argv
        self.features = []             # list[str]
        self.core_flatpaks = None      # True/False/None (None == CLI default)
        self.disk = None               # Disk
        self.confirm_text = ""         # what the user typed on the erase gate
        self.recovery_ack = False      # "I will save the passphrase" gate
        self.recovery_key_file = None  # path this app chose (under /root)
        self.mok_password = None       # secret; NEVER placed on argv
        self.origin = None             # None == CLI default origin

    def confirm_ok(self):
        return self.disk is not None and confirm_matches(
            self.confirm_text, self.disk.path, self.disk.serial)


def default_recovery_key_path(product_name, now=None):
    """A fresh path under /root for the generated recovery passphrase.
    snosi-install refuses a pre-existing file, so embed a timestamp."""
    import time
    stamp = time.strftime("%Y%m%d%H%M%S", time.gmtime(now))
    return "/root/%s-recovery-key-%s.txt" % (product_name, stamp)


class StateError(ValueError):
    """A SetupState that cannot be turned into a valid install command."""


def validate_state(state, defaults):
    """Full-state validation, run before command assembly. Returns a list of
    human-readable problems (empty == good). Mirrors snosi-install's own
    --non-interactive argument matrix so a GUI bug fails HERE, not minutes
    into an install."""
    problems = []
    if state.product is None:
        problems.append("no product selected")
    if state.disk is None:
        problems.append("no target disk selected")
    elif state.disk.refusal is not None:
        problems.append("selected disk is refused: %s" % state.disk.refusal)
    if state.disk is not None and not state.confirm_ok():
        problems.append("typed confirmation does not match the disk path or serial")
    if not state.recovery_ack:
        problems.append("recovery passphrase not acknowledged")
    if not state.recovery_key_file:
        problems.append("no recovery key file path chosen")
    if not state.mok_password:
        problems.append("no MOK password set")
    if state.username is not None:
        if not defaults.valid_username(state.username):
            problems.append("invalid username %r" % state.username)
        if not state.user_password:
            problems.append("username set but no user password")
    if state.hostname is not None and not defaults.valid_hostname(state.hostname):
        problems.append("invalid hostname %r" % state.hostname)
    if state.locale is not None and not defaults.valid_locale(state.locale):
        problems.append("invalid locale %r" % state.locale)
    if state.timezone is not None and not defaults.valid_timezone(state.timezone):
        problems.append("invalid timezone %r" % state.timezone)
    if state.keyboard is not None and not defaults.valid_keyboard(state.keyboard):
        problems.append("invalid keyboard %r" % state.keyboard)
    for feat in state.features:
        if not defaults.valid_feature(feat):
            problems.append("invalid feature name %r" % feat)
    if state.product is not None and state.core_flatpaks and \
            not state.product.core_flatpaks_allowed:
        problems.append("core flatpaks are not allowed for %s" % state.product.name)
    return problems


def build_install_argv(state, defaults, user_password_file, mok_password_file,
                       installer=INSTALLER_DEFAULT):
    """Assemble the ONE snosi-install invocation. Secrets travel exclusively
    via the two 0600 file paths; raising StateError on an invalid state is
    the last line of defense (pages should have gated earlier)."""
    problems = validate_state(state, defaults)
    if problems:
        raise StateError("; ".join(problems))
    if not mok_password_file:
        raise StateError("mok_password_file is required")
    if state.username is not None and not user_password_file:
        raise StateError("user_password_file is required when a username is set")

    argv = [
        installer,
        "--non-interactive",
        "--json-progress",
        "--product", state.product.name,
        "--disk", state.disk.path,
        "--confirm", state.confirm_text,
        "--encrypt-var",
        "--recovery-key-file", state.recovery_key_file,
        "--acknowledge-recovery-saved",
        "--mok-password-file", mok_password_file,
    ]
    if state.origin is not None:
        argv += ["--origin", state.origin]
    if state.hostname is not None:
        argv += ["--hostname", state.hostname]
    if state.locale is not None:
        argv += ["--locale", state.locale]
    if state.timezone is not None:
        argv += ["--timezone", state.timezone]
    if state.keyboard is not None:
        argv += ["--keyboard", state.keyboard]
    if state.username is not None:
        argv += ["--username", state.username,
                 "--user-password-file", user_password_file]
        if state.user_fullname:
            argv += ["--user-fullname", state.user_fullname]
    else:
        argv += ["--no-create-user"]
    for feat in state.features:
        argv += ["--enable-feature", feat]
    if state.product.core_flatpaks_allowed:
        if state.core_flatpaks is True:
            argv += ["--core-flatpaks"]
        elif state.core_flatpaks is False:
            argv += ["--no-core-flatpaks"]
        # None: let the CLI apply its own default (currently: enabled).
    else:
        # Explicit is better: cayo-ab dies on --core-flatpaks, accepts
        # --no-core-flatpaks as a no-op restatement of its forced policy.
        argv += ["--no-core-flatpaks"]

    # Belt and suspenders: no secret material may ever ride on argv.
    for secret in (state.user_password, state.mok_password):
        if secret and any(secret in a for a in argv):
            raise StateError("secret material leaked onto argv")
    return argv


# ---------------------------------------------------------------------------
# --json-progress proto-1 event stream
# ---------------------------------------------------------------------------


class Event:
    def __init__(self, kind, data):
        self.kind = kind    # start|phase|log|error|done|unknown
        self.data = data

    def __repr__(self):
        return "Event(%r, %r)" % (self.kind, self.data)


_KNOWN_EVENTS = ("start", "phase", "log", "error", "done")


def parse_event(line):
    """One line of installer stdout -> Event or None. Non-JSON lines and
    JSON without an \"event\" key return None (the contract routes all
    human-oriented output away from stdout in --json-progress mode, but a
    tolerant reader costs nothing). Unknown event kinds come back as
    kind=\"unknown\" -- the proto-1 grammar comment requires receivers to
    ignore them so new events can be added compatibly."""
    line = line.strip()
    if not line:
        return None
    try:
        obj = json.loads(line)
    except (ValueError, TypeError):
        return None
    if not isinstance(obj, dict) or "event" not in obj:
        return None
    kind = obj["event"]
    if kind not in _KNOWN_EVENTS:
        return Event("unknown", obj)
    return Event(kind, obj)


class ProgressParser:
    """Feed installer stdout lines; exposes the rolled-up install status the
    progress page renders. Tail is bounded so a chatty install can't grow
    memory without limit."""

    LOG_TAIL_MAX = 400

    def __init__(self):
        self.proto = None
        self.product = None
        self.version = None
        self.phase_id = None
        self.phase_title = None
        self.log_tail = []          # newest last; bounded
        self.error = None           # first error message wins
        self.done = None            # the done event dict, when seen
        self.saw_start = False

    def feed_line(self, line):
        ev = parse_event(line)
        if ev is None:
            return None
        if ev.kind == "start":
            self.saw_start = True
            self.proto = ev.data.get("proto")
            self.product = ev.data.get("product")
            self.version = ev.data.get("version")
        elif ev.kind == "phase":
            self.phase_id = ev.data.get("id")
            self.phase_title = ev.data.get("title")
        elif ev.kind == "log":
            msg = ev.data.get("message", "")
            if ev.data.get("level") == "warning":
                msg = "Warning: " + msg
            self._append_log(msg)
        elif ev.kind == "error":
            if self.error is None:
                self.error = ev.data.get("message", "install failed")
            self._append_log("Error: " + ev.data.get("message", ""))
        elif ev.kind == "done":
            self.done = ev.data
        return ev

    def _append_log(self, msg):
        self.log_tail.append(msg)
        if len(self.log_tail) > self.LOG_TAIL_MAX:
            del self.log_tail[: len(self.log_tail) - self.LOG_TAIL_MAX]

    @property
    def succeeded(self):
        return self.done is not None and self.error is None


# ---------------------------------------------------------------------------
# Secret files (0600, XDG_RUNTIME_DIR with /run fallback)
# ---------------------------------------------------------------------------


def runtime_secrets_dir():
    """A root-only directory for secret tmpfiles. XDG_RUNTIME_DIR when set
    and usable, else /run (the ISO runs everything as root; /run is a
    tmpfs), else the system tempdir as a last resort. The snosi-setup
    subdirectory is created 0700."""
    base = os.environ.get("XDG_RUNTIME_DIR")
    if not base or not os.path.isdir(base):
        base = "/run" if os.path.isdir("/run") else None
    if base is None:
        import tempfile
        base = tempfile.gettempdir()
    d = os.path.join(base, "snosi-setup")
    os.makedirs(d, mode=0o700, exist_ok=True)
    os.chmod(d, 0o700)
    return d


def write_secret_file(content, label, directory=None):
    """Create a fresh 0600 file containing `content` (one line, as the
    installer reads with head -1) and return its path. O_EXCL so an existing
    path is never silently reused."""
    directory = directory or runtime_secrets_dir()
    path = os.path.join(directory, "%s-%s" % (label, _secrets.token_hex(8)))
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.write(fd, content.encode("utf-8"))
        if not content.endswith("\n"):
            os.write(fd, b"\n")
    finally:
        os.close(fd)
    # Refuse to hand back anything a non-owner could read (paranoia against
    # umask/ACL surprises; mirrors the CLI's check_secret_file_perms).
    mode = stat.S_IMODE(os.stat(path).st_mode)
    if mode & 0o077:
        os.unlink(path)
        raise OSError("secret file %s ended up mode %o" % (path, mode))
    return path


class SecretFiles:
    """Context manager owning the per-install secret files: created on
    entry-time writes, ALWAYS deleted on exit (the finally-block contract
    from the plan)."""

    def __init__(self, directory=None):
        self._directory = directory
        self.paths = []

    def add(self, content, label):
        path = write_secret_file(content, label, self._directory)
        self.paths.append(path)
        return path

    def cleanup(self):
        for path in self.paths:
            try:
                os.unlink(path)
            except OSError:
                pass
        self.paths = []

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.cleanup()
        return False
