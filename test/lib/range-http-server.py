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
# Usage: range-http-server.py <port> <directory>
# Binds 127.0.0.1 only.
import http.server
import os
import re
import socketserver
import sys

RANGE_RE = re.compile(r"^bytes=(\d*)-(\d*)$")


class RangeRequestHandler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path) or not os.path.isfile(path):
            return super().send_head()

        file_size = os.path.getsize(path)
        range_header = self.headers.get("Range")
        if not range_header:
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
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <port> <directory>", file=sys.stderr)
        return 2
    port = int(sys.argv[1])
    directory = sys.argv[2]

    handler = lambda *a, **kw: RangeRequestHandler(*a, directory=directory, **kw)  # noqa: E731
    with ThreadingHTTPServer(("127.0.0.1", port), handler) as httpd:
        print(f"Serving {directory} on http://127.0.0.1:{port}/ (Range-capable)")
        httpd.serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
