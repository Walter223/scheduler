import { test, expect, apiURL } from './fixtures'
import { customer, gate, followingWeek } from './booking-helpers'

test('a competing booking refreshes slots and preserves the customer form', async ({ page, request, booking, contactPage }) => {
  await contactPage.openBooking(booking)
  await contactPage.fillCustomer(customer)
  await expect(contactPage.submitButton).toBeEnabled()

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
  await contactPage.submitButton.click()
  expect((await rejected).status()).toBe(422)
  const refreshedResponse = await refreshed
  expect(refreshedResponse.status()).toBe(200)
  const availability = await refreshedResponse.json()
  expect(availability.available_times).not.toContain('09:00')

  await expect(contactPage.alert).toHaveText(
    "We apologize, but that slot was just claimed.Another customer booked this time while you were completing your appointment. We've refreshed the available times below."
  )
  await expect(contactPage.timeSlot('9:00 AM')).toHaveCount(0)
  await expect(contactPage.selectedTimes).toHaveCount(0)
  await expect(contactPage.submitButton).toHaveCount(0)
  await contactPage.timeSlot('11:00 AM').click()
  for (const [label, value] of Object.entries(customer)) {
    await expect(contactPage.field(label)).toHaveValue(value)
  }
  await expect(contactPage.submitButton).toBeEnabled()
})


test('an obsolete conflict refresh cannot replace availability for a new date', async ({ page, request, booking, contactPage }) => {
  await contactPage.openBooking(booking)
  await contactPage.fillCustomer(customer)
  await expect(contactPage.submitButton).toBeEnabled()
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
  await contactPage.submitButton.click()
  await pending.promise
  const cancelled = page.waitForEvent('requestfailed', (request) => request.url().includes(`date=${booking.date}`))
  await contactPage.dateInput.fill(followingWeek(booking.date))
  await cancelled
  release.release()
  await finished.promise
  await expect(contactPage.timeSlot('9:00 AM')).toBeVisible()
  await expect(contactPage.alert).toHaveCount(0)
})

