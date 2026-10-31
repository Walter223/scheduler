#!/usr/bin/env python3
"""Opt-in real Keycloak browser tests; isolated PostgreSQL DB and temporary owned identities."""
import json
import os
from pathlib import Path
import queue
import secrets
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import uuid

import auth


def check_ports():
    for port in (4002, 5174):
        for host in ("127.0.0.1", "::1"):
            try:
                with socket.create_connection((host, port), timeout=1):
                    raise ValueError(f"Port {port} is occupied; existing servers were preserved. This exact-origin runner requires free ports 4002/5174")
            except OSError:
                pass


def run():
    check_ports()  # Refuse before Docker, Keycloak or database operations.
    auth.check_reset_ownership()  # Inspection only; never calls reset/down.
    auth.check_source()
    auth.check_compose()
    auth.compose("up", "-d", "--wait", "--wait-timeout", "240")

    processes = []
    owned_names = []
    seeded = False
    with tempfile.TemporaryDirectory(prefix="magnum-bff-e2e-") as directory:
        run_id = "magnum-bff-e2e-" + uuid.uuid4().hex
        fixture = {"run_id": run_id, "users": []}
        client_secret = secrets.token_urlsafe(48)
        path = Path(directory) / "fixtures.json"
        env = {**os.environ, "MIX_ENV": "test", "MIX_TEST_PARTITION": "_auth_e2e",
               "MAGNUM_OIDC_ENABLED": "false", "BFF_E2E_FIXTURE": str(path),
               "MAGNUM_WEB_CLIENT_SECRET": client_secret, "BFF_E2E_CLIENT_ID": run_id,
               "MAGNUM_API_UPSTREAM": "http://127.0.0.1:4002", "PORT": "4002"}

        def mix(*args):
            result = subprocess.run(["mix", *args], cwd=auth.ROOT / "backend", env=env,
                                    text=True, capture_output=True, timeout=120)
            # Never echo backend/provider output containing credentials on failure.
            auth.require(result.returncode == 0, "Isolated backend fixture command failed: " + args[-1])

        def spawn(command, cwd):
            process = subprocess.Popen(command, cwd=cwd, env=env, stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True, start_new_session=True)
            processes.append(process)
            lines = queue.Queue()
            def drain():
                for line in process.stdout:
                    if line.strip() == "AUTH_E2E_READY":
                        lines.put(True)
            threading.Thread(target=drain, daemon=True).start()
            return process, lines

        try:
            client = json.loads((auth.ROOT / "infra/auth/magnum-realm.json").read_text())["clients"][0]
            client.update(clientId=run_id, name=run_id, secret=client_secret,
                          redirectUris=["http://localhost:5174/auth/callback"],
                          webOrigins=["http://localhost:5174"])
            client["attributes"]["post.logout.redirect.uris"] = "http://localhost:5174/"
            client["attributes"]["id.token.signed.response.alg"] = "RS256"
            auth.admin_write("create", "realms/magnum/clients", client)
            live, = auth.admin_get("realms/magnum/clients?clientId=" + run_id)
            auth.require(len(live) == 1 and live[0]["clientId"] == run_id and
                         live[0]["redirectUris"] == client["redirectUris"] and
                         live[0]["webOrigins"] == client["webOrigins"] and
                         live[0]["attributes"]["pkce.code.challenge.method"] == "S256" and
                         live[0]["standardFlowEnabled"] and not live[0]["publicClient"] and
                         not live[0]["implicitFlowEnabled"] and not live[0]["directAccessGrantsEnabled"],
                         "Isolated client contract mismatch")
            mix("ecto.create", "--quiet")
            mix("ecto.migrate", "--quiet")
            for kind in ("active", "pending", "owner", "manager", "shop_manager", "employee", "mixed", "multi_owner"):
                username = run_id + "-" + kind
                password = secrets.token_urlsafe(32)
                email = username + "@example.invalid"
                username = email  # Realm registrationEmailAsUsername is enabled.
                owned_names.append(username)
                auth.admin_write("create", "realms/magnum/users", {
                    "username": username, "email": email, "emailVerified": True, "enabled": True,
                    "firstName": "E2E", "lastName": kind.title(), "requiredActions": [],
                    "credentials": [{"type": "password", "value": password, "temporary": False}],
                })
                users, = auth.admin_get("realms/magnum/users?username=" + username + "&exact=true")
                auth.require(len(users) == 1 and users[0]["username"] == username, "Owned identity not found")
                fixture["users"].append({"kind": kind, "username": username, "password": password,
                                         "email": email, "subject": users[0]["id"]})
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as stream:
                json.dump(fixture, stream)
            mix("run", "--no-start", "scripts/auth_e2e.exs", "seed")
            seeded = True
            _, ready = spawn(["mix", "run", "--no-start", "scripts/auth_e2e.exs", "server"], auth.ROOT / "backend")
            try:
                ready.get(timeout=60)
            except queue.Empty:
                raise ValueError("Auth E2E backend/provider did not become ready") from None
            vite, _ = spawn(["npm", "run", "dev", "--", "--host", "localhost", "--port", "5174", "--strictPort"],
                            auth.ROOT / "frontend")
            deadline = time.monotonic() + 30
            while True:
                try:
                    with urllib.request.urlopen("http://localhost:5174/api/me", timeout=1) as response:
                        auth.require(json.load(response)["authenticated"] is False, "Unexpected initial session")
                    break
                except OSError:
                    auth.require(vite.poll() is None and time.monotonic() < deadline, "Vite did not become ready")
                    threading.Event().wait(0.1)  # readiness polling, not browser/test timing
            result = subprocess.run(["npx", "playwright", "test", "--config", "playwright.auth.config.ts"],
                                    cwd=auth.ROOT / "frontend", env=env)
            auth.require(result.returncode == 0, "Real Keycloak browser suite failed")
            mix("run", "--no-start", "scripts/auth_e2e.exs", "verify")
            print("PASS: real signed-token login, pending denial, role-scoped Admin acceptance, expiry and local logout")
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=15)
            try:
                if seeded:
                    mix("run", "--no-start", "scripts/auth_e2e.exs", "cleanup")
            finally:
                for username in owned_names:
                    users, = auth.admin_get("realms/magnum/users?username=" + username + "&exact=true")
                    if not users:
                        continue
                    auth.require(len(users) == 1, "Ambiguous fixture ownership")
                    user = users[0]
                    user_id = user["id"]
                    auth.require(user["username"] == username and username.startswith(run_id),
                                 "Identity ownership changed; refusing deletion")
                    auth.admin_write("delete", "realms/magnum/users/" + user_id)
                owned_clients, = auth.admin_get("realms/magnum/clients?clientId=" + run_id)
                for owned in owned_clients:
                    auth.require(owned["clientId"] == run_id and owned["name"] == run_id,
                                 "Client ownership changed; refusing deletion")
                    auth.admin_write("delete", "realms/magnum/clients/" + owned["id"])
                remaining, = auth.admin_get("realms/magnum/clients?clientId=" + run_id)
                auth.require(not remaining, "Owned client cleanup incomplete")
            print("PASS: temporary Keycloak identities/client and isolated account/session/login fixtures cleaned")


if __name__ == "__main__":
    try:
        run()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        # Only our bounded messages/exception type; never dump captured subprocesses.
        print("ERROR: " + (str(error) if isinstance(error, ValueError) else type(error).__name__), file=sys.stderr)
        sys.exit(1)
