import { readFile } from 'node:fs/promises'
import { test, expect } from '@playwright/test'
import type { Service } from '../src/types/booking'

// Read the invocation-owned catalog without allocating dates or launching a browser.
async function catalogServices() {
  const path = process.env.MAGNUM_E2E_MANIFEST
  if (!path) throw new Error('Missing invocation-owned E2E manifest')
  const { services } = JSON.parse(await readFile(path, 'utf8')) as { services: Service[] }
  return services
}

// Calendar arithmetic on Denver's date, independent of the host timezone and DST.
function dateAfter(days: number) {
  const today = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Denver',
    year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date())
  const date = new Date(`${today}T12:00:00Z`)
  date.setUTCDate(date.getUTCDate() + days)
  return date
}
const isoDate = (date: Date) => date.toISOString().slice(0, 10)

function expectPrivateDenial(status: number, headers: Record<string, string>, body: unknown) {
  expect(status).toBe(401)
  expect(headers['cache-control']).toBe('no-store')
  // Exact equality rules out customer fields, appointment arrays and pagination leaks.
  expect(body).toEqual({ error: 'authentication_required' })
}

test('public services expose the catalog JSON contract through the Vite proxy', async ({ request }) => {
  const response = await request.get('/api/services')
  expect(response.status()).toBe(200)
  expect(response.headers()['content-type']).toContain('application/json')
  const services = await response.json() as Service[]
  expect(services).toHaveLength(3)
  expect(services.map((service) => service.name).sort()).toEqual(['Basic Detail', 'Mid Detail', 'Supreme Detail'])
  for (const service of services) {
    expect(Object.keys(service).sort()).toEqual(['description', 'id', 'name', 'prices'])
    expect(Number.isSafeInteger(service.id) && service.id > 0).toBe(true)
    expect(typeof service.description).toBe('string')
    expect(service.prices).toHaveLength(3)
    expect(service.prices.map((price) => price.vehicle_size).sort()).toEqual(['Large', 'Medium', 'Small'])
    for (const price of service.prices) {
      expect(Object.keys(price).sort()).toEqual(['duration_minutes', 'price_cents', 'service_price_id', 'vehicle_size', 'vehicle_size_id'])
      for (const value of [price.service_price_id, price.vehicle_size_id, price.price_cents, price.duration_minutes]) {
        expect(Number.isSafeInteger(value) && value > 0).toBe(true)
      }
    }
  }
})

test('availability returns structured slots and representative validation errors', async ({ request }) => {
  const price = (await catalogServices())[0].prices[0]
  const future = dateAfter(2)
  if (future.getUTCDay() === 0) future.setUTCDate(future.getUTCDate() + 1)
  const date = isoDate(future)
  const sunday = dateAfter(1)
  sunday.setUTCDate(sunday.getUTCDate() + (7 - sunday.getUTCDay()) % 7)

  const response = await request.get('/api/availability', { params: { date, service_price_id: price.service_price_id } })
  expect(response.status()).toBe(200)
  const body = await response.json()
  expect(body).toEqual({ date, service_price_id: price.service_price_id,
    duration_minutes: price.duration_minutes, available_times: expect.any(Array) })
  for (const time of body.available_times) expect(time).toMatch(/^(09|1[0-7]):(00|30)$/)

  const cases = [
    { date: 'not-a-date', id: price.service_price_id, status: 422, field: 'date', code: 'invalid_date' },
    { date: isoDate(dateAfter(-2)), id: price.service_price_id, status: 422, field: 'date', code: 'past_date' },
    { date: isoDate(dateAfter(92)), id: price.service_price_id, status: 422, field: 'date', code: 'outside_booking_window' },
    { date: isoDate(sunday), id: price.service_price_id, status: 422, field: 'date', code: 'closed_sunday' },
    { date, id: 'invalid', status: 422, field: 'service_price_id', code: 'invalid_service_price_id' },
    { date, id: '9223372036854775807', status: 404, field: 'service_price_id', code: 'not_found' },
  ]
  for (const entry of cases) {
    const rejected = await request.get('/api/availability', { params: { date: entry.date, service_price_id: entry.id } })
    expect(rejected.status(), entry.code).toBe(entry.status)
    const error = await rejected.json()
    expect(error).toEqual({ error: { field: entry.field, code: entry.code, message: expect.any(String) } })
    expect(error.error.message.length).toBeGreaterThan(0)
  }
})

test('anonymous admin appointments are denied without exposing customer data', async ({ request }) => {
  const response = await request.get('/api/admin/appointments')
  expectPrivateDenial(response.status(), response.headers(), await response.json())
})

test('ownership selectors cannot bypass the admin session requirement', async ({ request }) => {
  const selectors: Record<string, string>[] = [
    { business_id: '1' }, { shop_id: '1' }, { user_id: '1' },
    { business_id: '1', shop_id: '1', user_id: '1', limit: 'invalid', cursor: 'forged' },
  ]
  for (const params of selectors) {
    const response = await request.get('/api/admin/appointments', { params })
    expectPrivateDenial(response.status(), response.headers(), await response.json())
  }
})
