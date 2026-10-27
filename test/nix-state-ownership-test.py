#!/usr/bin/env python3
"""Check composed base/Nix state ownership and preservation of existing data."""
import os
import re
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
assert os.geteuid() == 0, "run with sudo python3"
nix = repo / "mkosi.images/nix"
assert not (nix / "mkosi.extra/usr/lib/tmpfiles.d/nix.conf").exists()
base_names = {f.name for f in (repo / "mkosi.images/base/mkosi.extra/usr/lib/tmpfiles.d").iterdir()}
sysext_names = {f.name for f in (nix / "mkosi.extra/usr/lib/tmpfiles.d").iterdir()}
assert not base_names & sysext_names, f"mkosi drops sysext files that base ships: {base_names & sysext_names}"
assert "/usr/lib/tmpfiles.d/nix-sysext.conf" in (nix / "required-paths.txt").read_text().splitlines()
# snosi#1164: tmpfiles runs before nix.mount, so no rule may target /nix.
for conf in (nix / "mkosi.extra/usr/lib/tmpfiles.d").iterdir():
    for line in conf.read_text().splitlines():
        fields = line.split()
        if fields and not fields[0].startswith("#"):
            assert not re.match(r"/nix(/|$)", fields[1]), f"{conf.name}: rule targets /nix: {line}"
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    (root / "etc").mkdir()
    (root / "etc/passwd").write_text("root:x:0:0::/root:/bin/sh\n")
    (root / "etc/group").write_text("root:x:0:\n")
    for source in (repo / "mkosi.images/base/mkosi.extra/usr/lib/tmpfiles.d/nix.conf",
                   nix / "mkosi.extra/usr/lib/tmpfiles.d/nix-sysext.conf",
                   nix / "mkosi.extra/usr/lib/sysusers.d/nix.conf"):
        relative = str(source).split("mkosi.extra/", 1)[1]
        dest = root / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, dest)
    factory = root / "usr/share/factory/etc/nix"
    factory.mkdir(parents=True)
    (factory / "nix.conf").write_text("build-users-group = nixbld\n")
    subprocess.run(["systemd-sysusers", f"--root={root}"], check=True)
    subprocess.run(["systemd-tmpfiles", f"--root={root}", "--create"], check=True)
    store = root / "var/lib/nix/store"
    assert (store.stat().st_uid, store.stat().st_gid) == (0, 30000)
    assert store.stat().st_mode & 0o7777 == 0o1775
    backing = root / "var/lib/nix"
    assert (backing.stat().st_uid, backing.stat().st_gid) == (0, 0)
    assert (root / "etc/nix/nix.conf").read_text() == "build-users-group = nixbld\n"
    nix_users_gid = next(int(l.split(":")[2]) for l in (root / "etc/group").read_text().splitlines()
                         if l.startswith("nix-users:"))
    for rel, mode, gid in (("daemon-socket", 0o770, nix_users_gid), ("gcroots/per-user", 0o1777, 0),
                           ("profiles/per-user", 0o1777, 0)):
        directory = root / "var/lib/nix/var/nix" / rel
        assert directory.is_dir(), rel
        assert directory.stat().st_mode & 0o7777 == mode, (rel, oct(directory.stat().st_mode))
        assert (directory.stat().st_uid, directory.stat().st_gid) == (0, gid), rel
    assert not (root / "nix").exists(), "tmpfiles must not touch /nix"
    item = store / "existing-output"
    item.write_text("retain store contents")
    item.chmod(0o444)
    (root / "etc/nix/nix.conf").write_text("local administrator config\n")
    subprocess.run(["systemd-tmpfiles", f"--root={root}", "--create"], check=True)
    assert item.read_text() == "retain store contents" and item.stat().st_mode & 0o777 == 0o444
    assert (root / "etc/nix/nix.conf").read_text() == "local administrator config\n"
# mkosi.finalize: it deletes Debian's unchanged nix-daemon.conf, and fails on a
# changed Debian file or on any system tmpfiles rule that targets /nix.
DEBIAN = ("#Type Path        Mode User Group Age Argument\n"
          "d     /nix/var/nix/daemon-socket 770 root nix-users\n"
          "e!    /nix/var/nix/daemon-socket - - - 0\n"
          "d     /nix/var/nix/gcroots/per-user 1777\n"
          "d     /nix/var/nix/profiles/per-user 1777\n")
for debian, extra, ok in ((DEBIAN, None, True),
                          (DEBIAN.replace("770", "775"), None, False),
                          (DEBIAN, "d /nix/var/nix/other 0755 - - -\n", False)):
    with tempfile.TemporaryDirectory() as tmp:
        tmpfiles = Path(tmp) / "usr/lib/tmpfiles.d"
        tmpfiles.mkdir(parents=True)
        (tmpfiles / "nix-daemon.conf").write_text(debian)
        if extra:
            (tmpfiles / "other.conf").write_text(extra)
        result = subprocess.run([str(nix / "mkosi.finalize")], env={**os.environ, "BUILDROOT": tmp},
                                capture_output=True, text=True)
        assert (result.returncode == 0) == ok, (debian, extra, result.stderr)
        if ok:
            assert not (tmpfiles / "nix-daemon.conf").exists(), "finalize must delete Debian's nix-daemon.conf"
print("PASS: root-owned multi-user store, socket and per-user dirs on /var/lib/nix, finalize rule check, retained outputs and local settings")
