import type { Page } from '@playwright/test'
import { expect } from './fixtures'
import type { BookingData } from './fixtures'

export const customer = {
  'First Name': 'Alex',
  'Last Name': 'Driver',
  Email: 'alex@example.com',
  Phone: '303-555-0100',
  Make: 'Toyota',
  Model: 'Camry',
  Notes: 'Please call on arrival.',
}

export function gate() {
  let release = () => {}
  const promise = new Promise<void>((resolve) => { release = resolve })
  return { promise, release }
}

export function followingWeek(date: string) {
  const next = new Date(`${date}T12:00:00Z`)
  next.setUTCDate(next.getUTCDate() + 7)
  return next.toISOString().slice(0, 10)
}

export async function openBooking(page: Page, booking: BookingData) {
  await page.goto(`/contact?service=${booking.service_id}&size=${booking.vehicle_size_id}`)
  await page.getByLabel('Choose a Date').fill(booking.date)
  const slot = page.getByRole('button', { name: '9:00 AM', exact: true })
  await slot.click()
}

export async function prepareBooking(page: Page, booking: BookingData) {
  await openBooking(page, booking)
  for (const [label, value] of Object.entries(customer)) {
    await page.getByLabel(label, { exact: true }).fill(value)
  }
  await expect(page.getByRole('button', { name: 'Book Appointment', exact: true })).toBeEnabled()
}

