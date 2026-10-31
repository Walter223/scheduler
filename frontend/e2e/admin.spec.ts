import { test, expect } from './fixtures'
import { AdminPage } from './pages/AdminPage'
test('direct anonymous Admin entry stays separate from public navigation', async ({ page }) => {
  const admin = new AdminPage(page)
  await page.setViewportSize({ width: 390, height: 844 })
  await admin.goto()
  await expect(admin.heading).toBeVisible()
  await expect(admin.signIn).toHaveAttribute('href', '/auth/login')
  await expect(page.getByLabel('Business', { exact: true })).toHaveCount(0)
  await admin.signIn.focus()
  await expect(admin.signIn).toBeFocused()
  await page.goto('/')
  await expect(page.getByRole('link', { name: 'Staff sign in' })).toHaveCount(0)
})
