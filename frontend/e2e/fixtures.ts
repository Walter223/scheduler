import { execFile } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { promisify } from 'node:util'
import { test as base, expect } from '@playwright/test'
import type { Service } from '../src/types/booking'

const exec = promisify(execFile)
export const apiURL = 'http://127.0.0.1:4002'

export type BookingData = {
  service_id: number
  service_price_id: number
  service_name: string
  vehicle_size: string
  date: string
  starts_at: string
  vehicle_size_id: number
  price_cents: number
  duration_minutes: number
}

export type CatalogData = { services: Service[]; date: string; starts_at: string }

async function fixtures(command: 'seed' | 'cleanup') {
  const { stdout } = await exec('mix', ['run', '--no-start', 'scripts/e2e.exs', command], {
    cwd: fileURLToPath(new URL('../../backend', import.meta.url)),
    env: { ...process.env, MIX_ENV: 'test', MIX_TEST_PARTITION: '_e2e', PORT: '4002' },
    timeout: 30_000,
  })
  return stdout.trim().split('\n').at(-1) ?? ''
}

export const test = base.extend<{
  catalog: CatalogData
  booking: BookingData
  packageName: string
  vehicleSize: string
}>({
  packageName: ['Mid Detail', { option: true }],
  vehicleSize: ['Small', { option: true }],
  catalog: async ({ page }, run) => {
    const catalog = JSON.parse(await fixtures('seed')) as CatalogData
    try {
      // Vite proxies same-origin API requests to the isolated test server.
      await run(catalog)
    } finally {
      await page.close()
      await fixtures('cleanup')
    }
  },
  booking: async ({ catalog, packageName, vehicleSize }, run) => {
    const service = catalog.services.find((entry) => entry.name === packageName)
    const price = service?.prices.find((entry) => entry.vehicle_size === vehicleSize)
    if (!service || !price) throw new Error(`Missing fixture offering: ${packageName}/${vehicleSize}`)
    await run({ ...price, service_id: service.id, service_name: service.name,
      date: catalog.date, starts_at: catalog.starts_at })
  },
})

export { expect }
