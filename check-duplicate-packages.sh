#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
guard_root=${SNOSI_DUPLICATE_PACKAGES_GUARD_ROOT:-$script_dir}
cd "$guard_root"

python3 - <<'PY'
from collections import defaultdict
from pathlib import Path
import subprocess
import sys

# mkosi accumulates list settings, so a package named twice in one file is a
# mistake. The suite-matched fragments (ADR-0037) are separate files, and the
# same package may legitimately appear in the trixie one and the forky one, so
# each file is still checked on its own.
patterns = [
    "**/mkosi.conf",
    "**/mkosi.conf.d/*.conf",
    "shared/suite/*.conf",
    "shared/suite/*/*.conf",
    "shared/kernel/backports/*.conf",
    # every other suite fragment that a shared mkosi.conf includes
    "**/trixie.conf",
    "**/forky.conf",
]
# -co: an untracked fragment is checked before it is committed.
found = subprocess.check_output(
    ["git", "ls-files", "-co", "--exclude-standard", "--", *patterns], text=True
)
files = sorted(
    {
        f
        for f in found.splitlines()
        if not f.startswith("saved-unused/") and Path(f).is_file()
    }
)

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

print(f"No duplicate package entries found in {len(files)} mkosi package files.")
PY
