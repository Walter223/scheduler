import type { Locator, Page } from '@playwright/test'

export class ServicesPage {
  readonly page: Page
  readonly heading: Locator
  readonly bookingLinks: Locator
  readonly selectedOptions: Locator

  constructor(page: Page) {
    this.page = page
    this.heading = page.getByRole('heading', { name: 'Magnum Detailing Services', exact: true })
    this.bookingLinks = page.getByRole('link', { name: 'Book This Detail', exact: true })
    this.selectedOptions = page.getByRole('button', { pressed: true })
  }

  // Cards are unnamed sections, not accessible regions. Filter the simple HTML
  // container by its accessible heading; no styling classes or parent XPath.
  private serviceCard(name: string) {
    return this.page.locator('section').filter({ has: this.page.getByRole('heading', { name, exact: true }) })
  }

  option(service: string, size: string) {
    return this.serviceCard(service).getByRole('button', { name: new RegExp(`^${size}\\b`) })
  }

  bookingLink(service: string) {
    return this.serviceCard(service).getByRole('link', { name: 'Book This Detail', exact: true })
  }

  async goto() {
    await this.page.goto('/services')
  }

  async selectDetail(service: string, size: string) {
    await this.option(service, size).click()
  }

  async bookDetail(service: string) {
    await this.bookingLink(service).click()
  }
}
