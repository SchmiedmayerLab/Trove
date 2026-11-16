# This source file is part of the Trove open-source project
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
# SPDX-License-Identifier: MIT

"""Loopback-only streaming fixture; all content and credentials are synthetic."""

import http.server
import json
import signal
import sys
import time


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        mode = self.path.split("/")[1]
        with open(sys.argv[1], "a", encoding="utf-8") as log:
            log.write(json.dumps({
                "path": self.path,
                "authorized": self.headers.get("Authorization") == "Bearer synthetic-test-credential",
                "identity_encoding": self.headers.get("Accept-Encoding") == "identity",
            }) + "\n")
        if mode == "redirect":
            self.send_response(302)
            self.send_header("Location", "/forbidden")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        size = {"small": 1024, "large": 128 * 1024 * 1024, "unknown": 128 * 1024 * 1024,
                "slow": 8 * 1024 * 1024}.get(mode, 1024)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("X-Recording-Content-Type", "text/csv")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Disposition", "attachment; filename=ignored.csv")
        if mode != "unknown":
            self.send_header("Content-Length", str(size))
        else:
            self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        sent = 0
        chunk = b"1,2\n" * (64 * 1024 // 4)
        try:
            while sent < size:
                data = chunk[:min(len(chunk), size - sent)]
                if mode == "unknown":
                    self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
                else:
                    self.wfile.write(data)
                self.wfile.flush()
                sent += len(data)
                if mode == "slow":
                    time.sleep(0.05)
            if mode == "unknown":
                self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with open(sys.argv[1], "a", encoding="utf-8") as log:
                log.write(json.dumps({"sent": sent, "total": size}) + "\n")


# Swift Testing can launch subprocesses with termination signals blocked on Linux.
# This owned fixture must remain terminable by Foundation.Process during teardown.
signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM})
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
