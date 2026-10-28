#!/usr/bin/env python3
"""Local authentication infrastructure only. Python standard library + Docker Compose."""
import argparse
import json
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
ENV = ROOT / "infra/auth/.env"
REALM = ROOT / "infra/auth/magnum-realm.json"
ISSUER = "http://auth.magnum.test:8080/realms/magnum"
CALLBACK = "http://localhost:5173/auth/callback"
LOGOUT_RETURN = "http://localhost:5173/"
SERVICES = {"auth-db", "auth-mail", "keycloak"}
SMTP = {
    "host": "auth-mail", "port": "1025", "from": "no-reply@magnum.test",
    "fromDisplayName": "Magnum Local Development", "auth": "false",
    "ssl": "false", "starttls": "false",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check_contract(realm):
    """Validate both checked-in configuration and selected live Admin API fields."""
    require(realm["realm"] == "magnum" and realm["enabled"], "Expected enabled magnum realm")
    require(not realm.get("users") and not realm.get("groups") and not realm.get("roles"),
            "No users, groups or Magnum authorization roles belong in this configuration")
    require(realm["verifyEmail"] and realm["bruteForceProtected"], "Email/brute-force baseline missing")
    require(not realm["registrationAllowed"], "Self-registration must stay disabled")
    require(realm["passwordPolicy"] ==
            "length(15) and maxLength(128) and notUsername(undefined) and notEmail(undefined)",
            "Password baseline differs")
    require(realm["smtpServer"] == SMTP,
            "SMTP must point only at the local sink")
    clients = {c["clientId"]: c for c in realm["clients"]}
    web = clients["magnum-web"]
    require(not web["publicClient"] and not web["bearerOnly"], "BFF must be confidential")
    require(web["standardFlowEnabled"] and not web["implicitFlowEnabled"]
            and not web["directAccessGrantsEnabled"] and not web["serviceAccountsEnabled"],
            "Unexpected web grant/flow configuration")
    require(web["redirectUris"] == [CALLBACK], "Exact callback required")
    require(web.get("webOrigins", []) == [], "BFF does not need browser token CORS")
    require(web["attributes"]["pkce.code.challenge.method"] == "S256", "S256 PKCE required")
    require(web["attributes"]["post.logout.redirect.uris"] == LOGOUT_RETURN,
            "Exact logout return required")
    mapper = next(m for m in web["protocolMappers"] if m["name"] == "magnum-api-audience")
    require(mapper["protocolMapper"] == "oidc-audience-mapper" and
            mapper["config"]["included.client.audience"] == "magnum-api" and
            mapper["config"]["access.token.claim"] == "true" and
            mapper["config"]["id.token.claim"] == "false", "API access-token audience missing")
    api = clients["magnum-api"]
    require(api["bearerOnly"] and not api["standardFlowEnabled"] and
            not api["implicitFlowEnabled"] and not api["directAccessGrantsEnabled"],
            "API is a resource, not a login client")


def check_source():
    realm = json.loads(REALM.read_text())

    def scan(value):
        if isinstance(value, dict):
            for key, item in value.items():
                normalized = key.lower().replace("_", "").replace("-", "")
                if normalized in {"secret", "password", "credentials", "accesstoken",
                                  "refreshtoken", "privatekey", "clientsecret"}:
                    require(key == "secret" and item == "${MAGNUM_WEB_CLIENT_SECRET}",
                            "Possible secret/credential in realm configuration")
                scan(item)
        elif isinstance(value, list):
            for item in value:
                scan(item)
        elif isinstance(value, str):
            require("BEGIN PRIVATE KEY" not in value and not value.startswith("eyJ"),
                    "Possible key/token in realm configuration")

    scan(realm)
    check_contract(realm)
    require(realm["clients"][0]["secret"] == "${MAGNUM_WEB_CLIENT_SECRET}",
            "Client secret must use Keycloak runtime substitution")
    print("PASS: source realm contract and obvious-secret guard")


def compose(*args, capture=False, input_text=None):
    require(shutil.which("docker"), "Docker with Compose v2 is required; Docker is not installed/on PATH")
    require(ENV.exists(), "Run python3 scripts/auth.py init first")
    # Never print rendered Compose configuration: it contains resolved secrets.
    command = ["docker", "compose", "--project-name", "magnum-auth-dev",
               "--env-file", str(ENV), "-f", str(ROOT / "compose.yaml"), "--profile", "auth"]
    result = subprocess.run(command + list(args), cwd=ROOT, text=True, input=input_text,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    require(result.returncode == 0, "Compose command failed" if capture else "Compose failed; see output")
    return result.stdout if capture else None


def get_json(url):
    # These are local-only probes; do not route auth/management through HTTP_PROXY.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(url, timeout=10) as response:
        return json.load(response)


def docker_json(*args):
    result = subprocess.run(["docker", *args], text=True, capture_output=True)
    require(result.returncode == 0, "Docker inspection failed; refusing reset")
    return json.loads(result.stdout)


def docker_records(*args):
    result = subprocess.run(["docker", *args, "--format", "{{json .}}"], text=True, capture_output=True)
    require(result.returncode == 0, "Docker inventory failed; refusing reset")
    return [json.loads(line) for line in result.stdout.splitlines() if line.strip()]


def check_owned_resources(containers, volumes, networks):
    """Names AND Compose labels must agree; foreign consumers also prevent reset."""
    project = "magnum-auth-dev"
    volume_names = {project + "_auth-postgres": "auth-postgres", project + "_auth-mail": "auth-mail"}
    network_names = {project + "_auth": "auth", project + "_auth-local": "auth-local"}
    for volume in volumes:
        labels = volume.get("Labels") or {}
        if volume["Name"] in volume_names or labels.get("com.docker.compose.project") == project:
            require(volume["Name"] in volume_names and
                    labels.get("com.docker.compose.project") == project and
                    labels.get("com.docker.compose.volume") == volume_names[volume["Name"]],
                    "Volume ownership mismatch; refusing reset")
    owned_network_ids = set()
    for network in networks:
        labels = network.get("Labels") or {}
        if network["Name"] in network_names or labels.get("com.docker.compose.project") == project:
            require(network["Name"] in network_names and
                    labels.get("com.docker.compose.project") == project and
                    labels.get("com.docker.compose.network") == network_names[network["Name"]],
                    "Network ownership mismatch; refusing reset")
            owned_network_ids.add(network["Id"])
    seen = set()
    for container in containers:
        labels = container["Config"].get("Labels") or {}
        owned = labels.get("com.docker.compose.project") == project
        service = labels.get("com.docker.compose.service")
        if owned:
            require(service in SERVICES and service not in seen,
                    "Unexpected/duplicate service in auth project; refusing reset")
            seen.add(service)
            require(labels.get("com.docker.compose.project.config_files") == str(ROOT / "compose.yaml")
                    and labels.get("com.docker.compose.project.working_dir") == str(ROOT),
                    "Container belongs to another Compose configuration; refusing reset")
        for mount in container.get("Mounts", []):
            if mount["Type"] == "volume":
                name = mount.get("Name")
                require((not owned and name not in volume_names) or (owned and name in volume_names),
                        "Unexpected/shared auth volume consumer; refusing reset")
            elif owned:
                require(mount["Type"] == "bind" and service == "keycloak" and
                        mount["Source"] == str(REALM) and not mount["RW"],
                        "Unexpected auth bind mount; refusing reset")
        for network in container.get("NetworkSettings", {}).get("Networks", {}).values():
            require(owned or network.get("NetworkID") not in owned_network_ids,
                    "Foreign container uses the auth network; refusing reset")


def check_reset_ownership():
    # Reset is deliberately restricted to local Docker Desktop, never a remote
    # daemon. No context switching or host configuration changes are performed.
    context = docker_json("context", "inspect")[0]
    endpoint = context["Endpoints"]["docker"]["Host"]
    local_sockets = {"unix://" + str(Path.home() / ".docker/run/docker.sock"),
                     "unix:///var/run/docker.sock"}
    require(context["Name"] == "desktop-linux" and endpoint in local_sockets and
            os.environ.get("DOCKER_HOST", endpoint) == endpoint and
            not os.environ.get("DOCKER_TLS_VERIFY") and not os.environ.get("DOCKER_CERT_PATH"),
            "Reset requires the unambiguous local Docker Desktop target")
    info = docker_json("info", "--format", "{{json .}}")
    require(info["OperatingSystem"] == "Docker Desktop", "Local Docker Desktop must be running")
    ids = docker_records("container", "ls", "--all")
    containers = docker_json("container", "inspect", *(c["ID"] for c in ids)) if ids else []
    volume_names = docker_records("volume", "ls")
    volumes = docker_json("volume", "inspect", *(v["Name"] for v in volume_names)) if volume_names else []
    network_names = docker_records("network", "ls")
    networks = docker_json("network", "inspect", *(n["ID"] for n in network_names)) if network_names else []
    check_owned_resources(containers, volumes, networks)
    print("PASS: local Docker Desktop target, Compose ownership labels and exclusive auth resources")


def check_network_contract(config):
    require(config["networks"]["auth"]["internal"], "Auth network must be isolated")
    require(set(config["networks"]) == {"auth", "auth-local"} and
            not config["networks"]["auth-local"].get("internal", False),
            "Expected isolated database and host-facing auth bridges")
    db = config["services"]["auth-db"]
    require(not db.get("ports"), "Keycloak database must not publish a host port")
    require(set(db["networks"]) == {"auth"}, "Database must remain on the internal network only")
    for name in ("keycloak", "auth-mail"):
        service = config["services"][name]
        require(set(service["networks"]) == {"auth", "auth-local"},
                "Published services need the host-facing bridge")
        require(all(port.get("host_ip") == "127.0.0.1" for port in service["ports"]),
                "Auth ports must publish only on loopback")


def check_compose():
    config = json.loads(compose("config", "--format", "json", capture=True))
    require(set(config["services"]) == SERVICES, "Unexpected service in local-auth reset boundary")
    images = {"keycloak": "quay.io/keycloak/keycloak:26.8.1", "auth-db": "postgres:18.6",
              "auth-mail": "axllent/mailpit:v1.32.0"}
    for name, service in config["services"].items():
        require(service["profiles"] == ["auth"], "All services must be opt-in")
        require(service["image"] == images[name], "Unexpected/unpinned image")
    require(config["name"] == "magnum-auth-dev", "Unexpected project reset boundary")
    require(set(config["volumes"]) == {"auth-postgres", "auth-mail"}, "Unexpected auth volumes")
    for name, volume in config["volumes"].items():
        require(not volume.get("external") and volume["name"] == "magnum-auth-dev_" + name and
                not volume.get("driver_opts"), "Auth volumes must belong only to this local project")
    check_network_contract(config)
    keycloak = config["services"]["keycloak"]["environment"]
    for name in ("KC_DB_PASSWORD", "KC_BOOTSTRAP_ADMIN_PASSWORD", "MAGNUM_WEB_CLIENT_SECRET"):
        value = keycloak[name]
        require(len(value) >= 32 and "replace-with" not in value,
                "Generate real local-only random secrets with auth.py init")
    print("PASS: rendered Compose profile, version pins and database isolation")
    return config


def admin_get(*paths):
    # Capture responses in memory. Do not use kcadm --fields for nested maps:
    # in this version it projects smtpServer/attributes/config into empty maps.
    script = '''set -eu
config=$(mktemp)
trap 'rm -f "$config"' EXIT
/opt/keycloak/bin/kcadm.sh config credentials --config "$config" --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null 2>&1
for path in "$@"; do
  /opt/keycloak/bin/kcadm.sh get "$path" --config "$config"
done
'''
    output = compose("exec", "-T", "keycloak", "bash", "-ec", script, "auth-smoke", *paths,
                     capture=True)
    values = []
    decoder = json.JSONDecoder()
    while output.strip():
        output = output.lstrip()
        value, end = decoder.raw_decode(output)
        values.append(value)
        output = output[end:]
    return values


def admin_write(method, path, body=None):
    """Supported kcadm API; JSON/credentials never appear in process arguments/output."""
    require(method in {"create", "update", "delete"}, "Invalid admin operation")
    script = '''set -eu
config=$(mktemp)
payload=$(mktemp)
trap 'rm -f "$config" "$payload"' EXIT
/opt/keycloak/bin/kcadm.sh config credentials --config "$config" --server http://localhost:8080 --realm master --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null 2>&1
if [ "$1" = delete ]; then
  /opt/keycloak/bin/kcadm.sh delete "$2" --config "$config" >/dev/null 2>&1
else
  cat > "$payload"
  /opt/keycloak/bin/kcadm.sh "$1" "$2" --config "$config" -f "$payload" >/dev/null 2>&1
fi
'''
    compose("exec", "-T", "keycloak", "bash", "-ec", script, "auth-admin", method, path,
            capture=True, input_text=json.dumps(body) if body is not None else "")


def reconcile_callback():
    """Opt-in partial client update only: no realm import/reset, no secret rotation."""
    check_source()
    check_compose()
    check_reset_ownership()
    clients, = admin_get("realms/magnum/clients")
    web = next(c for c in clients if c["clientId"] == "magnum-web")
    require(web["redirectUris"] in [["http://localhost:4000/auth/callback"], [CALLBACK]],
            "Unexpected existing redirect URIs; refusing to overwrite")
    # Keycloak derives webOrigins from redirectUris when webOrigins is omitted
    # in this partial update. Explicitly retain the source's empty BFF CORS list.
    require(web.get("webOrigins", []) in [[], ["http://localhost:5173"]],
            "Unexpected existing webOrigins; refusing to overwrite")
    patch = {"redirectUris": [CALLBACK], "webOrigins": []}
    admin_write("update", "realms/magnum/clients/" + web["id"], patch)
    updated, = admin_get("realms/magnum/clients/" + web["id"])
    require(updated == {**web, **patch},
            "Unexpected client change; inspect non-secret configuration before continuing")
    print("PASS: magnum-web callback reconciled with empty webOrigins; other client fields preserved")


def smoke():
    check_source()
    config = check_compose()
    # Compose polls actual health status, with a deadline; no arbitrary sleeps.
    compose("up", "-d", "--wait", "--wait-timeout", "240")
    addresses = {entry[4][0] for entry in socket.getaddrinfo("auth.magnum.test", 8080)}
    require(addresses == {"127.0.0.1"}, "Map auth.magnum.test to 127.0.0.1 in /etc/hosts")
    for probe in ("started", "live", "ready"):
        health = get_json("http://127.0.0.1:9000/health/" + probe)
        require(health["status"] == "UP", "Keycloak health probe failed: " + probe)
        if probe == "ready":
            require(any("database" in c["name"].lower() and c["status"] == "UP"
                        for c in health["checks"]), "Readiness must include an UP database check")
    discovery = get_json(ISSUER + "/.well-known/openid-configuration")
    require(discovery["issuer"] == ISSUER, "Canonical issuer mismatch")
    base = ISSUER + "/protocol/openid-connect/"
    for key, suffix in (("authorization_endpoint", "auth"), ("token_endpoint", "token"),
                        ("jwks_uri", "certs"), ("end_session_endpoint", "logout"),
                        ("userinfo_endpoint", "userinfo")):
        require(discovery[key] == base + suffix, "Noncanonical discovery endpoint: " + key)
    jwks = get_json(discovery["jwks_uri"])
    require(any(k.get("kid") and k.get("use") == "sig" and k.get("kty") == "RSA"
                and k.get("alg") == "RS256" and k.get("n") and k.get("e")
                for k in jwks["keys"]), "No usable RS256 signing-key metadata")
    # The bootstrap account is for this local infrastructure check only. This is
    # NOT an application password-grant flow. Credentials remain inside Docker.
    realm, clients = admin_get("realms/magnum", "realms/magnum/clients")
    source = json.loads(REALM.read_text())
    for field, expected in source.items():
        if field != "clients":
            require(realm.get(field) == expected, "Live realm configuration differs: " + field)
    web = next(c for c in clients if c["clientId"] == "magnum-web")
    secret, = admin_get("realms/magnum/clients/" + web["id"] + "/client-secret")
    expected_secret = config["services"]["keycloak"]["environment"]["MAGNUM_WEB_CLIENT_SECRET"]
    require(bool(secret.get("value")) and secrets.compare_digest(secret["value"], expected_secret),
            "Runtime client secret does not match environment injection")
    # Keep credential responses in memory only; never log or persist them.
    del secret, expected_secret, config
    # Keycloak also creates its built-in account/admin clients; ignore those.
    realm["clients"] = [{k: v for k, v in c.items() if k != "secret"}
                        for c in clients if c["clientId"] in {"magnum-web", "magnum-api"}]
    check_contract(realm)
    print("PASS: live realm policy and runtime client-secret injection (value not printed)")
    db = compose("exec", "-T", "auth-db", "psql", "-U", "keycloak", "-d", "keycloak",
                 "-Atc", "SELECT current_database(), current_user", capture=True)
    require(db.strip() == "keycloak|keycloak", "Unexpected authentication database identity")
    tables = compose("exec", "-T", "auth-db", "psql", "-U", "keycloak", "-d", "keycloak", "-Atc",
                     "SELECT tablename FROM pg_tables WHERE schemaname = 'public'", capture=True)
    names = set(tables.splitlines())
    require({"realm", "client", "databasechangelog"}.issubset(names) and
            not names.intersection({"appointments", "services", "service_prices", "vehicle_sizes",
                                    "businesses", "shops"}), "Auth database isolation check failed")
    compose("exec", "-T", "keycloak", "bash", "-ec",
            'exec 3<>/dev/tcp/auth-mail/1025; read -r greeting <&3; '
            '[[ "$greeting" == 220* ]]; printf "QUIT\\r\\n" >&3', capture=True)
    get_json("http://127.0.0.1:8025/api/v1/info")
    print("PASS: services healthy, DB readiness, canonical discovery/JWKS, live realm/client contract and SMTP")


def init():
    require(not ENV.exists(), "Local .env already exists; refusing to overwrite secrets")
    template = (ENV.parent / ".env.example").read_text()
    for _ in range(3):
        template = template.replace("replace-with-generated-local-secret", secrets.token_hex(32), 1)
    fd = os.open(ENV, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        stream.write(template)
    print("Created ignored infra/auth/.env with random local-only secrets (mode 0600)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["init", "check", "config-check", "up", "status",
                                            "logs", "stop", "smoke", "reset", "reconcile-callback"])
    parser.add_argument("--destroy-local-auth-state", action="store_true",
                        help="Required for reset: deletes ONLY this Compose project's auth volumes")
    args = parser.parse_args()
    if args.command == "init":
        init()
    elif args.command == "check":
        check_source()
    elif args.command == "config-check":
        check_source()
        check_compose()
    elif args.command == "smoke":
        smoke()
    elif args.command == "reconcile-callback":
        reconcile_callback()
    elif args.command == "reset":
        require(args.destroy_local_auth_state, "Reset requires --destroy-local-auth-state")
        check_source()
        check_compose()
        check_reset_ownership()
        # Fixed project/file/service set: no access to Scheduler DBs or volumes.
        compose("down", "--volumes")
        smoke()
        print("PASS: clean local-auth reset/rebootstrap and full smoke checks")
    else:
        commands = {"up": ("up", "-d", "--wait", "--wait-timeout", "240"),
                    "status": ("ps",), "logs": ("logs", "--tail", "100", "-f"),
                    "stop": ("stop",)}
        check_source()
        compose(*commands[args.command])


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, StopIteration) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
