#!/usr/bin/env python3
"""Read-only comparison of running binaries, frozen inventory and dpkg queries."""
from pathlib import Path
import re
import subprocess

release = dict(line.split("=", 1) for line in Path("/usr/lib/os-release").read_text().splitlines()
               if "=" in line and not line.startswith("#"))
image = release["IMAGE_ID"].strip('"')
inventory = {}
for line in Path(f"/usr/share/frostyard/{image}.packages.txt").read_text().splitlines():
    fields = line.split()
    if len(fields) >= 2 and "/" in fields[0]:
        inventory[fields[0].split("/", 1)[0]] = fields[1]
for package in ("systemd", "bootc", "frostyard-updex"):
    queried = subprocess.check_output(
        ["dpkg-query", "-W", "-f=${Version}", package], text=True)
    assert queried == inventory[package], (package, queried, inventory[package])
systemd = subprocess.check_output(["systemctl", "--version"], text=True).split()[1]
assert re.match(r"^(?:[0-9]+:)?"+re.escape(systemd)+r"(?:[.+~-]|$)",
                inventory["systemd"]), (systemd, inventory["systemd"])
bootc = subprocess.check_output(["bootc", "--version"], text=True).split()[1]
assert re.match(r"^(?:[0-9]+:)?"+re.escape(bootc)+r"(?:[.+~-]|$)",
                inventory["bootc"]), (bootc, inventory["bootc"])
print("PASS: binaries, frozen inventory and supported package-query interface agree")
