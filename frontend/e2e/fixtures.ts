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
      // Forward every browser API call to the real isolated Phoenix test server.
      // No canned responses; this also prevents any writes to the dev API.
      await page.route('http://localhost:4000/api/**', async (route) => {
        const url = new URL(route.request().url())
        const response = await route.fetch({ url: `${apiURL}${url.pathname}${url.search}` })
        await route.fulfill({
          response,
          headers: {
            ...response.headers(),
            'access-control-allow-origin': 'http://127.0.0.1:5174',
          },
        })
      })
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
