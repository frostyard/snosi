#!/usr/bin/env python3
"""Use real dpkg tools in isolated roots across install, two updates and rollback."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

assert os.geteuid() == 0, "run with sudo python3"
repo = Path(__file__).resolve().parents[1]

def install_binary(root, source, target=None):
    dest = root / (target or source).lstrip("/")
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, dest)
    libraries = subprocess.check_output(["ldd", source], text=True)
    for lib in re.findall(r"/[^\s()]+", libraries):
        dest = root / lib.lstrip("/")
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(lib, dest)

def status(version):
    return ("Package: fixture\nStatus: install ok installed\nArchitecture: amd64\n"
            f"Version: {version}\nMaintainer: Fixture <fixture@example.invalid>\n"
            "Description: metadata fixture\n")

with tempfile.TemporaryDirectory() as tmp:
    roots = []
    for version in ("1.0", "2.0", "3.0"):
        root = Path(tmp) / version
        for binary in ("/usr/bin/dpkg-query", "/usr/bin/dpkg", "/usr/bin/update-alternatives"):
            install_binary(root, binary)
        install_binary(root, "/bin/sh")
        (root / "dev").mkdir()
        (root / "dev/null").touch()
        db = root / "var/lib/dpkg"
        db.mkdir(parents=True)
        (db / "status").write_text(status(version))
        (db / "info").mkdir()
        (db / "info/fixture.list").write_text("/usr/bin/fixture\n")
        inventory = root / "usr/share/frostyard/snow.packages.txt"
        inventory.parent.mkdir(parents=True)
        inventory.write_text(f"Listing...\nfixture/now {version} amd64 [installed,local]\n")
        # Set an actual alternatives choice in the future persistent database.
        for editor in ("vim", "nano"):
            target = root / f"usr/bin/{editor}"
            target.write_text("#!/bin/sh\nexit 0\n")
            target.chmod(0o755)
        (root / "etc/alternatives").mkdir(parents=True)
        (root / "var/log").mkdir()
        for editor, priority in (("vim", "10"), ("nano", "20")):
            subprocess.run(["chroot", str(root), "/usr/bin/update-alternatives",
                            "--install", "/usr/bin/editor", "editor", f"/usr/bin/{editor}",
                            priority], check=True, capture_output=True)
        subprocess.run(["chroot", str(root), "/usr/bin/update-alternatives",
                        "--set", "editor", "/usr/bin/vim"], check=True, capture_output=True)
        alternatives = (db / "alternatives/editor").read_bytes()
        subprocess.run([str(repo / "shared/outformat/image/finalize/package-metadata.finalize")],
                       env=dict(os.environ, BUILDROOT=str(root), SRCDIR=str(repo)), check=True)
        assert inventory.read_text() == f"Listing...\nfixture/now {version} amd64 [installed,local]\n"
        assert (db / "alternatives/editor").read_bytes() == alternatives
        # Simulate the same stale persistent /var database surviving every update.
        (db / "status").write_text(status("0.9"))
        roots.append(root)
    for root in (*roots, roots[0]):
        def query(*args, env=None):
            return subprocess.check_output(["chroot", str(root), *args],
                                           text=True, env=env)
        assert query("/usr/bin/dpkg-query", "-W", "-f=${Version}", "fixture") == root.name
        assert f"Version: {root.name}" in query("/usr/bin/dpkg", "--status", "fixture")
        assert root.name in query("/usr/bin/dpkg", "-l", "fixture")
        assert "/usr/bin/fixture" in query("/usr/bin/dpkg-query", "-L", "fixture")
        assert "Value: /usr/bin/vim" in query("/usr/bin/update-alternatives", "--query", "editor")
        assert query("/usr/bin/dpkg-query", "--admindir=/var/lib/dpkg",
                     "-W", "-f=${Version}", "fixture") == "0.9"
        assert query("/usr/bin/dpkg-query", "--root=/", "-W", "-f=${Version}",
                     "fixture") == "0.9"
        assert query("/usr/bin/dpkg-query", "-W", "-f=${Version}", "fixture",
                     env=dict(os.environ, DPKG_ADMINDIR="/var/lib/dpkg")) == "0.9"
        assert query("/usr/bin/dpkg-query", "-W", "-f=${Version}", "fixture",
                     env=dict(os.environ, DPKG_ROOT="/")) == "0.9"
        assert (root / "var/lib/dpkg/status").read_text() == status("0.9")
print("PASS: fresh image, two updates, rollback, explicit overrides, alternatives and inventory")
