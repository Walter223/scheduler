import type { Locator, Page } from '@playwright/test'

export class HomePage {
  readonly page: Page
  readonly viewServicesLink: Locator
  readonly checkAvailabilityLink: Locator
  readonly servicesNavigationLink: Locator

  constructor(page: Page) {
    this.page = page
    this.viewServicesLink = page.getByRole('link', { name: 'View Services', exact: true })
    this.checkAvailabilityLink = page.getByRole('link', { name: 'Check Availability', exact: true })
    this.servicesNavigationLink = page.getByRole('navigation').getByRole('link', { name: 'Services', exact: true })
  }

  async goto() {
    await this.page.goto('/')
  }

  async openServices() {
    await this.servicesNavigationLink.click()
  }
}
