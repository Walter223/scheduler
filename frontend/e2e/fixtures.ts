import { readFile } from 'node:fs/promises'
import { fixtures } from './runner'
import { test as base, expect } from '@playwright/test'
import type { Service } from '../src/types/booking'

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

export const test = base.extend<{
  catalog: CatalogData
  booking: BookingData
  packageName: string
  vehicleSize: string
}>({
  packageName: ['Mid Detail', { option: true }],
  vehicleSize: ['Small', { option: true }],
  catalog: async ({ page }, run) => {
    const path = process.env.MAGNUM_E2E_MANIFEST
    if (!path) throw new Error('Missing invocation-owned E2E manifest')
    const shared = JSON.parse(await readFile(path, 'utf8')) as { runId: string; services: Service[] }
    const slot = JSON.parse(await fixtures('allocate', shared.runId)) as { slot_id: number; date: string; starts_at: string }
    try {
      await run({ services: shared.services, date: slot.date, starts_at: slot.starts_at })
    } finally {
      await page.close()
      await fixtures('cleanup-slot', shared.runId, String(slot.slot_id))
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
