#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

python3 - <<'PY'
from collections import defaultdict
from pathlib import Path
import subprocess
import sys

files = subprocess.check_output(
    ["git", "ls-files", "**/mkosi.conf"], text=True
).splitlines()
files = [f for f in files if not f.startswith("saved-unused/")]

has_duplicates = False

for rel_path in files:
    path = Path(rel_path)
    lines = path.read_text().splitlines()

    package_lines = defaultdict(list)
    in_packages = False

    for idx, raw in enumerate(lines, start=1):
        stripped = raw.strip()

        if not stripped or raw.lstrip().startswith("#"):
            continue

        entry = None
        if raw.startswith("Packages="):
            in_packages = True
            entry = raw.split("=", 1)[1]
        elif in_packages and (raw.startswith(" ") or raw.startswith("\t")):
            entry = raw
        else:
            in_packages = False

        if entry is None:
            continue

        pkg = entry.split("#", 1)[0].strip()
        if pkg:
            package_lines[pkg].append(idx)

    duplicates = {pkg: locs for pkg, locs in package_lines.items() if len(locs) > 1}
    if duplicates:
        has_duplicates = True
        print(f"Duplicate package entries in {rel_path}:")
        for pkg, locs in sorted(duplicates.items()):
            locs_str = ", ".join(str(n) for n in locs)
            print(f"  - {pkg}: lines {locs_str}")

if has_duplicates:
    sys.exit(1)

print("No duplicate package entries found in mkosi.conf files.")
PY
