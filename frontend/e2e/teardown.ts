import { readFile, rm } from 'node:fs/promises'
import { dirname } from 'node:path'
import { fixtures } from './runner'

export default async function teardown() {
  const path = process.env.MAGNUM_E2E_MANIFEST
  if (!path) return
  const { runId } = JSON.parse(await readFile(path, 'utf8')) as { runId: string }
  // Runs after all workers; no per-test teardown can delete the shared catalog.
  await fixtures('cleanup', runId)
  await rm(dirname(path), { recursive: true })
}
