import { test, expect, apiURL } from './fixtures'
import { customer, gate, followingWeek } from './booking-helpers'

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
