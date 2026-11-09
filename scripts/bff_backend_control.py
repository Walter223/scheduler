#!/usr/bin/env python3
"""Test-only IPC with the parent runner; cannot signal arbitrary PIDs or dev servers."""
import json
import os
from pathlib import Path
import sys
import time

def main():
    if os.environ.get('MIX_ENV') != 'test' or os.environ.get('MIX_TEST_PARTITION') != '_auth_e2e':
        raise ValueError('Isolated runner required')
    path = Path(os.environ['BFF_E2E_BACKEND_CONTROL'])
    fixture = Path(os.environ['BFF_E2E_FIXTURE'])
    if path.parent != fixture.parent or path.name != 'backend-control.json' or not fixture.is_file():
        raise ValueError('Owned fixture directory required')
    action, = sys.argv[1:]
    if action not in ('stop', 'start'):
        raise ValueError('Invalid action')
    response = path.with_suffix('.response')
    response.unlink(missing_ok=True)
    temporary = path.with_suffix('.request')
    temporary.write_text(json.dumps({'action': action}))
    temporary.replace(path)
    deadline = time.monotonic() + 65
    while not response.exists():
        if time.monotonic() >= deadline:
            raise ValueError('Owned server control timed out')
        time.sleep(0.1)  # infrastructure acknowledgement polling, not browser sleeps
    if json.loads(response.read_text()) != {'ok': True}:
        raise ValueError('Owned server action failed')
    print('PASS: owned test backend ' + action)

if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError):
        sys.exit('ERROR: isolated backend control failed; no development server targeted')
