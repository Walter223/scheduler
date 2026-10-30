import { test, expect } from './fixtures'
import { gate, followingWeek, openBooking } from './booking-helpers'

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
