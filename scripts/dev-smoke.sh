#!/usr/bin/env bash
# Read-only probes of existing services. Never start/stop services or seed data.
set -euo pipefail
command -v python3 >/dev/null || { printf 'ERROR: python3 is required on PATH.\n' >&2; exit 1; }
python3 - <<'PY'
import json
import sys
import urllib.request

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
results = []
for port in (4000, 5173):
    url = f'http://localhost:{port}/api/services'
    try:
        with opener.open(url, timeout=5) as response:
            body = response.read(2_000_001)
            if len(body) > 2_000_000:
                raise ValueError('response exceeds smoke-check limit')
            data = json.loads(body)
        if not isinstance(data, list) or not all(
            isinstance(item, dict) and isinstance(item.get('id'), int)
            and isinstance(item.get('name'), str) and isinstance(item.get('prices'), list)
            for item in data
        ):
            raise ValueError('unexpected services response shape (expected catalog array)')
        results.append(data)
        print(f'PASS: {url} returned a valid catalog ({len(data)} services)')
    except (OSError, ValueError) as error:
        # Do not dump response bodies, headers or environment values.
        sys.exit(f'ERROR: {url} failed ({type(error).__name__}). Check the already-running backend/Vite proxy; this script starts nothing.')
if results[0] != results[1]:
    sys.exit('ERROR: backend and Vite catalogs differ; check the Vite /api upstream (or retry if the catalog changed during the probes).')
print('PASS: Vite /api proxy matches the backend catalog')
PY
