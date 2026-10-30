import { test, expect } from './fixtures'
import { customer } from './booking-helpers'

test('validated fields preserve blur validation, label associations and phone formatting', async ({ booking, contactPage }) => {
  await contactPage.openBooking(booking)
  await expect(contactPage.timeSlot('9:00 AM')).toHaveAttribute('aria-pressed', 'true')
  await expect(contactPage.submitButton).toBeDisabled()
  const fields = [
    { label: 'First Name', id: 'first-name', type: 'text', invalid: '123', corrected: '  Alex  ', expected: 'Alex', message: 'Please enter a valid first name' },
    { label: 'Last Name', id: 'last-name', type: 'text', invalid: '456', corrected: '  Driver  ', expected: 'Driver', message: 'Please enter a valid last name' },
    { label: 'Email', id: 'customer-email', type: 'email', invalid: 'invalid', corrected: 'alex@example.com', expected: 'alex@example.com', message: 'Please enter a valid email address' },
    { label: 'Phone', id: 'customer-phone', type: 'tel', invalid: '123', corrected: '3035550100', expected: '303-555-0100', message: 'A valid phone number is required in this field' },
    { label: 'Make', id: 'vehicle-make', type: 'text', invalid: '   ', corrected: '  Toyota  ', expected: 'Toyota', message: 'Please enter the Make of your vehicle' },
    { label: 'Model', id: 'vehicle-model', type: 'text', invalid: '   ', corrected: '  Camry  ', expected: 'Camry', message: 'Please enter the model of your vehicle' },
  ]

  for (const field of fields) {
    const input = contactPage.field(field.label)
    await expect(input).toHaveAttribute('id', field.id)
    await expect(input).toHaveAttribute('type', field.type)
    await expect(input).toHaveAttribute('aria-invalid', 'false')
    expect(await input.getAttribute('aria-describedby')).toBeNull()
    await expect(contactPage.fieldError(field.id)).toHaveCount(0)
    expect(await input.evaluate((element) => {
      return element.previousElementSibling?.getAttribute('for') === element.id &&
        element.parentElement?.className === 'booking-form-section'
    })).toBe(true)
  }

  for (const field of fields) {
    const input = contactPage.field(field.label)
    const errorId = `${field.id}-error`
    const error = contactPage.fieldError(field.id)
    await contactPage.fieldLabel(field.label).click()
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

  const phone = contactPage.field('Phone')
  await phone.fill('18015551234')
  await expect(phone).toHaveValue('1-801-555-1234')
  await phone.fill('+44 20 1234 5678')
  await expect(phone).toHaveValue('+442012345678')
  await phone.blur()
  await expect(phone).toHaveAttribute('aria-invalid', 'false')
  await expect(contactPage.submitButton).toBeEnabled()
})


test('backend customer field errors identify the field and preserve the form', async ({ booking, contactPage }) => {
  await contactPage.openBooking(booking)
  await contactPage.fillCustomer(customer)
  await expect(contactPage.submitButton).toBeEnabled()
  const make = 'T'.repeat(256)
  await contactPage.field('Make').fill(make)
  await contactPage.submitButton.click()
  await expect(contactPage.alert).toContainText('Vehicle make: should be at most 255 character(s)')
  await expect(contactPage.field('Make')).toHaveValue(make)
  await expect(contactPage.field('Email')).toHaveValue(customer.Email)
})

