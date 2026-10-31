import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { test, expect } from '@playwright/test'
import { AdminPage } from './pages/AdminPage'
const fixturePath = process.env.BFF_E2E_FIXTURE
if (!fixturePath) throw new Error('Use npm run test:auth for isolated fixtures')
const { users } = JSON.parse(readFileSync(fixturePath, 'utf8')) as {
  users: { kind: string; username: string; password: string }[]
}
function mutate(action: string) {
  // Local fixture control only; no production endpoint, token fabrication or real account changes.
  execFileSync('mix', ['run', '--no-start', 'scripts/auth_e2e.exs', action], {
    cwd: '../backend', env: process.env, stdio: 'pipe', timeout: 120000,
  })
}
for (const kind of ['owner', 'manager', 'shop_manager', 'employee']) {
  test(`real BFF ${kind} uses persisted capabilities without inferred classification permissions`, async ({ page }) => {
    const admin = new AdminPage(page)
    await admin.login(users.find(u => u.kind === kind)!)
    await expect(page.getByText('Signed in as E2E', { exact: true })).toBeVisible()
    if (kind === 'employee') {
      await expect(page.getByText(/No management workspaces/)).toBeVisible()
      await expect(admin.navigation.getByRole('button')).toHaveCount(0)
    } else {
      await expect(admin.business).toHaveValue(/\d+/)
      await expect(admin.navigation.getByRole('button', { name: 'Dashboard', exact: true })).toBeVisible()
      await expect(admin.navigation.getByRole('button', { name: 'Business settings' })).toHaveCount(kind === 'owner' ? 1 : 0)
      await expect(admin.navigation.getByRole('button', { name: 'Employees and HR' })).toHaveCount(kind === 'shop_manager' ? 0 : 1)
      await expect(admin.navigation.getByRole('button', { name: 'Staff schedules' })).toHaveCount(kind === 'manager' ? 0 : 1)
      if (kind === 'manager') {
        // Owner membership operations remain forbidden despite permitted lower-role delegation.
        const result = await page.evaluate(async () => {
          const business = (await (await fetch('/api/admin/context')).json()).businesses[0]
          const me = await (await fetch('/api/me')).json()
          const memberships = await (await fetch(`/api/admin/businesses/${business.id}/memberships`)).json()
          const target = memberships.data.items[0]
          const response = await fetch(`/api/admin/businesses/${business.id}/memberships/${target.id}/revoke`, {
            method: 'POST', headers: { 'content-type': 'application/json', 'x-csrf-token': me.csrf_token }, body: '{}',
          })
          return response.status
        })
        expect(result).toBe(403)
      }
    }
    await admin.logout()
    await expect(page.getByRole('status')).toContainText('Signed out of Magnum')
    await expect(admin.business).toHaveCount(0)
  })
}
test('mixed Owner and Manager scopes reset workspace and live revocation preserves only the unrelated business', async ({ page }) => {
  const admin = new AdminPage(page)
  await admin.login(users.find(u => u.kind === 'mixed')!)
  await expect(admin.navigation.getByRole('button', { name: 'Business settings' })).toBeVisible()
  await admin.shop.selectOption({ label: 'Acceptance a shop 2' })
  await admin.navigation.getByRole('button', { name: 'Appointments and calendar' }).click()
  await admin.business.selectOption({ label: 'Acceptance b' })
  await expect(admin.shop).toHaveCount(0)
  await expect(page.getByRole('heading', { name: 'Dashboard', exact: true })).toBeVisible()
  await expect(page.getByText('Acceptance a shop 2', { exact: true })).toHaveCount(0)
  await expect(admin.navigation.getByRole('button', { name: 'Business settings' })).toHaveCount(0)
  await admin.business.selectOption({ label: 'Acceptance a' })
  mutate('revoke_mixed')
  await page.getByRole('button', { name: 'Refresh access' }).click()
  await expect(admin.business.getByRole('option', { name: 'Acceptance a', exact: true })).toHaveCount(0)
  await expect(admin.business).toHaveValue(/\d+/)
  await expect(admin.navigation.getByRole('button', { name: 'Employees and HR' })).toBeVisible()
  await admin.logout()
})
test('one Owner switches independently between two businesses with keyboard-accessible mobile navigation', async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 })
  const admin = new AdminPage(page)
  await admin.login(users.find(u => u.kind === 'multi_owner')!)
  const menu = page.getByRole('button', { name: 'Menu', exact: true })
  await menu.focus()
  await page.keyboard.press('Enter')
  await expect(menu).toHaveAttribute('aria-expanded', 'true')
  await admin.business.selectOption({ label: 'Acceptance b' })
  await menu.click()
  await admin.shop.selectOption({ label: 'Acceptance b shop 2' })
  await expect(admin.navigation.getByRole('button', { name: 'Business settings' })).toBeVisible()
  await admin.navigation.getByRole('button', { name: 'Employees and HR' }).click()
  await expect(menu).toHaveAttribute('aria-expanded', 'false')
  await expect(page.getByRole('heading', { name: 'Employees and HR', exact: true })).toBeVisible()
  await admin.logout()
})
test('expired real-login session loses workspace on the next request', async ({ page }) => {
  const admin = new AdminPage(page)
  await admin.login(users.find(u => u.kind === 'shop_manager')!)
  await expect(admin.navigation.getByRole('button', { name: 'Staff schedules' })).toBeVisible()
  mutate('expire_shop_manager')
  await page.getByRole('button', { name: 'Refresh access' }).click()
  await expect(page.getByText(/Access is unavailable/)).toBeVisible()
  await expect(admin.navigation.getByRole('button')).toHaveCount(0)
  const status = await page.evaluate(async () => (await fetch('/api/me')).json())
  expect(status.authenticated).toBe(false)
})
