#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Type one initrd recovery key after a serial password prompt settles."""
import re
import socket
import sys
import time

path, log_path, key = sys.argv[1:]
for _ in range(50):
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(path)
        break
    except OSError:
        time.sleep(0.2)
else:
    raise SystemExit("serial socket unavailable")

prompt = re.compile(
    rb"[Ee]nter[^\n]*pass ?(?:phrase|word)[^\n]*:"
    rb"(?:\s|\x1b\[[0-9;]*m|\(press TAB for no echo\))*"
)
# Deliberately not end-anchored: Task 3's observed initrd writes progress after
# the prompt in the same read. Serial quiet plus the one-shot latch distinguish
# a waiting prompt here; do not reuse this worker for a multi-prompt flow.
sent = False
buffer = bytearray()
last_rx = time.time()
sock.settimeout(1)
with open(log_path, "ab", buffering=0) as log:
    while True:
        try:
            data = sock.recv(4096)
        except socket.timeout:
            data = None
        if data == b"":
            break
        if data:
            log.write(data)
            buffer.extend(data)
            if len(buffer) > 8192:
                del buffer[:-8192]
            last_rx = time.time()
        # Progress lines can arrive in the same socket read as the prompt. Keep
        # that observed prompt match, but wait for serial quiet before typing.
        if not sent and time.time() - last_rx > 0.6 and prompt.search(bytes(buffer)):
            time.sleep(0.3)
            sock.sendall(key.encode() + b"\r\n")
            log.write(b"\n[task3: typed recovery passphrase]\n")
            sent = True
