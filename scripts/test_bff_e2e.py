#!/usr/bin/env python3
"""Non-destructive runner prerequisite tests; no Docker or PostgreSQL required."""
import unittest
from unittest.mock import patch, MagicMock
import bff_e2e


class PortSafetyTest(unittest.TestCase):
    def test_occupied_port_stops_before_infrastructure(self):
        with patch.object(bff_e2e.socket, "create_connection", return_value=MagicMock()), \
                patch.object(bff_e2e.auth, "check_reset_ownership") as docker:
            with self.assertRaisesRegex(ValueError, "Port 4002 is occupied"):
                bff_e2e.run()
            docker.assert_not_called()

    def test_checks_ipv4_and_ipv6_for_both_ports(self):
        with patch.object(bff_e2e.socket, "create_connection", side_effect=OSError) as connect:
            bff_e2e.check_ports()
            self.assertEqual([c.args[0] for c in connect.call_args_list],
                             [("127.0.0.1", 4002), ("::1", 4002), ("127.0.0.1", 5174), ("::1", 5174)])


if __name__ == "__main__":
    unittest.main()
