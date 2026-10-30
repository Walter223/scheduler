import { test, expect, apiURL } from './fixtures'
import { customer, gate, followingWeek } from './booking-helpers'

for (const offering of [
  { name: 'Basic Detail', size: 'Small', price: '$59.99', duration: '60 min' },
  { name: 'Mid Detail', size: 'Medium', price: '$119.99', duration: '120 min' },
  { name: 'Supreme Detail', size: 'Large', price: '$179.99', duration: '230 min' },
]) {
  test.describe(offering.name, () => {
    test.use({ packageName: offering.name, vehicleSize: offering.size, timezoneId: 'Asia/Tokyo' })
    test('books through Services and displays saved confirmation in Denver time', async ({ page, booking, homePage, servicesPage, contactPage }) => {
      await homePage.goto()
      await homePage.openServices()
      await servicesPage.selectDetail(offering.name, offering.size)
      await servicesPage.bookDetail(offering.name)
      await contactPage.dateInput.fill(booking.date)
      await contactPage.timeSlot('9:00 AM').click()
      await contactPage.fillCustomer(customer)
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
      await contactPage.submitButton.click()
      await pending.promise
      // The saved confirmation must survive changes made while submission is pending.
      await contactPage.field('First Name').fill('Unsaved')
      await contactPage.field('Last Name').fill('Changes')
      await contactPage.dateInput.fill(followingWeek(booking.date))
      release.release()
      const response = await submitted
      expect(response.status()).toBe(201)
      const { appointment } = await response.json()

      await expect(contactPage.confirmationHeading).toBeVisible()
      const date = new Intl.DateTimeFormat('en-US', {
        month: 'long', day: 'numeric', year: 'numeric', timeZone: 'UTC',
      }).format(new Date(`${booking.date}T12:00:00Z`))
      for (const text of [booking.service_name, booking.vehicle_size, date, '9:00 AM', 'Toyota Camry', offering.duration, offering.price, 'pending', `Confirmation #${appointment.id}`]) {
        await expect(contactPage.confirmationText(text)).toBeVisible()
      }
      await expect(contactPage.confirmationText('Thanks, Alex Driver!', false)).toBeVisible()
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
      await contactPage.bookAnotherButton.click()
      await expect(page).toHaveURL(/\/services$/)
      await expect(servicesPage.heading).toBeVisible()
    })
  })
}
