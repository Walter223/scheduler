#!/usr/bin/env python3
"""Read-only LOCAL signup readiness; isolated test success is not development readiness."""
import sys
import urllib.request
import urllib.error
import json
import subprocess
import auth


def registration_ready(realm):
    auth.require(realm.get('realm') == 'magnum' and realm.get('enabled'), 'Expected enabled local magnum realm')
    auth.require(realm.get('registrationAllowed'), 'Registration disabled: local Create an account cannot work')
    auth.require(realm.get('verifyEmail'), 'Email verification must remain required')
    auth.require(realm.get('smtpServer') == auth.SMTP, 'Email must use the approved local Mailpit sink')


def main():
    auth.check_reset_ownership()
    auth.check_compose()
    realm, clients = auth.admin_get('realms/magnum', 'realms/magnum/clients')
    registration_ready(realm)
    # The existing contract checks exact callback, grant restrictions, S256 and SMTP.
    auth.check_contract({**realm, 'clients': clients})
    auth.get_json('http://localhost:8025/api/v1/info')
    result = subprocess.run([sys.executable, str(auth.ROOT/'scripts/dev-auth-health.py')])
    auth.require(result.returncode == 0, 'Phoenix/Vite/OIDC configuration or development schema is not ready')
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for path, expected in [('/platform', 200), ('/signup', 200), ('/auth/signup/timezones', 200), ('/auth/signup', 403)]:
        try:
            response = opener.open('http://localhost:5173'+path, timeout=5)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            auth.require(response.code == expected, 'Unexpected signup route status: '+path)
            if path == '/auth/signup':
                auth.require(json.load(response).get('error') in ('signup_verification_required', 'signup_unavailable'), 'First-visit signup contract is outdated')
    print('PASS: LOCAL registration, required email verification/local sink, OIDC client, Phoenix/Vite, migrations and signup routes')
    print('NOTE: Mailpit captures local verification mail at http://localhost:8025; this is not external email delivery or personal browser acceptance.')

if __name__ == '__main__':
    try:
        main()
    except Exception:
        print('FAIL: local signup not ready. Check registrationAllowed, verifyEmail, local Mailpit, client contract, backend/schema and routes. No credentials exposed.', file=sys.stderr)
        sys.exit(1)
