#!/usr/bin/env python3
"""Replay the shipped post-merge provisioning commands with a fresh account."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
assert os.geteuid() == 0, "run with sudo python3"
unit = repo / "mkosi.images/base/mkosi.extra/usr/lib/systemd/system/reload-sysext.service"
commands = [shlex.split(line.split("=", 1)[1]) for line in unit.read_text().splitlines()
            if line.startswith("ExecStart=systemd-")]
assert {c[0] for c in commands} == {"systemd-sysusers", "systemd-tmpfiles"}
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root / "etc").mkdir()
    (root / "etc/passwd").write_text("root:x:0:0::/root:/bin/sh\n")
    (root / "etc/group").write_text("root:x:0:\n")
    for kind in ("sysusers", "tmpfiles"):
        dest = root / f"usr/lib/{kind}.d"
        dest.mkdir(parents=True)
        shutil.copyfile(repo / f"mkosi.images/coder/mkosi.extra/usr/lib/{kind}.d/coder.conf",
                        dest / "coder.conf")

    def replay():
        for command in commands:
            args = [command[0], f"--root={root}", *command[1:]]
            if command[0] == "systemd-tmpfiles":
                args.append("--prefix=/home/coder")
            subprocess.run(args, check=True)

    replay()
    account = next(l.split(":") for l in (root / "etc/passwd").read_text().splitlines()
                   if l.startswith("coder:"))
    home = root / "home/coder"
    assert home.stat().st_uid == int(account[2]) != 0
    assert home.stat().st_gid == int(account[3])
    assert home.stat().st_mode & 0o777 == 0o700
    (home / "state").write_text("keep")
    # A previously root-owned home must be repaired, not replaced.
    os.chown(home, 0, 0)
    replay()
    assert home.stat().st_uid == int(account[2])
    assert (home / "state").read_text() == "keep"
print("PASS: shipped post-merge order creates and repairs Coder ownership")
