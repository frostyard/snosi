#!/usr/bin/env python3
"""Replay the shipped post-merge sysctl command against isolated fake sysctls."""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

assert os.geteuid() == 0, "run with sudo python3"
repo = Path(__file__).resolve().parents[1]
unit = repo / "mkosi.images/base/mkosi.extra/usr/lib/systemd/system/reload-sysext.service"
command, = [shlex.split(line.split("=", 1)[1]) for line in unit.read_text().splitlines()
            if line.startswith("ExecStart=/usr/lib/systemd/systemd-sysctl")]
limits = {"fs/aio-max-nr": 16777216, "fs/inotify/max_queued_events": 1048576,
          "fs/inotify/max_user_instances": 1048576, "fs/inotify/max_user_watches": 1048576,
          "kernel/keys/maxbytes": 2000000, "kernel/keys/maxkeys": 2000}
for incus, admin in ((False, False), (True, False), (True, True)):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        for path in ("usr/lib/sysctl.d", "usr/local/lib/sysctl.d", "etc/sysctl.d", "run/sysctl.d"):
            (root / path).mkdir(parents=True)
        for key in (*limits, "kernel/apparmor_restrict_unprivileged_unconfined", "vm/max_map_count"):
            target = root / "proc-sys" / key
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("1")
        vendor = root / "usr/lib/sysctl.d"
        (vendor / "40-fixture.conf").write_text("fs.aio-max-nr=65536\n")
        if incus:
            text = "".join(f"{key.replace('/', '.')}={value}\n" for key, value in limits.items())
            text += "kernel.apparmor_restrict_unprivileged_unconfined=0\nvm.max_map_count=262144\n"
            (vendor / "50-incus.conf").write_text(text)
        if admin:
            (root / "etc/sysctl.d/90-local.conf").write_text("fs.inotify.max_user_instances=8192\n")
        script = """
set -eu
root=$1
shift
mount --bind "$root/proc-sys" /proc/sys
for path in /usr/lib/sysctl.d /etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d; do
    if [ -d "$path" ]; then
        mount --bind "$root$path" "$path"
    elif [ -e "$path" ]; then
        exit 1
    fi
done
exec "$@"
"""
        subprocess.run(["unshare", "--mount", "--propagation", "private",
                        "bash", "-c", script, "fixture", str(root), *command], check=True)
        expected = limits if incus else dict.fromkeys(limits, 1) | {"fs/aio-max-nr": 65536}
        if admin:
            expected = expected | {"fs/inotify/max_user_instances": 8192}
        for key, value in expected.items():
            assert int((root / "proc-sys" / key).read_text()) == value, key
        for key in ("kernel/apparmor_restrict_unprivileged_unconfined", "vm/max_map_count"):
            assert (root / "proc-sys" / key).read_text() == "1", key
print("PASS: post-merge limits, no-Incus behavior, admin overrides and excluded security policy")
