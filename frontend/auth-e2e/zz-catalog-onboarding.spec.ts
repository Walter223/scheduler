import { readFileSync, mkdirSync } from 'node:fs'
import { test, expect } from '@playwright/test'
import { AdminPage } from './pages/AdminPage'
const file = process.env.BFF_E2E_FIXTURE
if (!file) throw Error('Use isolated runner')
const {users} = JSON.parse(readFileSync(file, 'utf8')) as {users: {kind: string; username: string; password: string}[]}
const folder = '/private/tmp/magnum-catalog-onboarding'

test('real Owner saves and resumes custom category prices and shop overrides without publishing', async ({page}) => {
  const admin = new AdminPage(page)
  await admin.login(users.find(u=>u.kind === 'owner')!)
  await page.getByRole('link', {name: 'Resume Setup', exact: true}).click()
  const setup = page.getByRole('region', {name: 'Business setup'})
  await expect(setup.getByRole('status')).toHaveText('Saved setup loaded.')
  // Own this spec's draft configuration; do not depend on another spec's locations.
  await page.evaluate(async () => {
    const context = await (await fetch('/api/admin/context')).json()
    const path = `/api/admin/businesses/${context.businesses[0].id}/onboarding`
    const {data} = await (await fetch(path)).json()
    const me = await (await fetch('/api/me')).json()
    const proposal = {...data.proposal, employees: [], services: [], catalog: {version: 1, currency: 'USD', vehicle_categories: []}, locations: [
      {key:'catalog-first',existing_shop_id:data.applied.shops[0].id,name:'Studio North',address:'100 Fictional Way',timezone:'America/Denver',operating_model:'in_shop'},
      {key:'catalog-second',name:'Mobile South',address:'200 Fictional Way',timezone:'America/Denver',operating_model:'both',mobile:{service_areas:['Denver'],dispatch_source:'this_location',travel_buffer_minutes:30}},
    ]}
    const response = await fetch(path, {method:'PUT',headers:{'Content-Type':'application/json','x-csrf-token':me.csrf_token},body:JSON.stringify({revision:data.revision,request_id:crypto.randomUUID(),state:data.state,proposal})})
    if (!response.ok) throw Error('Owned catalog setup failed')
  })
  await page.reload()
  await setup.getByRole('button', {name: 'Services', exact: true}).click()
  await expect(setup.getByText(/Configuration is deferred/)).toBeVisible()
  await setup.getByRole('button', {name:'Add vehicle category'}).click()
  await setup.getByLabel('Category 1 name').fill('City car')
  await setup.getByRole('button', {name:'Add vehicle category'}).click()
  await setup.getByLabel('Category 2 name').fill('Adventure van')
  await setup.getByRole('button', {name:'Use exterior-care suggestion'}).click()
  const service = setup.getByRole('group', {name:'Service proposal 1',exact:true})
  await service.getByLabel('Service name', {exact:true}).fill('Custom exterior care')
  await service.getByLabel('Estimated duration (minutes)', {exact:true}).fill('75')
  const availability = service.getByRole('group', {name:'Proposed shop availability',exact:true})
  await availability.getByLabel('Studio North', {exact:true}).check()
  await availability.getByLabel('Mobile South', {exact:true}).check()
  await service.getByLabel('City car price (USD)', {exact:true}).fill('123.45')
  await setup.getByRole('button', {name:'Save draft',exact:true}).click()
  await expect(setup.getByRole('status')).toContainText('not saved')
  mkdirSync(folder, {recursive:true})
  await setup.screenshot({path:`${folder}/validation.png`})
  await service.getByLabel('Adventure van price (USD)', {exact:true}).fill('234.56')
  const customize = service.getByLabel('Customize Mobile South', {exact:true})
  await customize.focus(); await page.keyboard.press('Space')
  await service.getByLabel('Duration override (minutes)', {exact:true}).fill('90')
  await service.getByRole('combobox', {name:'Delivery override',exact:true}).selectOption('mobile')
  await service.getByLabel('Override Adventure van price', {exact:true}).check()
  await service.getByRole('group', {name:'Override category prices',exact:true}).getByLabel('Adventure van price (USD)', {exact:true}).fill('300.05')
  await setup.getByRole('button', {name:'Save draft',exact:true}).click()
  await expect(setup.getByRole('status')).toHaveText('Saved to this business.')
  for (const width of [1440,1024,768,390,320]) {
    await page.setViewportSize({width,height:1000})
    expect(await page.evaluate(()=>document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    await setup.screenshot({path:`${folder}/services-${width}.png`})
  }
  await page.reload()
  await setup.getByRole('button', {name:'Services',exact:true}).click()
  await expect(service.getByLabel('City car price (USD)', {exact:true})).toHaveValue('123.45')
  await expect(service.getByRole('combobox', {name:'Delivery override',exact:true})).toHaveValue('mobile')
  const revalidation = page.waitForResponse(r=>r.url().endsWith('/api/admin/context'))
  await page.evaluate(()=>window.dispatchEvent(new Event('focus')))
  await revalidation
  await expect(service.getByLabel('Service name', {exact:true})).toHaveValue('Custom exterior care')
  await setup.getByRole('button', {name:'Review',exact:true}).click()
  await expect(setup.getByRole('region', {name:'Catalog review'})).toContainText('$300.05')
  await setup.screenshot({path:`${folder}/review-320.png`})
  await page.setViewportSize({width:1440,height:1000})
  await setup.screenshot({path:`${folder}/review-1440.png`})
  await admin.logout()
})
