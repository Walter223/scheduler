import { readFile } from 'node:fs/promises'
import { fixtures } from './runner'
import { test as base, expect } from '@playwright/test'
import type { Service } from '../src/types/booking'
import { HomePage } from './pages/HomePage'
import { ServicesPage } from './pages/ServicesPage'
import { ContactPage } from './pages/ContactPage'

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

export type CatalogData = { services: Service[] }

export const test = base.extend<{
  catalog: CatalogData
  booking: BookingData
  homePage: HomePage
  servicesPage: ServicesPage
  contactPage: ContactPage
  packageName: string
  vehicleSize: string
}>({
  packageName: ['Mid Detail', { option: true }],
  vehicleSize: ['Small', { option: true }],
  homePage: async ({ page }, run) => { await run(new HomePage(page)) },
  servicesPage: async ({ page }, run) => { await run(new ServicesPage(page)) },
  contactPage: async ({ page }, run) => { await run(new ContactPage(page)) },
  catalog: async ({ packageName }, run) => {
    const shared = await sharedCatalog()
    if (!shared.services.some((service) => service.name === packageName)) throw new Error('Missing fixture package')
    await run({ services: shared.services })
  },
  booking: async ({ page, catalog, packageName, vehicleSize }, run) => {
    const service = catalog.services.find((entry) => entry.name === packageName)
    const price = service?.prices.find((entry) => entry.vehicle_size === vehicleSize)
    if (!service || !price) throw new Error(`Missing fixture offering: ${packageName}/${vehicleSize}`)
    const { runId } = await sharedCatalog()
    // Every attempt (including retries in replacement workers) reserves a NEW date.
    // Only nine booking-dependent tests allocate: at most 27 attempts with CI retries.
    const slot = JSON.parse(await fixtures('allocate', runId)) as { slot_id: number; date: string; starts_at: string }
    try {
      await run({ ...price, service_id: service.id, service_name: service.name,
        date: slot.date, starts_at: slot.starts_at })
    } finally {
      // Stop late browser writes before deleting this attempt's owned bookings.
      // Cleanup still runs if closing an already-failed browser reports an error.
      try { await page.close() }
      finally { await fixtures('cleanup-slot', runId, String(slot.slot_id)) }
    }
  },
})

async function sharedCatalog() {
  const path = process.env.MAGNUM_E2E_MANIFEST
  if (!path) throw new Error('Missing invocation-owned E2E manifest')
  return JSON.parse(await readFile(path, 'utf8')) as { runId: string; services: Service[] }
}

export { expect }
