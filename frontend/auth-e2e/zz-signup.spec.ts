import { readFileSync, mkdirSync } from 'node:fs'
import { test, expect } from '@playwright/test'
const path = process.env.BFF_E2E_FIXTURE
if (!path) throw Error('Use isolated test:auth runner')
const { users, run_id } = JSON.parse(readFileSync(path, 'utf8')) as { run_id: string; users: {kind: string; username: string; password: string}[] }
for (const kind of ['pending', 'owner']) test(`real ${kind} signup, Owner access and responsive screens`, async ({ page, context }) => {
  const identity = users.find(u => u.kind === kind)!
  const folder = '/private/tmp/magnum-signup'
  mkdirSync(folder, { recursive: true })
  await page.goto('/signup')
  await expect(page.getByRole('button', {name: 'Continue to verification'})).toBeVisible()
  if (kind === 'pending') await page.screenshot({fullPage: true, path: `${folder}/entry.png`})
  await page.getByRole('button', {name: 'Continue to verification'}).click()
  await page.getByRole('textbox', {name: /email|username/i}).fill(identity.username)
  await page.getByLabel('Password', {exact: true}).fill(identity.password)
  await page.getByRole('button', {name: /sign in/i}).click()
  await expect(page.getByLabel('Business name')).toBeVisible()
  if (kind === 'pending') {
    const proof = (await context.cookies()).find(cookie => cookie.name === 'magnum_onboarding_dev')!
    await context.addCookies([{...proof, expires: Math.floor(Date.now() / 1000) - 1}])
    await page.reload()
    await expect(page.getByRole('button', {name: 'Continue to verification'})).toBeVisible()
    await page.getByRole('button', {name: 'Continue to verification'}).click()
    await expect(page.getByLabel('Business name')).toBeVisible()
  }
  expect((await context.cookies()).filter(c => c.name.includes('onboarding')).every(c => c.httpOnly && c.sameSite === 'Lax')).toBe(true)
  await page.getByLabel('Business name').fill(`Signup ${kind}`)
  await page.getByLabel('Business slug').fill('magnum-detailing')
  await page.getByLabel('Shop name').fill('Initial shop')
  await page.getByRole('button', {name: 'Review business'}).click()
  await page.getByRole('button', {name: 'Create business', exact: true}).click()
  await expect(page.getByRole('alert')).toContainText('slug')
  if (kind === 'pending') await page.screenshot({fullPage: true, path: `${folder}/validation.png`})
  await page.getByLabel('Business slug').fill(`${run_id}-signup-${kind}`)
  for (const width of [1440, 1024, 768, 390, 320]) {
    await page.setViewportSize({width, height: 1000})
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    await page.screenshot({fullPage: true, path: `${folder}/${kind}-form-${width}.png`})
  }
  await page.getByRole('button', {name: 'Review business'}).click()
  let submissions = 0
  page.on('request', request => { if (request.url().endsWith('/auth/signup/business')) submissions++ })
  await page.getByRole('button', {name: 'Create business', exact: true}).evaluate(button => {
    (button as HTMLButtonElement).click(); (button as HTMLButtonElement).click()
  })
  await expect(page.getByText('Your business is ready')).toBeVisible()
  expect(submissions).toBe(1)
  await page.screenshot({fullPage: true, path: `${folder}/${kind}-success.png`})
  await page.setViewportSize({width: 1440, height: 1000})
  await page.getByRole('link', {name: 'Sign in to Magnum', exact: true}).click()
  await expect(page.getByText('Signed in as E2E', {exact: true})).toBeVisible()
  const businesses = await page.evaluate(async () => (await (await fetch('/api/admin/context')).json()).businesses)
  expect(businesses).toHaveLength(kind === 'owner' ? 2 : 1)
  const created = businesses.find((business: {name: string}) => business.name === `Signup ${kind}`)
  expect(created.capabilities).toContain('access')
  if (kind === 'owner') await page.getByLabel('Business', {exact: true}).selectOption({label: `Signup ${kind}`})
  expect(await page.evaluate(() => localStorage.length + sessionStorage.length)).toBe(0)
  await page.getByRole('button', {name: 'Sign out', exact: true}).click()
  await expect(page.getByRole('link', {name: /Try signing in again/})).toBeVisible()
})
