#!/usr/bin/env python3
"""Read-only comparison of package links, dpkg, apt, inventory and binaries."""
import os
from pathlib import Path
import re
import subprocess


def query(*args):
    return subprocess.check_output(args, text=True, env=dict(os.environ, LC_ALL="C"))


def apt_inventory(text):
    result = {}
    for line in text.splitlines():
        fields = line.split()
        if len(fields) >= 3 and "/" in fields[0]:
            name = fields[0].split("/", 1)[0].split(":", 1)[0]
            result[name, fields[2]] = fields[1]
    assert result, "empty package inventory"
    return result


db = Path("/var/lib/dpkg")
assert db.is_dir() and not db.is_symlink()
for name in ("status", "info", "triggers", "diversions", "available", "arch-native"):
    path = db / name
    assert path.is_symlink() and os.readlink(path) == f"/usr/lib/sysimage/dpkg/{name}", path
    assert path.exists(), f"dangling package metadata link: {path}"
for name in ("alternatives", "statoverride", "lock", "lock-frontend", "updates", "parts"):
    assert not (db / name).is_symlink(), name
release = dict(line.split("=", 1) for line in Path("/usr/lib/os-release").read_text().splitlines()
               if "=" in line and not line.startswith("#"))
image = release["IMAGE_ID"].strip('"')
inventory = apt_inventory(Path(f"/usr/share/frostyard/{image}.packages.txt").read_text())
queried = {}
for line in query("dpkg-query", "-W", "-f=${Package}\t${Architecture}\t${Version}\t${db:Status-Status}\n").splitlines():
    name, arch, version, state = line.split("\t")
    if state == "installed":
        queried[name.split(":", 1)[0], arch] = version
assert queried == inventory, ("dpkg/inventory mismatch", queried.items() ^ inventory.items())
listed = apt_inventory(query("apt", "list", "--installed"))
assert listed == inventory, ("apt/inventory mismatch", listed.items() ^ inventory.items())
for package in ("systemd", "bootc", "frostyard-updex"):
    version = query("dpkg-query", "-W", "-f=${Version}", package)
    assert f"Installed: {version}" in query("apt-cache", "policy", package), package
systemd = query("systemctl", "--version").split()[1]
assert re.match(r"^(?:[0-9]+:)?" + re.escape(systemd) + r"(?:[.+~-]|$)",
                query("dpkg-query", "-W", "-f=${Version}", "systemd")), systemd
bootc = query("bootc", "--version").split()[1]
assert re.match(r"^(?:[0-9]+:)?" + re.escape(bootc) + r"(?:[.+~-]|$)",
                query("dpkg-query", "-W", "-f=${Version}", "bootc")), bootc
print(f"PASS: package links, all {len(inventory)} packages in dpkg/apt/inventory, and binaries agree")
