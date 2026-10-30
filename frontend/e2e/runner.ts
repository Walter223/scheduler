import { execFile } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'

const exec = promisify(execFile)
export async function fixtures(command: string, runId: string, ...args: string[]) {
  const { stdout } = await exec('mix', ['run', '--no-start', 'scripts/e2e.exs', command, runId, ...args], {
    cwd: fileURLToPath(new URL('../../backend', import.meta.url)),
    env: { ...process.env, MIX_ENV: 'test', MIX_TEST_PARTITION: '_e2e', PORT: '4002' },
    timeout: 30_000,
  })
  // Ecto's asynchronous log output can arrive after the result; use framing.
  return stdout.split('\n').find((line) => line.startsWith('MAGNUM_E2E_JSON:'))?.slice('MAGNUM_E2E_JSON:'.length) ?? ''
}
