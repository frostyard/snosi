#!/usr/bin/env python3
"""Real tmpfiles, dpkg and apt across fresh install, updates and rollback.

All mutations are confined to temporary chroots; no host database is changed.
"""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

assert os.geteuid() == 0, "run with sudo python3"
repo = Path(__file__).resolve().parents[1]
identity = ("status", "info", "triggers", "diversions", "available", "arch-native")
rule = "usr/lib/tmpfiles.d/dpkg.conf"
# Products inherit the base rule until the finalizer replaces it. A product
# tree copy would be silently overwritten and must not become a second owner.
product_rules = sorted((repo / "shared").glob(f"**/tree/{rule}"))
assert not product_rules, f"product trees must inherit the base dpkg.conf: {product_rules}"
env = dict(os.environ, LC_ALL="C")
for name in ("DPKG_ROOT", "DPKG_ADMINDIR", "APT_CONFIG"):
    env.pop(name, None)


def install_binary(root, source):
    dest = root / source.lstrip("/")
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, dest)
    libraries = subprocess.check_output(["ldd", source], text=True)
    for lib in re.findall(r"/[^\s()]+", libraries):
        dest = root / lib.lstrip("/")
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(lib, dest)


def query(root, *args):
    result = subprocess.run(["chroot", str(root), *args], text=True,
                            env=env, capture_output=True)
    assert result.returncode == 0, (args, result.stdout, result.stderr)
    return result.stdout


def status(version):
    return ("Package: fixture\nStatus: install ok installed\nArchitecture: amd64\n"
            f"Version: {version}\nMaintainer: Fixture <fixture@example.invalid>\n"
            "Description: metadata fixture\n\n"
            "Package: dpkg\nStatus: install ok installed\nArchitecture: amd64\n"
            "Version: 1.0\nMaintainer: Fixture <fixture@example.invalid>\n"
            "Description: query binary integrity fixture\n")


def apply_links(root):
    result = subprocess.run(["systemd-tmpfiles", f"--root={root}", "--create", "dpkg.conf"],
                            text=True, capture_output=True)
    assert result.returncode == 0, result.stderr
    db = root / "var/lib/dpkg"
    assert db.is_dir() and not db.is_symlink()
    for name in identity:
        assert (db / name).is_symlink(), name
        assert os.readlink(db / name) == f"/usr/lib/sysimage/dpkg/{name}"
    for name in ("alternatives", "statoverride", "lock", "lock-frontend", "updates", "parts"):
        assert not (db / name).is_symlink(), name


def check_queries(root, version):
    assert query(root, "/usr/bin/dpkg-query", "-W", "-f=${Version}", "fixture") == version
    assert f"Version: {version}" in query(root, "/usr/bin/dpkg", "-s", "fixture")
    assert version in query(root, "/usr/bin/dpkg", "-l", "fixture")
    assert "/usr/bin/fixture" in query(root, "/usr/bin/dpkg", "-L", "fixture")
    assert "fixture: /usr/bin/fixture" in query(root, "/usr/bin/dpkg", "-S", "/usr/bin/fixture")
    assert query(root, "/usr/bin/dpkg", "--verify", "fixture", "dpkg") == ""
    assert f"fixture/now {version} amd64 [installed,local]" in query(
        root, "/usr/bin/apt", "list", "--installed", "fixture")
    for tool in ("apt", "apt-cache"):
        assert f"Installed: {version}" in query(root, f"/usr/bin/{tool}", "policy", "fixture")
    assert f"Version: {version}" in query(root, "/usr/bin/apt-cache", "show", "fixture")
    # The same direct path used by libapt, PackageKit and file scanners.
    assert query(root, "/usr/bin/cat", "/var/lib/dpkg/status") == status(version)
    inventory = root / "usr/share/frostyard/snow.packages.txt"
    assert inventory.read_text() == f"Listing...\nfixture/now {version} amd64 [installed,local]\n"


def make_image(root, version):
    for binary in ("dpkg-query", "dpkg", "dpkg-divert", "update-alternatives", "apt", "apt-cache", "cat"):
        install_binary(root, f"/usr/bin/{binary}")
    install_binary(root, "/bin/sh")
    shutil.copytree("/usr/share/dpkg", root / "usr/share/dpkg")
    for directory in ("dev", "etc/alternatives", "etc/apt/apt.conf.d", "etc/apt/sources.list.d",
                      "var/log/apt", "var/cache/apt/archives/partial", "var/lib/apt/lists/partial",
                      "var/lib/dpkg/info", "var/lib/dpkg/triggers", "var/lib/dpkg/alternatives",
                      "var/lib/dpkg/updates", "var/lib/dpkg/parts", "usr/lib/tmpfiles.d"):
        (root / directory).mkdir(parents=True, exist_ok=True)
    (root / "dev/null").touch()
    (root / "etc/passwd").write_text("root:x:0:0:root:/root:/bin/sh\n")
    (root / "etc/group").write_text("root:x:0:\n")
    db = root / "var/lib/dpkg"
    (db / "status").write_text(status(version))
    # Model distinct image build times: libapt cache validity uses mtime/size.
    built_at = 1700000000 + int(version.split(".")[0]) * 86400
    os.utime(db / "status", (built_at, built_at))
    for name in ("available", "diversions", "lock", "lock-frontend", "triggers/Lock", "triggers/Unincorp"):
        (db / name).touch()
    (db / "arch-native").write_text("amd64\n")
    (db / "statoverride").write_text("root root 0644 /usr/bin/fixture\n")
    (root / "usr/bin/fixture").write_text(version)
    for package, binary in (("fixture", "fixture"), ("dpkg", "dpkg-query")):
        (db / f"info/{package}.list").write_text(f"/usr/bin/{binary}\n")
        digest = hashlib.md5((root / f"usr/bin/{binary}").read_bytes()).hexdigest()
        (db / f"info/{package}.md5sums").write_text(f"{digest}  usr/bin/{binary}\n")
    for editor in ("vim", "nano", "micro"):
        target = root / f"usr/bin/{editor}"
        target.write_text("#!/bin/sh\nexit 0\n")
        target.chmod(0o755)
    inventory = root / "usr/share/frostyard/snow.packages.txt"
    inventory.parent.mkdir(parents=True)
    inventory.write_text(f"Listing...\nfixture/now {version} amd64 [installed,local]\n")
    shutil.copy2(repo / "mkosi.images/base/mkosi.extra" / rule, root / rule)
    # mkosi's automatic tmpfiles pass precedes finalizers, including in the
    # reusable base. It must leave the normal package database usable.
    subprocess.run(["systemd-tmpfiles", f"--root={root}", "--boot", "--create", "dpkg.conf"],
                   check=True, capture_output=True)
    assert not (db / "info").is_symlink()
    assert (db / "status").read_text() == status(version)
    assert query(root, "/usr/bin/dpkg-query", "-W", "-f=${Version}", "fixture") == version
    before = (root / "usr/bin/dpkg-query").read_bytes()
    subprocess.run([str(repo / "shared/outformat/image/finalize/package-metadata.finalize")],
                   env=dict(env, BUILDROOT=str(root), SRCDIR=str(repo)), check=True)
    assert (root / "usr/bin/dpkg-query").read_bytes() == before
    assert not (root / "usr/libexec/snosi/dpkg-query").exists()
    assert not (root / "etc/dpkg/dpkg.cfg.d/00-snosi-image").exists()
    assert (db / "status").read_text() == status(version)
    assert not (db / "info").is_symlink(), "build root must remain writable"
    return root


with tempfile.TemporaryDirectory() as tmp:
    work = Path(tmp)
    images = [make_image(work / version, version) for version in ("1.0", "2.0", "3.0")]
    fresh = work / "fresh"
    shutil.copytree(images[0], fresh, symlinks=True)
    shutil.rmtree(fresh / "var/lib/dpkg")
    apply_links(fresh)
    apply_links(fresh)
    check_queries(fresh, "1.0")
    print("PASS: fresh /var, repeated tmpfiles, apt/dpkg/direct readers and binary integrity")

    live = work / "existing"
    shutil.copytree(images[0], live, symlinks=True)
    db = live / "var/lib/dpkg"
    (db / "status").write_text(status("0.9"))
    (db / "info/stale.list").write_text("/stale\n")
    (db / "triggers/stale").touch()
    # Install and select an actual manual alternative after the image snapshot.
    for editor, priority in (("vim", "10"), ("nano", "20")):
        query(live, "/usr/bin/update-alternatives", "--install", "/usr/bin/editor",
              "editor", f"/usr/bin/{editor}", priority)
    query(live, "/usr/bin/update-alternatives", "--set", "editor", "/usr/bin/vim")
    mutable_files = {name: (db / name).read_bytes()
                     for name in ("statoverride", "lock", "lock-frontend")}
    mutable_inodes = {name: (db / name).stat().st_ino
                      for name in (*mutable_files, "alternatives", "updates", "parts")}
    selected = "vim"
    for image in (*images, images[0]):
        # Switch only deployment-owned data, carrying the very same /var and
        # /etc alternatives state across two updates and a rollback.
        snapshot = live / "usr/lib/sysimage/dpkg"
        shutil.rmtree(snapshot)
        shutil.copytree(image / "usr/lib/sysimage/dpkg", snapshot, symlinks=True)
        shutil.copy2(image / "usr/bin/fixture", live / "usr/bin/fixture")
        shutil.copy2(image / "usr/share/frostyard/snow.packages.txt",
                     live / "usr/share/frostyard/snow.packages.txt")
        before = (db / "alternatives/editor").read_bytes()
        apply_links(live)
        apply_links(live)
        assert (db / "alternatives/editor").read_bytes() == before
        check_queries(live, image.name)
        assert f"Value: /usr/bin/{selected}" in query(
            live, "/usr/bin/update-alternatives", "--query", "editor")
        for name, contents in mutable_files.items():
            assert (db / name).read_bytes() == contents, name
        for name, inode in mutable_inodes.items():
            assert (db / name).stat().st_ino == inode, name
        # Alternatives remains writable after conversion; carry the new choice.
        query(live, "/usr/bin/update-alternatives", "--set", "editor", "/usr/bin/nano")
        query(live, "/usr/bin/update-alternatives", "--install", "/usr/bin/editor",
              "editor", "/usr/bin/micro", "30")
        choice = query(live, "/usr/bin/update-alternatives", "--query", "editor")
        assert "Status: manual" in choice and "Alternative: /usr/bin/micro" in choice
        assert "Value: /usr/bin/nano" in choice
        selected = "nano"
        print(f"PASS: deployment {image.name}, preserved writable state and manual alternatives")

    query(live, "/usr/bin/dpkg-divert", "--add", "--no-rename", "/usr/bin/fixture")
    assert not (db / "diversions").is_symlink()
    assert "/usr/bin/fixture" in (db / "diversions").read_text()
    apply_links(live)
    assert query(live, "/usr/bin/dpkg-divert", "--list") == ""
    print("PASS: unsupported local diversion is replaced by the next tmpfiles run")

    # This private namespace exits after the check; no host mounts are changed.
    result = subprocess.run([
        "unshare", "--mount", "--propagation", "private", "sh", "-eu", "-c",
        'mount --bind "$1" "$1"; mount -o remount,bind,ro "$1"; chroot "$2" /usr/bin/dpkg --configure -a',
        "fixture", str(snapshot), str(live)], text=True, capture_output=True, env=env)
    assert result.returncode != 0 and "Read-only file system" in result.stderr, result.stderr
    print("PASS: dpkg configuration fails on read-only deployment metadata")

    # A pre-fix rollback has no snapshot. Capture the documented transition
    # limitation, then prove rolling forward restores ordinary queries.
    old_snapshot = work / "saved-snapshot"
    snapshot.rename(old_snapshot)
    result = subprocess.run(["chroot", str(live), "dpkg-query", "-W", "fixture"],
                            text=True, capture_output=True, env=env)
    assert result.returncode != 0 and "no packages found" in result.stderr, result.stderr
    assert "fixture/" not in query(live, "/usr/bin/apt", "list", "--installed")
    old_snapshot.rename(snapshot)
    check_queries(live, "1.0")
    print("PASS: pre-fix rollback caveat and roll-forward recovery")
