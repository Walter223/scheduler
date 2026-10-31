import type { Page } from '@playwright/test'
export class AdminPage {
  readonly page: Page
  constructor(page: Page) { this.page = page }
  get business() { return this.page.getByLabel('Business', { exact: true }) }
  get shop() { return this.page.getByLabel('Shop', { exact: true }) }
  get employees() { return this.page.getByRole('region', { name: 'Employee directory', exact: true }) }
  get roster() { return this.page.getByRole('region', { name: 'Current shop roster' }) }
  async openEmployees() { await this.navigation.getByRole('button', { name: 'Employees and HR' }).click() }
  get dashboard() { return this.page.getByRole('region', { name: 'Operational dashboard' }) }
  get navigation() { return this.page.getByRole('navigation', { name: 'Admin areas' }) }
  async login(identity: { username: string; password: string }) {
    await this.page.goto('/admin')
    await this.page.getByRole('link', { name: 'Staff sign in' }).click()
    await this.page.getByRole('textbox', { name: /email|username/i }).fill(identity.username)
    await this.page.getByLabel('Password', { exact: true }).fill(identity.password)
    await this.page.getByRole('button', { name: /sign in/i }).click()
  }
  async logout() { await this.page.getByRole('button', { name: 'Sign out', exact: true }).click() }
}
