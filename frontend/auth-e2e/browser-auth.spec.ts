import { readFileSync } from 'node:fs'
import { test, expect } from '@playwright/test'
import type { Page } from '@playwright/test'

type Fixture = { kind: string; username: string; password: string }
const path = process.env.BFF_E2E_FIXTURE
if (!path) throw new Error('Run npm run test:auth to provision isolated fixtures')
const { users } = JSON.parse(readFileSync(path, 'utf8')) as { users: Fixture[] }

async function login(page: Page, kind: string) {
  const user = users.find((entry) => entry.kind === kind)!
  await page.goto('/')
  await expect(page.getByRole('link', { name: 'Staff sign in' })).toHaveCount(0)
  await page.goto('/admin')
  await page.getByRole('link', { name: 'Staff sign in' }).click()
  // A real Keycloak form, real authorization code and real signed ID token.
  await page.getByRole('textbox', { name: /email|username/i }).fill(user.username)
  await page.getByLabel('Password', { exact: true }).fill(user.password)
  await page.getByRole('button', { name: /sign in/i }).click()
}

test('active verified staff can log in, receive session-bound CSRF, and log out locally', async ({ page, context }) => {
  await login(page, 'active')
  await expect(page.getByText('Signed in as E2E', { exact: true })).toBeVisible()
  const cookies = await context.cookies('http://localhost:5174')
  const session = cookies.find((cookie) => cookie.name === 'magnum_session_dev')
  expect(Boolean(session?.httpOnly && session.sameSite === 'Lax' && session.path === '/')).toBe(true)
  expect(cookies.some((cookie) => cookie.name === 'magnum_login_dev')).toBe(false)
  const metadata = await page.evaluate(async () => {
    const response = await fetch('/api/me')
    const body = await response.json()
    const denied = await fetch('/auth/logout', { method: 'POST' })
    return { authenticated: body.authenticated, hasCSRF: typeof body.csrf_token === 'string',
      noStore: response.headers.get('cache-control'), missingCSRFStatus: denied.status }
  })
  expect(metadata).toEqual({ authenticated: true, hasCSRF: true, noStore: 'no-store', missingCSRFStatus: 403 })
  await page.getByRole('button', { name: 'Sign out', exact: true }).click()
  await expect(page.getByRole('status')).toContainText('Signed out of Magnum')
  expect((await context.cookies('http://localhost:5174')).some((cookie) => cookie.name === 'magnum_session_dev')).toBe(false)
  const status = await page.evaluate(async () => (await fetch('/api/me')).json())
  expect(status).toEqual({ authenticated: false, user: null, csrf_token: null })
})

test('unknown verified identity remains pending and never receives a Magnum session', async ({ page, context }) => {
  await login(page, 'pending')
  await expect(page.getByRole('status')).toHaveText('Your Magnum account is not available for sign-in. Contact your administrator.')
  expect((await context.cookies('http://localhost:5174')).some((cookie) => cookie.name === 'magnum_session_dev')).toBe(false)
  const status = await page.evaluate(async () => (await fetch('/api/me')).json())
  expect(status).toEqual({ authenticated: false, user: null, csrf_token: null })
})
