#!/usr/bin/env python3
"""Read-only check after fresh boot/update with the default zram policy."""
from pathlib import Path
import subprocess

subprocess.run(["systemctl", "is-active", "--quiet", "dev-zram0.swap"], check=True)
assert "/dev/zram0" in subprocess.check_output(
    ["swapon", "--noheadings", "--raw", "--show=NAME"], text=True).splitlines()
ram_kib = int(next(line.split()[1] for line in Path("/proc/meminfo").read_text().splitlines()
                   if line.startswith("MemTotal:")))
expected = int(min((ram_kib // 1024) / 2, 4096) * 1024 * 1024)
size = int(Path("/sys/block/zram0/disksize").read_text())
assert abs(size - expected) < 4096, (size, expected)
assert "[lz4]" in Path("/sys/block/zram0/comp_algorithm").read_text()
print("PASS: active zram swap, bounded size and lz4")
