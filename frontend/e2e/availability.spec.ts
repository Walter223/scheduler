import { test, expect } from './fixtures'
import { gate, followingWeek } from './booking-helpers'

test('obsolete availability requests are cancelled when the date changes', async ({ page, booking, contactPage }) => {
  await contactPage.openBooking(booking)
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
  await contactPage.dateInput.fill(oldDate)
  await pending.promise
  const cancelled = page.waitForEvent('requestfailed', (request) => request.url().includes(`date=${oldDate}`))
  await contactPage.dateInput.fill(booking.date)
  await cancelled
  release.release()
  await finished.promise
  await expect(contactPage.timeSlot('9:00 AM')).toBeVisible()
})

test.describe('Denver calendar date', () => {
  test.use({ timezoneId: 'Asia/Tokyo' })
  test('the minimum date follows Denver at midnight boundaries', async ({ page, booking, contactPage }) => {
    // Tokyo is on the following day at this instant, in either Denver DST season.
    const instant = new Date(`${booking.date}T23:30:00Z`)
    await page.clock.setFixedTime(instant)
    await contactPage.openBooking(booking)
    await expect(contactPage.dateInput).toHaveAttribute('min', booking.date)
  })
})
