#!/usr/bin/env python3
"""Fresh/upgrade/mask/custom-link/idempotence fixtures without a user manager."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
script = repo / "mkosi.images/base/mkosi.extra/usr/libexec/podman-socket-policy"
for state in ("fresh", "upgrade", "masked", "custom", "override", "legacy"):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        user = root / "etc/systemd/user"
        wants = user / "default.target.wants"
        wants.mkdir(parents=True)
        (root / "var/lib").mkdir(parents=True)
        if state != "legacy":
            (root / "var/lib/preset-enablement.done").write_text("first-boot\n")
        manifest = root / "usr/share/snosi/enablement-manifest.txt"
        manifest.parent.mkdir(parents=True)
        manifest.write_text("user sockets.target.wants/podman.socket\n")
        link = wants / "podman.service"
        if state in ("upgrade", "masked", "override", "legacy"):
            link.symlink_to("/usr/lib/systemd/user/podman.service")
        if state == "custom":
            link.symlink_to("/etc/systemd/user/custom-api.service")
        if state == "override":
            (user / "podman.service").write_text("[Service]\nExecStart=/custom/api\n")
        if state == "masked":
            (user / "podman.service").symlink_to("/dev/null")
        # A disabled socket stays disabled; unrelated enablement survives.
        unrelated = wants / "keep.service"
        unrelated.symlink_to("/usr/lib/systemd/user/keep.service")
        subprocess.run([str(script), str(root)], check=True)
        assert link.is_symlink() == (state in ("custom", "override", "legacy")), state
        assert unrelated.is_symlink()
        assert not (user / "sockets.target.wants/podman.socket").exists()
        if state == "masked":
            assert (user / "podman.service").readlink() == Path("/dev/null")
        # A deliberate later administrator re-enable is not removed.
        if not link.is_symlink():
            link.symlink_to("/usr/lib/systemd/user/podman.service")
        subprocess.run([str(script), str(root)], check=True)
        assert link.is_symlink()
print("PASS: upgrade removes only old policy; masks, opt-outs and admin choices survive")
