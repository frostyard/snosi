#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Socket-level regression test for Task 3's initrd recovery pump."""
import os
import socket
import select
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PUMP = os.path.join(ROOT, "test/lib/task3-console-pump.py")
PROMPT = b"Please enter passphrase for disk root: (press TAB for no echo) \x1b[0m"
PROGRESS = b"\r\n[  **  ] Job systemd-cryptsetup@root.service/start running\r\n"

with tempfile.TemporaryDirectory() as work:
    path = os.path.join(work, "serial.sock")
    log = os.path.join(work, "console.log")
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(1)
    pump = subprocess.Popen([sys.executable, PUMP, path, log, "fixture-recovery"])
    ready, _, _ = select.select([server], [], [], 2)
    if not ready:
        raise SystemExit(f"pump did not connect: exit={pump.poll()}")
    conn, _ = server.accept()
    conn.sendall(PROMPT + PROGRESS)
    time.sleep(1)
    conn.settimeout(2)
    received = conn.recv(128)
    time.sleep(0.2)
    conn.close()
    server.close()
    pump.terminate()
    pump.wait(timeout=5)

if received != b"fixture-recovery\r\n":
    raise SystemExit(f"expected one idle-settled recovery write, got {received!r}")
print("PASS: Task 3 pump sends one key after prompt plus progress becomes quiet")
