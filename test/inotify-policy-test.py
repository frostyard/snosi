#!/usr/bin/env python3
"""Apply real sysctl discovery to fake kernel files in a private mount namespace."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

assert os.geteuid() == 0, "run with sudo python3"
repo = Path(__file__).resolve().parents[1]
for top in ("mkosi.images", "shared"):
    for directory in (repo / top).glob("**/usr/lib/sysctl.d"):
        invalid = [p for p in directory.iterdir() if not p.name.endswith(".conf")]
        assert not invalid, f"sysctl files must end in .conf: {invalid}"
for incus, admin, expected in ((False, False, (8192, 524288)),
                               (True, False, (1048576, 1048576)),
                               (True, True, (16384, 2097152))):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for path in ("usr/lib/sysctl.d", "usr/local/lib/sysctl.d",
                     "etc/sysctl.d", "run/sysctl.d", "proc-sys/fs/inotify"):
            (root / path).mkdir(parents=True)
        vendor = root / "usr/lib/sysctl.d"
        shutil.copyfile(repo / "mkosi.images/base/mkosi.extra/usr/lib/sysctl.d/40-snosi-inotify.conf",
                        vendor / "40-snosi-inotify.conf")
        if incus:
            (vendor / "50-incus.conf").write_text(
                "fs.inotify.max_user_instances=1048576\nfs.inotify.max_user_watches=1048576\n")
        if admin:
            (root / "etc/sysctl.d/90-local.conf").write_text(
                "fs.inotify.max_user_instances=16384\nfs.inotify.max_user_watches=2097152\n")
        for name in ("max_user_instances", "max_user_watches"):
            (root / f"proc-sys/fs/inotify/{name}").write_text("0")
        script = """
set -eu
root=$1
mount --bind "$root/proc-sys" /proc/sys
for path in /usr/lib/sysctl.d /etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d; do
    # Hide the nearest existing ancestor when a config directory is absent.
    # This happens in the private mount namespace only.
    if [ -d "$path" ]; then
        mount --bind "$root$path" "$path"
    elif [ -e "$path" ]; then
        exit 1
    fi
done
/usr/lib/systemd/systemd-sysctl --prefix=/fs/inotify
"""
        subprocess.run(["unshare", "--mount", "--propagation", "private",
                        "bash", "-c", script, "fixture", str(root)], check=True)
        actual = tuple(int((root / f"proc-sys/fs/inotify/{name}").read_text())
                       for name in ("max_user_instances", "max_user_watches"))
        assert actual == expected, (incus, admin, actual, expected)
print("PASS: discovery, base/Incus precedence and administrator overrides")
