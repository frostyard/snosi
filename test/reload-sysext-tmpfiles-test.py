#!/usr/bin/env python3
"""A failing tmpfiles rule must not stop reload-sysext.service before daemon-reload."""
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import tempfile

assert os.geteuid() == 0, "run with sudo python3"
repo = Path(__file__).resolve().parents[1]
unit = repo / "mkosi.images/base/mkosi.extra/usr/lib/systemd/system/reload-sysext.service"
PREFIXES = "-@:+!"
text = unit.read_text()
assert "SuccessExitStatus=" not in text
service = text.split("[Service]", 1)[1].split("[Install]", 1)[0]
exec_lines = [l.split("=", 1)[1] for l in service.splitlines() if l.startswith("ExecStart=")]
cmds = [shlex.split(l.lstrip(PREFIXES)) for l in exec_lines]
prefixes = [l[:len(l) - len(l.lstrip(PREFIXES))] for l in exec_lines]
# a. Static shape: only the tmpfiles line is failure-tolerant, daemon-reload is last.
assert len(cmds) == 4, cmds
assert [Path(c[0]).name for c in cmds] == [
    "systemd-sysusers", "systemd-tmpfiles", "systemd-sysctl", "systemctl"], cmds
assert cmds[3][1:] == ["daemon-reload"], cmds[3]
assert prefixes == ["", "-", "", ""], prefixes
tmpfiles = cmds[1]


def fixture_root(tmp):
    root = Path(tmp) / "root"
    rules = root / "usr/lib/tmpfiles.d"
    rules.mkdir(parents=True)
    (root / "blocked").write_text("regular file\n")
    (rules / "10-bad.conf").write_text("d /blocked/sub/deep 0755 - - -\n")
    (rules / "20-good.conf").write_text("d /var/lib/good 0755 - - -\n")
    return root


with tempfile.TemporaryDirectory() as tmp:
    root = fixture_root(tmp)
    # b. The real tmpfiles command exits nonzero but continues past the bad rule.
    args = [tmpfiles[0], f"--root={root}", *tmpfiles[1:]]
    result = subprocess.run(args, capture_output=True, text=True)
    assert result.returncode in (65, 73), (result.returncode, result.stderr)
    assert (root / "var/lib/good").is_dir(), "tmpfiles stopped at the bad rule"
    assert "/blocked/sub" in result.stderr, result.stderr
    (root / "var/lib/good").rmdir()

    # c. Real systemd semantics, with a negative control without the "-".
    assert Path("/run/systemd/system").exists(), "systemd must be PID 1"
    marker = Path(tmp) / "reloaded"
    replaced = ["/bin/true", args, "/bin/true", ["/usr/bin/touch", str(marker)]]
    lines = ["ExecStart=" + p + shlex.join(c if isinstance(c, list) else [c])
             for p, c in zip(prefixes, replaced)]
    # Keep the shipped [Service] settings (Type=, RemainAfterExit=, ...).
    settings = [l for l in service.splitlines()
                if l.strip() and not l.startswith(("#", "ExecStart="))]
    assert "Type=oneshot" in settings, settings
    token = secrets.token_hex(4)

    def fixture(name, tolerant):
        body = "\n".join(l if tolerant or not l.startswith("ExecStart=-")
                         else "ExecStart=" + l[len("ExecStart=-"):] for l in lines)
        path = Path(f"/run/systemd/system/{name}.service")
        path.write_text("[Service]\n" + "\n".join(settings) + f"\n{body}\n")
        return path

    good = fixture(f"snosi-test-reload-sysext-{token}", True)
    bad = fixture(f"snosi-test-reload-sysext-strict-{token}", False)
    try:
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        subprocess.run(["systemctl", "start", good.name], check=True)
        assert marker.exists(), "daemon-reload line did not run"
        state = subprocess.run(["systemctl", "is-active", good.name],
                               capture_output=True, text=True)
        assert state.stdout.strip() == "active", state.stdout
        marker.unlink()
        failed = subprocess.run(["systemctl", "start", bad.name])
        assert failed.returncode != 0, "negative control must fail"
        assert not marker.exists(), "negative control ran daemon-reload"
    finally:
        for path in (good, bad):
            subprocess.run(["systemctl", "stop", path.name], check=False)
            subprocess.run(["systemctl", "reset-failed", path.name], check=False,
                           stderr=subprocess.DEVNULL)
            path.unlink(missing_ok=True)
        subprocess.run(["systemctl", "daemon-reload"], check=False)
print("PASS: a failing tmpfiles rule keeps sysctl and daemon-reload in reload-sysext.service")
