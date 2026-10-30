import { test, expect } from './fixtures'
import { customer, openBooking, prepareBooking } from './booking-helpers'

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

