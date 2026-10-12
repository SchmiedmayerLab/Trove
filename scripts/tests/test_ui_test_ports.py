#
# This source file is part of the Trove open-source project
#
# SPDX-FileCopyrightText: 2026 Schmiedmayer Lab and the project authors (see CONTRIBUTORS.md)
#
# SPDX-License-Identifier: MIT
#

"""Verify native UI port checks without inspecting unrelated filesystem mounts."""

import errno
import importlib.util
import pathlib
import socket
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("ui_test_ports", ROOT / "TroveiOS/scripts/check-ui-test-ports.py")
PORTS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PORTS)


class UITestPortTests(unittest.TestCase):
    def test_free_loopback_port_is_accepted_and_released(self):
        PORTS.check_ports((0,))

    def test_existing_listener_rejects_startup(self):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            with self.assertRaisesRegex(RuntimeError, "unavailable"):
                PORTS.check_ports((listener.getsockname()[1],))

    def test_permission_failure_rejects_startup(self):
        with mock.patch.object(PORTS.socket, "socket", side_effect=PermissionError(errno.EACCES, "Permission denied")):
            with self.assertRaisesRegex(RuntimeError, "Permission denied"):
                PORTS.check_ports()

    def test_later_failure_closes_all_earlier_probe_sockets(self):
        first, second = mock.MagicMock(), mock.MagicMock()
        first.__enter__.return_value = first
        second.__enter__.return_value = second
        second.bind.side_effect = OSError(errno.EADDRINUSE, "Address already in use")
        with mock.patch.object(PORTS.socket, "socket", side_effect=(first, second)):
            with self.assertRaises(RuntimeError):
                PORTS.check_ports((8080, 8180))
        first.__exit__.assert_called_once()
        second.__exit__.assert_called_once()
        first.setsockopt.assert_not_called()
        second.setsockopt.assert_not_called()


if __name__ == "__main__":
    unittest.main()
