import type { Page } from '@playwright/test'
export class AdminPage {
  readonly page: Page
  constructor(page: Page) { this.page = page }
  get heading() { return this.page.getByRole('heading', { name: 'Magnum Command Center' }) }
  get signIn() { return this.page.getByRole('link', { name: 'Staff sign in' }) }
  async goto() { await this.page.goto('/admin') }
}
