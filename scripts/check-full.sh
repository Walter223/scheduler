#!/usr/bin/env bash
set -euo pipefail
trap 'printf "ERROR: check-full failed at line %s (exit %s).\n" "$LINENO" "$?" >&2' ERR
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
for tool in mix npm python3; do
  command -v "$tool" >/dev/null || { printf 'ERROR: %s is required on PATH.\n' "$tool" >&2; exit 1; }
done
# Refuse conflicts before precommit or fixture setup; never stop existing servers.
python3 - <<'PY'
import socket
import sys
for port in (4002, 5174):
    for host in ('127.0.0.1', '::1'):
        try:
            connection = socket.create_connection((host, port), timeout=0.5)
        except PermissionError:
            sys.exit(f'ERROR: permission denied inspecting port {port}; cannot safely verify Playwright prerequisites.')
        except OSError:
            continue
        connection.close()
        sys.exit(f'ERROR: port {port} is occupied. Free the isolated Playwright port before running check-full; no services were stopped.')
PY
# Explicit test environment/partition; Keycloak is optional, never a prerequisite.
# precommit includes compile --warnings-as-errors, format and mix test.
(cd "$ROOT/backend" && MIX_ENV=test MIX_TEST_PARTITION='' MAGNUM_OIDC_ENABLED=false mix precommit)
(cd "$ROOT/frontend" && npm run test:component && npm run lint && npm run build && MAGNUM_OIDC_ENABLED=false npm run test:e2e)
printf 'PASS: full anonymous regression (real-Keycloak tests are separate)\n'
