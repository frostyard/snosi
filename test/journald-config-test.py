#!/usr/bin/env python3
"""Check vendor discovery, admin precedence and misplaced daemon drop-ins."""
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
for tree in (repo / "mkosi.images", repo / "shared"):
    misplaced = list(tree.glob("**/usr/lib/systemd/system/*.conf.d"))
    # Empty directories can remain in a developer checkout after a move.
    assert not [p for p in misplaced if any(p.iterdir())], misplaced
source = repo / "mkosi.images/base/mkosi.extra/usr/lib/systemd/journald.conf.d/10-snosi-persistent.conf"
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    vendor = root / "usr/lib/systemd/journald.conf.d"
    vendor.mkdir(parents=True)
    shutil.copy(source, vendor / source.name)
    def effective():
        return subprocess.check_output(
            ["systemd-analyze", f"--root={root}", "cat-config", "systemd/journald.conf"],
            text=True)
    output = effective()
    assert "/usr/lib/systemd/journald.conf.d/" in output and "Storage=persistent" in output
    admin = root / "etc/systemd/journald.conf.d"
    admin.mkdir(parents=True)
    (admin / source.name).write_text("[Journal]\nStorage=volatile\n")
    output = effective()
    assert "Storage=volatile" in output and "Storage=persistent" not in output
print("PASS: journald vendor discovery and administrator override precedence")
