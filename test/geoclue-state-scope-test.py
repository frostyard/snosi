#!/usr/bin/env python3
"""Ensure desktop-only geoclue state is recreated only with its account."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
assert os.geteuid() == 0, "run with sudo python3"
for tree in ("mkosi.images/base/mkosi.extra", "shared/floe/tree"):
    assert not (repo / tree / "usr/lib/tmpfiles.d/geoclue.conf").exists()
assert "geoclue-2.0" in (repo / "shared/packages/snow/mkosi.conf").read_text()
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root / "etc").mkdir()
    (root / "etc/passwd").write_text("root:x:0:0::/root:/bin/sh\n")
    (root / "etc/group").write_text("root:x:0:\n")
    for kind in ("sysusers", "tmpfiles"):
        dest = root / f"usr/lib/{kind}.d"
        dest.mkdir(parents=True)
        shutil.copyfile(repo / f"shared/snow/tree/usr/lib/{kind}.d/geoclue.conf", dest / "geoclue.conf")
    subprocess.run(["systemd-sysusers", f"--root={root}"], check=True)
    subprocess.run(["systemd-tmpfiles", f"--root={root}", "--create", "geoclue.conf"], check=True)
    account = next(l.split(":") for l in (root / "etc/passwd").read_text().splitlines() if l.startswith("geoclue:"))
    state = root / "var/lib/geoclue"
    assert (state.stat().st_uid, state.stat().st_gid) == (int(account[2]), int(account[3]))
print("PASS: geoclue state stays with the desktop package and account")
