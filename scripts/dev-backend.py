#!/usr/bin/env python3
"""Start the existing local Phoenix backend with opt-in OIDC; never replaces servers."""
import argparse
import os
from pathlib import Path
import socket
import sys

ROOT = Path(__file__).resolve().parents[1]

def environment(base, path):
    if base.get('MIX_ENV', 'dev') != 'dev':
        raise ValueError('This launcher is development-only')
    secret = None
    for line in path.read_text().splitlines():
        key, separator, value = line.partition('=')
        if separator and key.strip() == 'MAGNUM_WEB_CLIENT_SECRET':
            secret = value.strip()
    if not secret or secret.startswith(('"', "'")):
        raise ValueError('Missing or unsupported local client secret; use the auth.py-generated env file')
    return {**base, 'MIX_ENV': 'dev', 'MAGNUM_OIDC_ENABLED': 'true',
            'MAGNUM_WEB_CLIENT_SECRET': secret, 'PORT': '4000',
            'MAGNUM_APP_ORIGIN': 'http://localhost:5173',
            'OIDC_ISSUER': 'http://auth.magnum.test:8080/realms/magnum',
            'OIDC_CLIENT_ID': 'magnum-web',
            'OIDC_REDIRECT_URI': 'http://localhost:5173/auth/callback'}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Validate secret configuration without starting or changing services')
    args = parser.parse_args()
    env = environment(os.environ, ROOT / 'infra/auth/.env')
    if args.check:
        print('PASS: local OIDC environment can be supplied; no secret values printed, no services changed')
        return
    for host in ('127.0.0.1', '::1'):
        try:
            with socket.create_connection((host, 4000), timeout=1):
                raise ValueError('Port 4000 is occupied; existing server preserved. Stop it only with explicit approval.')
        except OSError:
            pass
    os.chdir(ROOT / 'backend')
    os.execvpe('mix', ['mix', 'phx.server'], env)

if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError):
        sys.exit('ERROR: local backend prerequisites failed; no services were stopped. Check port 4000, MIX_ENV and ignored infra/auth/.env.')
