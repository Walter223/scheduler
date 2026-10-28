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


def run():
    auth.check_reset_ownership()  # Inspection only; never calls reset/down.
    auth.check_source()
    config = auth.check_compose()
    auth.compose("up", "-d", "--wait", "--wait-timeout", "240")
    clients, = auth.admin_get("realms/magnum/clients")
    web = next(c for c in clients if c["clientId"] == "magnum-web")
    auth.require(web["redirectUris"] == [auth.CALLBACK], "Run auth.py reconcile-callback first")
    for port in (4000, 5173):
        for host in ("127.0.0.1", "::1"):
            try:
                with socket.create_connection((host, port), timeout=1):
                    raise ValueError(f"Port {port} is occupied; stop your local dev server explicitly first")
            except OSError:
                pass

    processes = []
    owned_names = []
    seeded = False
    with tempfile.TemporaryDirectory(prefix="magnum-bff-e2e-") as directory:
        run_id = "magnum-bff-e2e-" + uuid.uuid4().hex
        fixture = {"run_id": run_id, "users": []}
        path = Path(directory) / "fixtures.json"
        env = {**os.environ, "MIX_ENV": "test", "MIX_TEST_PARTITION": "_auth_e2e",
               "MAGNUM_OIDC_ENABLED": "false", "BFF_E2E_FIXTURE": str(path),
               "MAGNUM_WEB_CLIENT_SECRET": config["services"]["keycloak"]["environment"]["MAGNUM_WEB_CLIENT_SECRET"],
               "MAGNUM_API_UPSTREAM": "http://127.0.0.1:4000", "PORT": "4000"}

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
            mix("ecto.create", "--quiet")
            mix("ecto.migrate", "--quiet")
            for kind in ("active", "pending"):
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
            vite, _ = spawn(["npm", "run", "dev", "--", "--host", "localhost", "--port", "5173", "--strictPort"],
                            auth.ROOT / "frontend")
            deadline = time.monotonic() + 30
            while True:
                try:
                    with urllib.request.urlopen("http://localhost:5173/api/me", timeout=1) as response:
                        auth.require(json.load(response)["authenticated"] is False, "Unexpected initial session")
                    break
                except OSError:
                    auth.require(vite.poll() is None and time.monotonic() < deadline, "Vite did not become ready")
                    threading.Event().wait(0.1)  # readiness polling, not browser/test timing
            result = subprocess.run(["npx", "playwright", "test", "--config", "playwright.auth.config.ts"],
                                    cwd=auth.ROOT / "frontend", env=env)
            auth.require(result.returncode == 0, "Real Keycloak browser suite failed")
            mix("run", "--no-start", "scripts/auth_e2e.exs", "verify")
            print("PASS: real signed-token login, pending denial, local logout and DB revocation")
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
            print("PASS: temporary Keycloak identities and isolated account/session/login fixtures cleaned")


if __name__ == "__main__":
    try:
        run()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        # Only our bounded messages/exception type; never dump captured subprocesses.
        print("ERROR: " + (str(error) if isinstance(error, ValueError) else type(error).__name__), file=sys.stderr)
        sys.exit(1)
