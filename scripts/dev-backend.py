#!/usr/bin/env python3
"""Start the existing local Phoenix backend with opt-in OIDC; never replaces servers."""
import argparse
import os
from pathlib import Path
import socket
import sys
import subprocess
import json
import hashlib
import datetime
import re

ROOT = Path(__file__).resolve().parents[1]

def environment(base, path):
    if base.get('MIX_ENV', 'dev') != 'dev' or base.get('CI') or base.get('DATABASE_URL'):
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

def preflight(env, backup=None, baseline=None):
    checked = dict(env)
    checked.pop('MAGNUM_DEV_BACKUP', None)
    checked.pop('MAGNUM_DEV_BASELINE', None)
    if backup: checked['MAGNUM_DEV_BACKUP'] = str(backup)
    if baseline: checked['MAGNUM_DEV_BASELINE'] = str(baseline)
    result = subprocess.run(['mix', 'run', '--no-start', 'scripts/dev_preflight.exs'],
                            cwd=ROOT/'backend', env=checked, text=True, capture_output=True)
    lines = [line.removeprefix('MAGNUM_DEV_PREFLIGHT ') for line in result.stdout.splitlines() if line.startswith('MAGNUM_DEV_PREFLIGHT ')]
    if result.returncode or len(lines) != 1:
        raise ValueError('Cannot verify local scheduler_api_dev connection/backup; no migration authorized')
    return json.loads(lines[0])

def pending_versions(info):
    files = sorted(int(path.name.split('_',1)[0]) for path in (ROOT/'backend/priv/repo/migrations').glob('*.exs') if re.match(r'^\d+_.+\.exs$',path.name))
    unknown = set(info['versions']) - set(files)
    if unknown: raise ValueError('Database has unknown migration versions; review target before proceeding')
    return [version for version in files if version not in info['versions']]

def migrate(env, confirmed):
    if confirmed != 'scheduler_api_dev':
        raise ValueError('Use --migrate --confirm-database scheduler_api_dev for an explicit local apply')
    if env.get('MIX_ENV') != 'dev' or env.get('CI') or env.get('DATABASE_URL'):
        raise ValueError('Migration opt-in is restricted to confirmed local development')
    info = preflight(env)
    if not pending_versions(info):
        print('PASS: schema already current; no migration needed')
        return
    directory = ROOT/'.local/backups'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    archive = directory / ('scheduler_api_dev-' + stamp + '.dump')
    baseline = archive.with_suffix('.baseline.json')
    verified = preflight(env, backup=archive)
    baseline.write_text(json.dumps(verified['snapshot'], sort_keys=True))
    baseline.chmod(0o600)
    archive.with_suffix('.sha256').write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + '\n')
    print('PASS: verified local backup:', archive)
    result = subprocess.run(['mix', 'ecto.migrate'], cwd=ROOT/'backend', env=env, capture_output=True)
    if result.returncode:
        raise ValueError('Migration failed; backup preserved. Review schema status before retrying; never reset')
    after = preflight(env, baseline=baseline)
    if pending_versions(after) or any(after['snapshot'].get(k) != v for k,v in verified['snapshot'].items()):
        raise ValueError('Migration/preservation check failed; backup retained; server not started')
    print('PASS: migrations up; all pre-existing table rows/columns preserved')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Validate secret configuration without starting or changing services')
    parser.add_argument('--migrate', action='store_true', help='Explicit local apply after target verification and verified backup')
    parser.add_argument('--confirm-database', help='Required exact local target for --migrate')
    args = parser.parse_args()
    env = environment(os.environ, ROOT / 'infra/auth/.env')
    if args.confirm_database and not args.migrate: raise ValueError('--confirm-database requires --migrate')
    if not args.check:
        for host in ('127.0.0.1', '::1'):
            try:
                with socket.create_connection((host, 4000), timeout=1):
                    raise ValueError('Port 4000 is occupied; existing server preserved. Stop it only with explicit approval.')
            except OSError:
                pass
    if args.migrate:
        if args.check: raise ValueError('--check cannot be combined with --migrate')
        migrate(env, args.confirm_database)
    info = preflight(env)
    pending = pending_versions(info)
    if pending: raise ValueError('Pending development migrations: ' + ', '.join(map(str,pending)) + '. Review, then explicitly use --migrate --confirm-database scheduler_api_dev (backup required).')
    if args.check:
        print('PASS: local database schema current; OIDC launcher configuration available; no services changed')
        return
    os.chdir(ROOT / 'backend')
    os.execvpe('mix', ['mix', 'phx.server'], env)

if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as error:
        sys.exit('ERROR: ' + str(error) if isinstance(error, ValueError) else 'ERROR: local launcher prerequisite unavailable; no services stopped')
