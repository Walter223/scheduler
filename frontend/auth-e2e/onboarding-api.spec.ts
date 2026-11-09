import { readFileSync } from 'node:fs'
import { test, expect } from '@playwright/test'
import { AdminPage } from './pages/AdminPage'
const file = process.env.BFF_E2E_FIXTURE
if (!file) throw Error('Use isolated test:auth runner')
const { users } = JSON.parse(readFileSync(file, 'utf8')) as { users: {kind: string; username: string; password: string}[] }
test('real Owner begins, saves and resumes a private onboarding draft without applying records', async ({ page }) => {
  const admin = new AdminPage(page)
  await admin.login(users.find(user => user.kind === 'owner')!)
  await expect(page.getByText('Signed in as E2E', {exact: true})).toBeVisible()
  const result = await page.evaluate(async () => {
    const context = await (await fetch('/api/admin/context')).json()
    const { csrf_token } = await (await fetch('/api/me')).json()
    const path = `/api/admin/businesses/${context.businesses[0].id}/onboarding`
    const headers = {'Content-Type': 'application/json', 'x-csrf-token': csrf_token}
    const draft = (await (await fetch(path, {method: 'POST', headers, body: '{}'})).json()).data
    const update = {revision: draft.revision, request_id: crypto.randomUUID(), state: 'locations', proposal: draft.proposal}
    const saved = (await (await fetch(path, {method: 'PUT', headers, body: JSON.stringify(update)})).json()).data
    const retry = (await (await fetch(path, {method: 'PUT', headers, body: JSON.stringify(update)})).json()).data
    const resumed = await fetch(path)
    return {saved, retry, resumed: (await resumed.json()).data, cache: resumed.headers.get('cache-control')}
  })
  expect(result.saved.state).toBe('locations')
  expect(result.saved.revision).toBe(1)
  expect(result.retry).toEqual(result.saved)
  expect(result.resumed).toEqual(result.saved)
  expect(result.saved.readiness.published).toBe(false)
  expect(result.cache).toBe('no-store')
  await admin.logout()
})
