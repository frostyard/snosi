#!/usr/bin/env python3
"""Recreate SANE identities and persistent state using only the base payload."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
assert os.geteuid() == 0, "run with sudo python3"
assert "sane-utils" in (repo / "mkosi.images/base/mkosi.conf").read_text()
for relative in ("sysusers.d/sane.conf", "tmpfiles.d/saned.conf"):
    assert not (repo / "shared/snow/tree/usr/lib" / relative).exists()
for existing in (False, True):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "etc").mkdir()
        accounts = "root:x:0:0::/root:/bin/sh\n"
        groups = "root:x:0:\n"
        if existing:
            accounts += "saned:x:123:124::/var/lib/saned:/usr/sbin/nologin\n"
            groups += "saned:x:124:\nscanner:x:125:\n"
        (root / "etc/passwd").write_text(accounts)
        (root / "etc/group").write_text(groups)
        for relative in ("sysusers.d/sane.conf", "tmpfiles.d/saned.conf"):
            dest = root / "usr/lib" / relative
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(repo / "mkosi.images/base/mkosi.extra/usr/lib" / relative, dest)
        subprocess.run(["systemd-sysusers", f"--root={root}"], check=True)
        subprocess.run(["systemd-tmpfiles", f"--root={root}", "--create", "saned.conf"], check=True)
        user = next(l.split(":") for l in (root / "etc/passwd").read_text().splitlines() if l.startswith("saned:"))
        scanner = next(l.split(":") for l in (root / "etc/group").read_text().splitlines() if l.startswith("scanner:"))
        assert "saned" in scanner[3].split(",")
        directory = root / "var/lib/saned"
        assert (directory.stat().st_uid, directory.stat().st_gid) == (int(user[2]), int(user[3]))
        assert directory.stat().st_mode & 0o777 == 0o755
        if existing:
            assert (root / "etc/passwd").read_text() == accounts
print("PASS: base alone provisions SANE identities, scanner membership and state")
