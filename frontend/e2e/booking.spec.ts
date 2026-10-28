import type { Page } from '@playwright/test'
import { test, expect, apiURL } from './fixtures'
import type { BookingData } from './fixtures'

const customer = {
  'First Name': 'Alex',
  'Last Name': 'Driver',
  Email: 'alex@example.com',
  Phone: '303-555-0100',
  Make: 'Toyota',
  Model: 'Camry',
  Notes: 'Please call on arrival.',
}

function gate() {
  let release = () => {}
  const promise = new Promise<void>((resolve) => { release = resolve })
  return { promise, release }
}

function followingWeek(date: string) {
  const next = new Date(`${date}T12:00:00Z`)
  next.setUTCDate(next.getUTCDate() + 7)
  return next.toISOString().slice(0, 10)
}

async function openBooking(page: Page, booking: BookingData) {
  await page.goto(`/contact?service=${booking.service_id}&size=${booking.vehicle_size_id}`)
  await page.getByLabel('Choose a Date').fill(booking.date)
  const slot = page.getByRole('button', { name: '9:00 AM', exact: true })
  await slot.click()
}

async function prepareBooking(page: Page, booking: BookingData) {
  await openBooking(page, booking)
  for (const [label, value] of Object.entries(customer)) {
    await page.getByLabel(label, { exact: true }).fill(value)
  }
  await expect(page.getByRole('button', { name: 'Book Appointment', exact: true })).toBeEnabled()
}

for (const offering of [
  { name: 'Basic Detail', size: 'Small', price: '$59.99', duration: '60 min' },
  { name: 'Mid Detail', size: 'Medium', price: '$119.99', duration: '120 min' },
  { name: 'Supreme Detail', size: 'Large', price: '$179.99', duration: '230 min' },
]) {
  test.describe(offering.name, () => {
    test.use({ packageName: offering.name, vehicleSize: offering.size, timezoneId: 'Asia/Tokyo' })
    test('books through Services and displays saved confirmation in Denver time', async ({ page, booking }) => {
      await page.goto('/')
      await page.getByRole('navigation').getByRole('link', { name: 'Services', exact: true }).click()
      // Service cards are unnamed sections; scope by their visible package heading.
      const service = page.getByRole('heading', { name: offering.name, exact: true }).locator('..')
      await service.getByRole('button', { name: new RegExp(`^${offering.size} `) }).click()
      await service.getByRole('link', { name: 'Book This Detail' }).click()
      await page.getByLabel('Choose a Date').fill(booking.date)
      await page.getByRole('button', { name: '9:00 AM', exact: true }).click()
      for (const [label, value] of Object.entries(customer)) {
        await page.getByLabel(label, { exact: true }).fill(value)
      }
      const pending = gate()
      const release = gate()
      await page.route('**/api/appointments', async (route) => {
        const response = await route.fetch({ url: `${apiURL}/api/appointments` })
        pending.release()
        await release.promise
        await route.fulfill({ response, headers: { ...response.headers(), 'access-control-allow-origin': 'http://127.0.0.1:5174' } })
      })
      const submitted = page.waitForResponse((response) =>
        response.url().endsWith('/api/appointments') && response.request().method() === 'POST'
      )
      await page.getByRole('button', { name: 'Book Appointment', exact: true }).click()
      await pending.promise
      // The saved confirmation must survive changes made while submission is pending.
      await page.getByLabel('First Name', { exact: true }).fill('Unsaved')
      await page.getByLabel('Last Name', { exact: true }).fill('Changes')
      await page.getByLabel('Choose a Date').fill(followingWeek(booking.date))
      release.release()
      const response = await submitted
      expect(response.status()).toBe(201)
      const { appointment } = await response.json()

      await expect(page.getByRole('heading', { name: "You're On The Schedule", exact: true })).toBeVisible()
      const confirmation = page.getByRole('main')
      const date = new Intl.DateTimeFormat('en-US', {
        month: 'long', day: 'numeric', year: 'numeric', timeZone: 'UTC',
      }).format(new Date(`${booking.date}T12:00:00Z`))
      for (const text of [booking.service_name, booking.vehicle_size, date, '9:00 AM', 'Toyota Camry', offering.duration, offering.price, 'pending', `Confirmation #${appointment.id}`]) {
        await expect(confirmation.getByText(text, { exact: true })).toBeVisible()
      }
      await expect(confirmation.getByText('Thanks, Alex Driver!', { exact: false })).toBeVisible()
      expect(appointment.starts_at).toBe(booking.starts_at)
      expect(appointment.service_price_id).toBe(booking.service_price_id)
      expect(appointment.customer_email).toBe(customer.Email)
      expect(appointment.customer_first_name).toBe(customer['First Name'])
      expect(appointment.customer_last_name).toBe(customer['Last Name'])
      expect(appointment).not.toHaveProperty('customer_name')
      const payload = response.request().postDataJSON()
      expect(payload.service_price_id).toBe(booking.service_price_id)
      expect(payload.customer_first_name).toBe(customer['First Name'])
      expect(payload.customer_last_name).toBe(customer['Last Name'])
      expect(payload).not.toHaveProperty('customer_name')
      await page.getByRole('button', { name: 'Book Another Detail', exact: true }).click()
      await expect(page).toHaveURL(/\/services$/)
      await expect(page.getByRole('heading', { name: 'Magnum Detailing Services', exact: true })).toBeVisible()
    })
  })
}

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


test('validated fields preserve blur validation, label associations and phone formatting', async ({ page, booking }) => {
  await openBooking(page, booking)
  await expect(page.getByRole('button', { name: '9:00 AM', exact: true })).toHaveAttribute('aria-pressed', 'true')
  await expect(page.getByRole('button', { name: 'Book Appointment', exact: true })).toBeDisabled()
  const fields = [
    { label: 'First Name', id: 'first-name', type: 'text', invalid: '123', corrected: '  Alex  ', expected: 'Alex', message: 'Please enter a valid first name' },
    { label: 'Last Name', id: 'last-name', type: 'text', invalid: '456', corrected: '  Driver  ', expected: 'Driver', message: 'Please enter a valid last name' },
    { label: 'Email', id: 'customer-email', type: 'email', invalid: 'invalid', corrected: 'alex@example.com', expected: 'alex@example.com', message: 'Please enter a valid email address' },
    { label: 'Phone', id: 'customer-phone', type: 'tel', invalid: '123', corrected: '3035550100', expected: '303-555-0100', message: 'A valid phone number is required in this field' },
    { label: 'Make', id: 'vehicle-make', type: 'text', invalid: '   ', corrected: '  Toyota  ', expected: 'Toyota', message: 'Please enter the Make of your vehicle' },
    { label: 'Model', id: 'vehicle-model', type: 'text', invalid: '   ', corrected: '  Camry  ', expected: 'Camry', message: 'Please enter the model of your vehicle' },
  ]

  for (const field of fields) {
    const input = page.getByLabel(field.label, { exact: true })
    await expect(input).toHaveAttribute('id', field.id)
    await expect(input).toHaveAttribute('type', field.type)
    await expect(input).toHaveAttribute('aria-invalid', 'false')
    expect(await input.getAttribute('aria-describedby')).toBeNull()
    await expect(page.locator(`[id="${field.id}-error"]`)).toHaveCount(0)
    expect(await input.evaluate((element) => {
      return element.previousElementSibling?.getAttribute('for') === element.id &&
        element.parentElement?.className === 'booking-form-section'
    })).toBe(true)
  }

  for (const field of fields) {
    const input = page.getByLabel(field.label, { exact: true })
    const errorId = `${field.id}-error`
    const error = page.locator(`[id="${errorId}"]`)
    await page.getByText(field.label, { exact: true }).click()
    await expect(input).toBeFocused()
    await input.fill(field.invalid)
    await expect(input).toHaveAttribute('aria-invalid', 'false')
    await input.blur()
    await expect(input).toHaveAttribute('aria-invalid', 'true')
    await expect(input).toHaveAttribute('aria-describedby', errorId)
    await expect(error).toHaveText(field.message)
    expect(await input.evaluate((element, id) => element.nextElementSibling?.id === id, errorId)).toBe(true)

    await input.fill(field.corrected)
    await input.blur()
    await expect(input).toHaveValue(field.expected)
    await expect(input).toHaveAttribute('aria-invalid', 'false')
    await expect(error).toHaveCount(0)
    expect(await input.getAttribute('aria-describedby')).toBeNull()
  }

  const phone = page.getByLabel('Phone', { exact: true })
  await phone.fill('18015551234')
  await expect(phone).toHaveValue('1-801-555-1234')
  await phone.fill('+44 20 1234 5678')
  await expect(phone).toHaveValue('+442012345678')
  await phone.blur()
  await expect(phone).toHaveAttribute('aria-invalid', 'false')
  await expect(page.getByRole('button', { name: 'Book Appointment', exact: true })).toBeEnabled()
})


test('backend customer field errors identify the field and preserve the form', async ({ page, booking }) => {
  await prepareBooking(page, booking)
  const make = 'T'.repeat(256)
  await page.getByLabel('Make', { exact: true }).fill(make)
  await page.getByRole('button', { name: 'Book Appointment', exact: true }).click()
  await expect(page.getByRole('alert')).toContainText('Vehicle make: should be at most 255 character(s)')
  await expect(page.getByLabel('Make', { exact: true })).toHaveValue(make)
  await expect(page.getByLabel('Email', { exact: true })).toHaveValue(customer.Email)
})

test('obsolete availability requests are cancelled when the date changes', async ({ page, booking }) => {
  await openBooking(page, booking)
  const pending = gate()
  const release = gate()
  const finished = gate()
  const oldDate = followingWeek(booking.date)
  await page.route('**/api/availability?**', async (route) => {
    if (new URL(route.request().url()).searchParams.get('date') !== oldDate) return route.fallback()
    pending.release()
    await release.promise
    await route.fulfill({ json: { available_times: [] } })
    finished.release()
  })
  await page.getByLabel('Choose a Date').fill(oldDate)
  await pending.promise
  const cancelled = page.waitForEvent('requestfailed', (request) => request.url().includes(`date=${oldDate}`))
  await page.getByLabel('Choose a Date').fill(booking.date)
  await cancelled
  release.release()
  await finished.promise
  await expect(page.getByRole('button', { name: '9:00 AM', exact: true })).toBeVisible()
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

test.describe('Denver calendar date', () => {
  test.use({ timezoneId: 'Asia/Tokyo' })
  test('the minimum date follows Denver at midnight boundaries', async ({ page, booking }) => {
    // Tokyo is on the following day at this instant, in either Denver DST season.
    const instant = new Date(`${booking.date}T23:30:00Z`)
    await page.clock.setFixedTime(instant)
    await openBooking(page, booking)
    await expect(page.getByLabel('Choose a Date')).toHaveAttribute('min', booking.date)
  })
})
