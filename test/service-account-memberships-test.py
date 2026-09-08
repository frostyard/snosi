#!/usr/bin/env python3
"""Check fresh and existing service-account membership with real sysusers."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
assert os.geteuid() == 0, "run with sudo python3"
base = repo / "mkosi.images/base/mkosi.extra/usr/lib/sysusers.d"
snow = repo / "shared/snow/tree/usr/lib/sysusers.d"
assert (base / "usbmux.conf").read_bytes() == (snow / "usbmux.conf").read_bytes()
for existing in (False, True):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "etc").mkdir()
        accounts = "root:x:0:0::/root:/bin/sh\n"
        groups = "root:x:0:\nplugdev:x:46:\nlpadmin:x:200:\n"
        if existing:
            accounts += "saned:x:301:401::/var/lib/saned:/usr/sbin/nologin\n"
            accounts += "cups-pk-helper:x:302:402::/nonexistent:/usr/sbin/nologin\n"
            accounts += "usbmux:x:303:403::/var/lib/usbmux:/usr/sbin/nologin\n"
            groups += "saned:x:401:\ncups-pk-helper:x:402:\nusbmux:x:403:\n"
        (root / "etc/passwd").write_text(accounts)
        (root / "etc/group").write_text(groups)
        dest = root / "usr/lib/sysusers.d"
        dest.mkdir(parents=True)
        # Follow the definition if a later PR moves SANE into base.
        sane = base / "sane.conf" if (base / "sane.conf").exists() else snow / "sane.conf"
        for source in (sane, snow / "cups-pk-helper.conf", base / "usbmux.conf"):
            shutil.copyfile(source, dest / source.name)
        subprocess.run(["systemd-sysusers", f"--root={root}"], check=True)
        users = {f[0]: f for l in (root / "etc/passwd").read_text().splitlines() if (f := l.split(":"))}
        groups = {f[0]: f for l in (root / "etc/group").read_text().splitlines() if (f := l.split(":"))}
        for user, group in (("saned", "scanner"), ("cups-pk-helper", "lpadmin"), ("usbmux", "plugdev")):
            assert user in groups[group][3].split(","), (user, group)
            assert group not in users, f"unintended user {group}"
        if existing:
            assert (root / "etc/passwd").read_text() == accounts
        else:
            assert users["cups-pk-helper"][3] == groups["lpadmin"][2]
            assert users["usbmux"][3] == groups["plugdev"][2]
        before = (root / "etc/group").read_bytes()
        subprocess.run(["systemd-sysusers", f"--root={root}"], check=True)
        assert (root / "etc/group").read_bytes() == before
print("PASS: intended memberships, Debian primary groups, preserved existing IDs")
