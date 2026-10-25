#!/usr/bin/env python3
"""Exercise the real generator with synthetic RAM and no host devices."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
generator = "/usr/lib/systemd/system-generators/zram-generator"
for ram, size in ((256, 128), (65536, 4096)):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        config = root / "usr/lib/systemd/zram-generator.conf"
        config.parent.mkdir(parents=True)
        shutil.copyfile(repo / "mkosi.images/base/mkosi.extra/usr/lib/systemd/zram-generator.conf", config)
        (root / "proc").mkdir()
        (root / "proc/meminfo").write_text(f"MemTotal: {ram * 1024} kB\n")
        (root / "proc/cmdline").write_text("")
        # Even generator fake mode may try modprobe for a compression module.
        # Keep all module loading inside this fixture, never on the host.
        bindir = root / "bin"
        bindir.mkdir()
        (bindir / "modprobe").write_text("#!/bin/sh\nexit 0\n")
        (bindir / "modprobe").chmod(0o755)
        env = dict(os.environ, ZRAM_GENERATOR_ROOT=str(root),
                   PATH=f"{bindir}:{os.environ['PATH']}")
        output = root / "generated"
        output.mkdir()
        result = subprocess.run([generator, str(output)], env=env,
                                capture_output=True, text=True, check=True)
        assert (output / "dev-zram0.swap").exists(), result.stderr
        log = result.stdout + result.stderr
        assert f"with {size}MB" in log, log
        # Existing administrator configuration wins over the vendor default.
        (root / "etc/systemd").mkdir(parents=True)
        (root / "etc/systemd/zram-generator.conf").write_text("")
        disabled = root / "disabled"
        disabled.mkdir()
        subprocess.run([generator, str(disabled)], env=env,
                       capture_output=True, text=True, check=True)
        assert not (disabled / "dev-zram0.swap").exists()
print("PASS: generator, low/high RAM size bounds and administrator opt-out")
