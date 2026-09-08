#!/usr/bin/env python3
"""Derive the SSH helper group from immutable file ownership, preserving IDs."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
assert os.geteuid() == 0, "run with sudo python3"
for existing in (False, True):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "etc").mkdir()
        (root / "etc/passwd").write_text("root:x:0:0::/root:/bin/sh\n")
        groups = "root:x:0:\n" + ("_ssh:x:456:\n" if existing else "")
        (root / "etc/group").write_text(groups)
        binary = root / "usr/bin/ssh-agent"
        binary.parent.mkdir(parents=True)
        binary.write_text("fixture\n")
        os.chown(binary, 0, 321)
        binary.chmod(0o2755)
        dest = root / "usr/lib/sysusers.d"
        dest.mkdir(parents=True)
        shutil.copyfile(repo / "mkosi.images/base/mkosi.extra/usr/lib/sysusers.d/openssh-client.conf",
                        dest / "openssh-client.conf")
        for _ in range(2):
            subprocess.run(["systemd-sysusers", f"--root={root}"], check=True)
            group = next(l.split(":") for l in (root / "etc/group").read_text().splitlines() if l.startswith("_ssh:"))
            assert int(group[2]) == (456 if existing else 321)
            assert binary.stat().st_gid == 321
            assert binary.stat().st_mode & 0o7777 == 0o2755
print("PASS: _ssh derives the binary GID, preserves existing groups and setgid file")
