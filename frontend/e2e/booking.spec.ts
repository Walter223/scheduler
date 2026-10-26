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

async function openBooking(page: Page, booking: BookingData) {
  await page.goto('/')
  await expect(page.getByRole('link', { name: 'View Services', exact: true })).toHaveAttribute('href', '/services')
  await expect(page.getByRole('link', { name: 'Check Availability', exact: true })).toHaveAttribute('href', '/contact')
  await page.getByRole('navigation').getByRole('link', { name: 'Services', exact: true }).click()
  const service = page.getByRole('heading', { name: booking.service_name, exact: true }).locator('..')
  const option = service.getByRole('button', { name: new RegExp(booking.vehicle_size) })
  const book = service.getByRole('link', { name: 'Book This Detail' })
  await expect(book).toHaveAttribute('aria-disabled', 'true')
  await expect(book).toHaveAttribute('tabindex', '-1')
  await expect(option).toHaveAttribute('aria-pressed', 'false')
  await option.click()
  await expect(option).toHaveAttribute('aria-pressed', 'true')
  await expect(book).toHaveAttribute('aria-disabled', 'false')
  await expect(book).toHaveAttribute('tabindex', '0')
  await option.click()
  await expect(option).toHaveAttribute('aria-pressed', 'false')
  await expect(book).toHaveAttribute('aria-disabled', 'true')
  await option.click()
  await book.click()
  await expect(page).toHaveURL(new RegExp(`/contact\\?service=${booking.service_id}&size=\\d+$`))
  await page.getByLabel('Choose a Date').fill(booking.date)
  const slot = page.getByRole('button', { name: '9:00 AM', exact: true })
  await slot.click()
  await expect(slot).toHaveAttribute('aria-pressed', 'true')
  await expect(page.getByRole('button', { name: 'Book Appointment', exact: true })).toBeDisabled()
}

async function prepareBooking(page: Page, booking: BookingData) {
  await openBooking(page, booking)
  for (const [label, value] of Object.entries(customer)) {
    await page.getByLabel(label, { exact: true }).fill(value)
  }
  await expect(page.getByRole('button', { name: 'Book Appointment', exact: true })).toBeEnabled()
}

test('booking succeeds and displays the BookingConfirmation details', async ({ page, booking }) => {
  await prepareBooking(page, booking)
  const submitted = page.waitForResponse((response) =>
    response.url().endsWith('/api/appointments') && response.request().method() === 'POST'
  )
  await page.getByRole('button', { name: 'Book Appointment', exact: true }).click()
  const response = await submitted
  expect(response.status()).toBe(201)
  const { appointment } = await response.json()

  await expect(page.getByRole('heading', { name: "You're On The Schedule", exact: true })).toBeVisible()
  const confirmation = page.getByRole('main')
  const date = new Intl.DateTimeFormat('en-US', {
    month: 'long', day: 'numeric', year: 'numeric', timeZone: 'UTC',
  }).format(new Date(`${booking.date}T12:00:00Z`))
  for (const text of [booking.service_name, booking.vehicle_size, date, '9:00 AM', 'Toyota Camry', '90 min', '$89.99', 'pending', `Confirmation #${appointment.id}`]) {
    await expect(confirmation.getByText(text, { exact: true })).toBeVisible()
  }
  await expect(confirmation.getByText('Thanks, Alex Driver!', { exact: false })).toBeVisible()
  expect(appointment.starts_at).toBe(booking.starts_at)
  expect(appointment.customer_email).toBe(customer.Email)
  await page.getByRole('button', { name: 'Book Another Detail', exact: true }).click()
  await expect(page.getByRole('heading', { name: 'Contact & Availability', exact: true })).toBeVisible()
  await expect(page.getByLabel('Choose a Date')).toHaveValue('')
})

test('a competing booking refreshes slots and preserves the customer form', async ({ page, request, booking }) => {
  await prepareBooking(page, booking)

  // Another real API client claims the visible slot before the browser submits.
  const competing = await request.post(`${apiURL}/api/appointments`, {
    data: {
      service_price_id: booking.service_price_id,
      starts_at: booking.starts_at,
      customer_name: 'Other Customer',
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
