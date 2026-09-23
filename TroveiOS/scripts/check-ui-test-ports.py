#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Require the native UI stack's loopback ports before starting owned services."""

import contextlib
import socket
import sys


def check_ports(ports: tuple[int, ...] = (8080, 8180, 9000)) -> None:
    with contextlib.ExitStack() as sockets:
        for port in ports:
            try:
                probe = sockets.enter_context(socket.socket(socket.AF_INET, socket.SOCK_STREAM))
                # No address/port reuse: an existing listener must prevent startup.
                probe.bind(("127.0.0.1", port))
            except OSError as error:
                raise RuntimeError(f"Native test port {port} is unavailable: {error.strerror}; no services were started.") from error


if __name__ == "__main__":
    try:
        check_ports()
    except RuntimeError as failure:
        print(failure, file=sys.stderr)
        sys.exit(1)
