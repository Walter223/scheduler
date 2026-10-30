import { test, expect, apiURL } from './fixtures'
import { customer, gate, followingWeek, prepareBooking } from './booking-helpers'

test('a competing booking refreshes slots and preserves the customer form', async ({ page, request, booking }) => {
  await prepareBooking(page, booking)

  // Another real API client claims the visible slot before the browser submits.
  const competing = await request.post(`${apiURL}/api/appointments`, {
    data: {
      service_price_id: booking.service_price_id,
      starts_at: booking.starts_at,
      customer_first_name: 'Other', customer_last_name: 'Customer',
      customer_email: 'other@example.com',
      customer_phone: '3035550123',
      vehicle_make: 'Honda',
      vehicle_model: 'Civic',
    },
  })
  expect(competing.status()).toBe(201)

  const rejected = page.waitForResponse((response) =>
    response.url().endsWith('/api/appointments') && response.request().method() === 'POST'
  )
  const refreshed = page.waitForResponse((response) => response.url().includes('/api/availability?'))
  await page.getByRole('button', { name: 'Book Appointment', exact: true }).click()
  expect((await rejected).status()).toBe(422)
  const refreshedResponse = await refreshed
  expect(refreshedResponse.status()).toBe(200)
  const availability = await refreshedResponse.json()
  expect(availability.available_times).not.toContain('09:00')

  await expect(page.getByRole('alert')).toHaveText(
    "We apologize, but that slot was just claimed.Another customer booked this time while you were completing your appointment. We've refreshed the available times below."
  )
  await expect(page.getByRole('button', { name: '9:00 AM', exact: true })).toHaveCount(0)
  await expect(page.getByRole('button', { pressed: true })).toHaveCount(0)
  await expect(page.getByRole('button', { name: 'Book Appointment', exact: true })).toHaveCount(0)
  await page.getByRole('button', { name: '11:00 AM', exact: true }).click()
  for (const [label, value] of Object.entries(customer)) {
    await expect(page.getByLabel(label, { exact: true })).toHaveValue(value)
  }
  await expect(page.getByRole('button', { name: 'Book Appointment', exact: true })).toBeEnabled()
})


test('an obsolete conflict refresh cannot replace availability for a new date', async ({ page, request, booking }) => {
  await prepareBooking(page, booking)
  const competing = await request.post(`${apiURL}/api/appointments`, {
    data: {
      service_price_id: booking.service_price_id, starts_at: booking.starts_at,
      customer_first_name: 'Other', customer_last_name: 'Customer', customer_email: 'other@example.com',
      customer_phone: '3035550123', vehicle_make: 'Honda', vehicle_model: 'Civic',
    },
  })
  expect(competing.status()).toBe(201)
  const pending = gate()
  const release = gate()
  const finished = gate()
  await page.route('**/api/availability?**', async (route) => {
    if (new URL(route.request().url()).searchParams.get('date') !== booking.date) return route.fallback()
    pending.release()
    await release.promise
    await route.fulfill({ json: { available_times: [] } })
    finished.release()
  })
  await page.getByRole('button', { name: 'Book Appointment', exact: true }).click()
  await pending.promise
  const cancelled = page.waitForEvent('requestfailed', (request) => request.url().includes(`date=${booking.date}`))
  await page.getByLabel('Choose a Date').fill(followingWeek(booking.date))
  await cancelled
  release.release()
  await finished.promise
  await expect(page.getByRole('button', { name: '9:00 AM', exact: true })).toBeVisible()
  await expect(page.getByRole('alert')).toHaveCount(0)
})

