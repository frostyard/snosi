#!/usr/bin/env python3
"""Real user-manager activation with temporary storage/runtime; no host enablement changes."""
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

with tempfile.TemporaryDirectory(prefix="snosi-podman-") as tmp:
    root = Path(tmp)
    runtime = root / "runtime"
    runtime.mkdir(mode=0o700)
    name = "snosi-podman-test-" + uuid.uuid4().hex[:8]
    podman = ["/usr/bin/podman", "--root=" + str(root / "storage"),
              "--runroot=" + str(root / "run"), "--storage-driver=vfs",
              "--events-backend=file"]
    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime))
    subprocess.run([
        "systemd-run", "--user", "--unit=" + name, "--collect",
        "--property=Delegate=yes", "--property=Type=exec",
        "--property=KillMode=process", "--setenv=XDG_RUNTIME_DIR=" + str(runtime),
        "--socket-property=ListenStream=" + str(root / "api.sock"),
        *podman, "system", "service", "--time=3"], check=True)
    try:
        # The socket alone must not eagerly start the API daemon.
        active = subprocess.run(["systemctl", "--user", "is-active", "--quiet",
                                 name + ".service"], check=False)
        assert active.returncode != 0, "API started before a request"
        for _ in range(2):
            reply = subprocess.check_output([
                "curl", "--fail", "--silent", "--show-error", "--max-time", "15",
                "--unix-socket", str(root / "api.sock"), "http://localhost/_ping"],
                text=True)
            assert reply == "OK", reply
        subprocess.run([*podman, "info", "--format", "{{.Host.Security.Rootless}}"],
                       env=env, check=True)
        print("PASS: idle socket, real API activation/repeated request and rootless CLI")
    finally:
        subprocess.run(["systemctl", "--user", "stop", name + ".socket", name + ".service"],
                       check=False)
        subprocess.run([*podman, "system", "migrate"], env=env, check=False)
