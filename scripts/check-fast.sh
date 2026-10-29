#!/usr/bin/env bash
# No servers, browser suites, database setup, or dependency installation.
set -euo pipefail
trap 'printf "ERROR: check-fast failed at line %s (exit %s).\n" "$LINENO" "$?" >&2' ERR
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
for tool in mix npm; do
  command -v "$tool" >/dev/null || { printf 'ERROR: %s is required on PATH.\n' "$tool" >&2; exit 1; }
done
(cd "$ROOT/backend" && mix format --check-formatted)
(cd "$ROOT/frontend" && npm run lint && npm run test:component)
printf 'PASS: fast checks\n'
