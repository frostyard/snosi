#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Minimal static-file HTTP server with real HTTP Range support, for local
# publication-pipeline rehearsals (test/native-ab-publication-test.sh,
# shared/native-ab/publish/verify-remote.sh's own self-test). Not used for
# anything shipped in an image.
#
# `python3 -m http.server`'s SimpleHTTPRequestHandler does NOT implement
# Range at all (confirmed against the stdlib source, Python 3.13): every GET
# always returns the full 200 body regardless of a Range header. That makes
# verify-remote.sh's mandatory ">=2 representative range GETs" check
# meaningless against it -- the "range" response would just be the full
# object, silently passing a check that is supposed to prove real partial
# fetches work. This script is the smallest fix that keeps the origin a
# plain stdlib python3 HTTP server (no new external dependency beyond what
# every other build/test script in this repo already requires) while
# actually honoring Range: bytes=start-end / start- / -suffix, streaming
# only the requested bytes so it stays cheap against multi-gigabyte
# artifacts.
#
# Usage: range-http-server.py <port> <directory> [--ignore-ranges]
#                                                [--ignore-first-ranges N]
#                                                [--reset-first-gets N]
#
# --ignore-ranges        every Range request is answered with a full 200 body
#                        (a permanently Range-incapable origin).
# --ignore-first-ranges  only the first N Range requests are answered that
#                        way, then Range is honored normally. This models the
#                        real Cloudflare-in-front-of-R2 behavior that broke
#                        build-installer-iso.yml run 33199899342: a cold
#                        (cf-cache-status BYPASS/DYNAMIC) object answers its
#                        first Range request with a full 200 and serves
#                        correct 206s from then on.
# --reset-first-gets N   the first N plain GETs (no Range header; HEAD is not
#                        counted) are answered with 200 headers carrying the
#                        FULL Content-Length, but only half the body travels
#                        before the connection is aborted with a TCP RST. This
#                        models the transient "curl: (56) Recv failure:
#                        Connection reset by peer" / "(18) end of response with
#                        N bytes missing" seen mid-body in public-origin ISO
#                        verification. SimpleHTTPRequestHandler's
#                        self.connection.close() does NOT close the socket fd
#                        -- rfile/wfile still reference it -- so a real abort
#                        needs SO_LINGER(1,0) plus shutdown(SHUT_RDWR). Each
#                        such abort also writes one "reset GET <path> after
#                        <half> of <size> bytes" line to stderr, so a test can
#                        prove that the abort really happened.
# Binds 127.0.0.1 only.
import http.server
import os
import re
import socket
import socketserver
import struct
import sys
import threading

RANGE_RE = re.compile(r"^bytes=(\d*)-(\d*)$")


class RangeRequestHandler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    ignore_ranges = False
    ignore_first_ranges = 0
    reset_first_gets = 0
    _ignore_lock = threading.Lock()
    _reset_lock = threading.Lock()

    @classmethod
    def _should_ignore_range(cls):
        if cls.ignore_ranges:
            return True
        with cls._ignore_lock:
            if cls.ignore_first_ranges > 0:
                cls.ignore_first_ranges -= 1
                return True
        return False

    @classmethod
    def _should_reset_get(cls):
        with cls._reset_lock:
            if cls.reset_first_gets > 0:
                cls.reset_first_gets -= 1
                return True
        return False

    def _abort_connection(self):
        """Abort the connection with a TCP RST, not a clean FIN.

        SO_LINGER with a zero timeout makes the close() that follows discard
        queued data and send RST. shutdown() forces the peer's read to fail
        right away instead of waiting for the handler's buffered file objects
        to be garbage-collected.
        """
        try:
            self.connection.setsockopt(
                socket.SOL_SOCKET,
                socket.SO_LINGER,
                struct.pack("ii", 1, 0),
            )
        except OSError:
            pass
        try:
            self.connection.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.close_connection = True

    def _reset_full_get(self, path, file_size):
        """Send full-length 200 headers, half the body, then abort."""
        half = max(1, file_size // 2) if file_size else 0
        sys.stderr.write(
            f"reset GET {self.path} after {half} of {file_size} bytes\n"
        )
        sys.stderr.flush()
        with open(path, "rb") as f:
            self.send_response(200)
            self.send_header("Content-Type", self.guess_type(path))
            self.send_header("Content-Length", str(file_size))
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
            if half:
                try:
                    self.wfile.write(f.read(half))
                    self.wfile.flush()
                except OSError:
                    pass
        self._abort_connection()

    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path) or not os.path.isfile(path):
            return super().send_head()

        file_size = os.path.getsize(path)
        range_header = self.headers.get("Range")
        if (
            not range_header
            and self.command == "GET"
            and self._should_reset_get()
        ):
            self._reset_full_get(path, file_size)
            return None
        if not range_header or self._should_ignore_range():
            f = open(path, "rb")
            self.send_response(200)
            self.send_header("Content-Type", self.guess_type(path))
            self.send_header("Content-Length", str(file_size))
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
            return f

        m = RANGE_RE.match(range_header.strip())
        if not m:
            self.send_error(416, "Invalid Range header")
            return None
        start_s, end_s = m.groups()
        if start_s == "" and end_s == "":
            self.send_error(416, "Invalid Range header")
            return None
        if start_s == "":
            # suffix range: last N bytes
            length = min(int(end_s), file_size)
            start = file_size - length
            end = file_size - 1
        else:
            start = int(start_s)
            end = int(end_s) if end_s != "" else file_size - 1
        if start >= file_size or start > end:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{file_size}")
            self.end_headers()
            return None
        end = min(end, file_size - 1)

        f = open(path, "rb")
        f.seek(start)
        self._range_remaining = end - start + 1
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
        self.send_header("Content-Length", str(self._range_remaining))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        return f

    def copyfile(self, source, outputfile):
        remaining = getattr(self, "_range_remaining", None)
        if remaining is None:
            return super().copyfile(source, outputfile)
        chunk_size = 1024 * 1024
        while remaining > 0:
            chunk = source.read(min(chunk_size, remaining))
            if not chunk:
                break
            outputfile.write(chunk)
            remaining -= len(chunk)


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        print(
            f"Usage: {sys.argv[0]} <port> <directory> "
            "[--ignore-ranges] [--ignore-first-ranges N] [--reset-first-gets N]",
            file=sys.stderr,
        )
        return 2
    port = int(args[0])
    directory = args[1]
    rest = args[2:]
    while rest:
        option = rest.pop(0)
        if option == "--ignore-ranges":
            RangeRequestHandler.ignore_ranges = True
        elif option == "--ignore-first-ranges":
            if not rest:
                print("--ignore-first-ranges requires a count", file=sys.stderr)
                return 2
            RangeRequestHandler.ignore_first_ranges = int(rest.pop(0))
        elif option == "--reset-first-gets":
            if not rest:
                print("--reset-first-gets requires a count", file=sys.stderr)
                return 2
            RangeRequestHandler.reset_first_gets = int(rest.pop(0))
        else:
            print(f"Unknown option: {option}", file=sys.stderr)
            return 2

    handler = lambda *a, **kw: RangeRequestHandler(*a, directory=directory, **kw)  # noqa: E731
    with ThreadingHTTPServer(("127.0.0.1", port), handler) as httpd:
        if RangeRequestHandler.ignore_ranges:
            mode = "ignoring Range"
        elif RangeRequestHandler.ignore_first_ranges:
            mode = f"ignoring first {RangeRequestHandler.ignore_first_ranges} Range request(s)"
        else:
            mode = "Range-capable"
        if RangeRequestHandler.reset_first_gets:
            mode += f", resetting first {RangeRequestHandler.reset_first_gets} plain GET(s)"
        print(f"Serving {directory} on http://127.0.0.1:{port}/ ({mode})")
        httpd.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
