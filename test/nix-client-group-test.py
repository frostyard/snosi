#!/usr/bin/env python3
"""Validate Nix client-group provisioning and Unix socket access controls."""
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parents[1]
assert os.geteuid() == 0, "run with sudo python3"
for existing in (False, True):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        root.chmod(0o755)
        (root / "etc").mkdir()
        (root / "etc/passwd").write_text("root:x:0:0::/root:/bin/sh\n")
        groups = "root:x:0:\n" + ("nix-users:x:432:\n" if existing else "")
        (root / "etc/group").write_text(groups)
        dest = root / "usr/lib/sysusers.d"
        dest.mkdir(parents=True)
        shutil.copyfile(repo / "mkosi.images/nix/mkosi.extra/usr/lib/sysusers.d/nix.conf", dest / "nix.conf")
        dest = root / "usr/lib/tmpfiles.d"
        dest.mkdir(parents=True)
        # The access rule shipped by Debian nix-setup-systemd 2.26.3+dfsg-1.
        (dest / "nix-daemon.conf").write_text("d /nix/var/nix/daemon-socket 770 root nix-users\n")
        subprocess.run(["systemd-sysusers", f"--root={root}"], check=True)
        subprocess.run(["systemd-tmpfiles", f"--root={root}", "--create", "nix-daemon.conf"], check=True)
        group = next(l.split(":") for l in (root / "etc/group").read_text().splitlines() if l.startswith("nix-users:"))
        gid = int(group[2])
        assert gid != 0 and (not existing or gid == 432)
        assert group[3] == "", "client membership must remain an administrator decision"
        directory = root / "nix/var/nix/daemon-socket"
        assert (directory.stat().st_uid, directory.stat().st_gid) == (0, gid)
        assert directory.stat().st_mode & 0o777 == 0o770
        path = str(directory / "socket")
        # Exercise filesystem access to a real Unix socket, without a host daemon.
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(path)
            os.chmod(path, 0o666)
            server.listen(2)
            client = """import os,socket,sys
os.setgroups([int(sys.argv[2])] if sys.argv[3] == 'member' else [])
os.setgid(65534)
os.setuid(65534)
with socket.socket(socket.AF_UNIX) as s:
    try: s.connect(sys.argv[1])
    except PermissionError: sys.exit(13)
"""
            for member, expected in (("member", 0), ("nonmember", 13)):
                result = subprocess.run([sys.executable, "-c", client, path, str(gid), member], check=False)
                assert result.returncode == expected, (member, result.returncode)
        before = (root / "etc/group").read_bytes()
        subprocess.run(["systemd-sysusers", f"--root={root}"], check=True)
        assert (root / "etc/group").read_bytes() == before
print("PASS: Nix client group, socket access for members, rejection of nonmembers, existing GID")
