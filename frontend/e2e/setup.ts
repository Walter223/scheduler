import { randomUUID } from 'node:crypto'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fixtures } from './runner'

export default async function setup() {
  const runId = randomUUID()
  const directory = await mkdtemp(join(tmpdir(), 'magnum-anonymous-e2e-'))
  let seeded = false
  try {
    const output = await fixtures('seed', runId)
    seeded = true
    const catalog = JSON.parse(output)
    const manifest = join(directory, 'catalog.json')
    await writeFile(manifest, JSON.stringify({ runId, ...catalog }), { mode: 0o600 })
    // Playwright passes global-setup environment values to all test workers.
    process.env.MAGNUM_E2E_MANIFEST = manifest
  } catch (error) {
    try { if (seeded) await fixtures('cleanup', runId) }
    finally { await rm(directory, { recursive: true }) }
    throw error
  }
}
