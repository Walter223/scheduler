#!/usr/bin/env python3
"""Read-only local auth checks; never starts services, signs in or creates transactions."""
import json
from pathlib import Path
import socket
import subprocess
import sys
import urllib.request
import urllib.error
ROOT = Path(__file__).resolve().parents[1]

def main():
    failed = False
    for host, port in [('127.0.0.1',4000),('localhost',5173)]:
        try:
            with socket.create_connection((host,port),2): pass
            print(f'PASS: listener {host}:{port}')
        except OSError:
            failed = True
            print(f'FAIL: no reachable listener {host}:{port}')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for url, kind in [('http://127.0.0.1:4000/api/me','session'),('http://localhost:5173/api/me','session'),('http://auth.magnum.test:8080/realms/magnum/.well-known/openid-configuration','discovery')]:
        try:
            with opener.open(url,timeout=4) as response:
                data = json.loads(response.read(1_000_000))
            valid = isinstance(data.get('authenticated'), bool) if kind == 'session' else data.get('issuer') == 'http://auth.magnum.test:8080/realms/magnum'
            if not valid: raise ValueError('Contract mismatch')
            print(f'PASS: {url}')
        except (OSError,ValueError):
            failed = True
            print(f'FAIL: {url} (no response details exposed)')
    checked = subprocess.run([sys.executable,str(ROOT/'scripts/dev-backend.py'),'--check'],capture_output=True)
    print('PASS: launcher environment contract available' if checked.returncode == 0 else 'FAIL: launcher configuration unavailable')
    print('NOTE: this does not prove running OIDC readiness, client-secret validity or a personal login.')
    return 1 if failed or checked.returncode else 0

if __name__ == '__main__':
    sys.exit(main())
