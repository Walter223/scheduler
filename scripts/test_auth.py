"""Dependency-free regression checks for the infrastructure contract guard."""
import copy
import json
import unittest
from unittest.mock import patch

import auth


class AuthContractTest(unittest.TestCase):
    def setUp(self):
        self.realm = json.loads(auth.REALM.read_text())

    def test_source_is_valid(self):
        auth.check_source()

    def test_unsafe_client_contracts_are_rejected(self):
        cases = [
            ("publicClient", True),
            ("implicitFlowEnabled", True),
            ("directAccessGrantsEnabled", True),
            ("standardFlowEnabled", False),
            ("redirectUris", ["http://localhost:4000/*"]),
        ]
        for field, value in cases:
            with self.subTest(field=field):
                realm = copy.deepcopy(self.realm)
                realm["clients"][0][field] = value
                with self.assertRaises(ValueError):
                    auth.check_contract(realm)

    def test_missing_api_audience_is_rejected(self):
        self.realm["clients"][0]["protocolMappers"][0]["config"]["access.token.claim"] = "false"
        with self.assertRaises(ValueError):
            auth.check_contract(self.realm)

    def test_users_and_authorization_roles_are_rejected(self):
        for field in ("users", "groups", "roles"):
            with self.subTest(field=field):
                realm = copy.deepcopy(self.realm)
                realm[field] = [{"name": "should-not-be-here"}]
                with self.assertRaises(ValueError):
                    auth.check_contract(realm)

    def test_literal_client_secrets_are_rejected(self):
        self.realm["clients"][0]["secret"] = "accidental-local-secret"
        with patch.object(auth.REALM.__class__, "read_text", return_value=json.dumps(self.realm)):
            with self.assertRaisesRegex(ValueError, "secret/credential"):
                auth.check_source()

    def test_source_cannot_redirect_smtp_to_real_mail(self):
        self.realm["smtpServer"]["host"] = "smtp.example.com"
        with self.assertRaisesRegex(ValueError, "local sink"):
            auth.check_contract(self.realm)

    def test_reset_accepts_only_owned_auth_resources(self):
        labels = {"com.docker.compose.project": "magnum-auth-dev",
                  "com.docker.compose.volume": "auth-postgres"}
        volume = {"Name": "magnum-auth-dev_auth-postgres", "Labels": labels}
        auth.check_owned_resources([], [volume], [])
        volume["Labels"] = {}
        with self.assertRaisesRegex(ValueError, "ownership mismatch"):
            auth.check_owned_resources([], [volume], [])

    def test_reset_rejects_extra_project_volumes(self):
        with self.assertRaisesRegex(ValueError, "ownership mismatch"):
            auth.check_owned_resources([], [{"Name": "scheduler-data", "Labels": {
                "com.docker.compose.project": "magnum-auth-dev"}}], [])

    def test_reset_rejects_foreign_volume_consumers(self):
        consumer = {"Config": {"Labels": {"com.docker.compose.project": "another-project"}},
                    "Mounts": [{"Type": "volume", "Name": "magnum-auth-dev_auth-postgres"}]}
        with self.assertRaisesRegex(ValueError, "volume consumer"):
            auth.check_owned_resources([consumer], [], [])

    def test_reset_rejects_unexpected_services(self):
        consumer = {"Config": {"Labels": {"com.docker.compose.project": "magnum-auth-dev",
                                            "com.docker.compose.service": "scheduler-db"}}}
        with self.assertRaisesRegex(ValueError, "Unexpected/duplicate service"):
            auth.check_owned_resources([consumer], [], [])

    def test_reset_rejects_foreign_network_consumers(self):
        network = {"Name": "magnum-auth-dev_auth", "Id": "auth-network", "Labels": {
            "com.docker.compose.project": "magnum-auth-dev", "com.docker.compose.network": "auth"}}
        consumer = {"Config": {"Labels": {}}, "NetworkSettings": {
            "Networks": {"auth": {"NetworkID": "auth-network"}}}}
        with self.assertRaisesRegex(ValueError, "Foreign container"):
            auth.check_owned_resources([consumer], [], [network])

    def test_admin_projection_preserves_nested_maps(self):
        response = json.dumps({"smtpServer": auth.SMTP}) + '\n' + json.dumps([
            {"attributes": {"pkce.code.challenge.method": "S256"}}])
        with patch.object(auth, "compose", return_value=response) as run:
            realm, clients = auth.admin_get("realms/magnum", "realms/magnum/clients")
        self.assertEqual(realm["smtpServer"], auth.SMTP)
        self.assertEqual(clients[0]["attributes"]["pkce.code.challenge.method"], "S256")
        self.assertNotIn("--fields", run.call_args.args[5])

    def test_host_bridge_does_not_expose_database_or_broad_ports(self):
        config = {"networks": {"auth": {"internal": True}, "auth-local": {}}, "services": {
            "auth-db": {"networks": {"auth": {}}},
            "keycloak": {"networks": {"auth": {}, "auth-local": {}},
                         "ports": [{"host_ip": "127.0.0.1"}]},
            "auth-mail": {"networks": {"auth": {}, "auth-local": {}},
                          "ports": [{"host_ip": "127.0.0.1"}]}}}
        auth.check_network_contract(config)
        internal_only = copy.deepcopy(config)
        del internal_only["services"]["keycloak"]["networks"]["auth-local"]
        with self.assertRaises(ValueError):
            auth.check_network_contract(internal_only)
        config["services"]["auth-db"]["networks"]["auth-local"] = {}
        with self.assertRaisesRegex(ValueError, "Database must remain"):
            auth.check_network_contract(config)


if __name__ == "__main__":
    unittest.main()
