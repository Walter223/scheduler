import type { Locator, Page } from '@playwright/test'

type Selection = { service_id: number; vehicle_size_id: number; date: string }

export class ContactPage {
  readonly page: Page
  readonly dateInput: Locator
  readonly submitButton: Locator
  readonly selectedTimes: Locator
  readonly alert: Locator
  readonly confirmationHeading: Locator
  readonly confirmation: Locator
  readonly bookAnotherButton: Locator

  constructor(page: Page) {
    this.page = page
    this.dateInput = page.getByLabel('Choose a Date')
    this.submitButton = page.getByRole('button', { name: 'Book Appointment', exact: true })
    this.selectedTimes = page.getByRole('button', { pressed: true })
    this.alert = page.getByRole('alert')
    this.confirmationHeading = page.getByRole('heading', { name: "You're On The Schedule", exact: true })
    this.confirmation = page.getByRole('main')
    this.bookAnotherButton = page.getByRole('button', { name: 'Book Another Detail', exact: true })
  }

  field(label: string) {
    return this.page.getByLabel(label, { exact: true })
  }

  fieldLabel(label: string) {
    return this.page.getByText(label, { exact: true })
  }

  // Stable field/error IDs are part of the aria-describedby relationship tested
  // by validation specs. These are source-defined IDs, not generated selectors.
  fieldError(fieldId: string) {
    return this.page.locator(`[id="${fieldId}-error"]`)
  }

  timeSlot(time: string) {
    return this.page.getByRole('button', { name: time, exact: true })
  }

  serviceHeading(name: string) {
    return this.page.getByRole('heading', { name, exact: true })
  }

  summaryText(text: string) {
    return this.page.getByText(text, { exact: true })
  }

  confirmationText(text: string, exact = true) {
    return this.confirmation.getByText(text, { exact })
  }

  async openBooking(selection: Selection) {
    await this.page.goto(`/contact?service=${selection.service_id}&size=${selection.vehicle_size_id}`)
    await this.dateInput.fill(selection.date)
    await this.timeSlot('9:00 AM').click()
  }

  async fillCustomer(fields: Record<string, string>) {
    for (const [label, value] of Object.entries(fields)) {
      await this.field(label).fill(value)
    }
  }
}
