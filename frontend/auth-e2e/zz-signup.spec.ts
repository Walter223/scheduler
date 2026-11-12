import { readFileSync, mkdirSync } from 'node:fs'
import { test, expect } from '@playwright/test'
import {execFileSync} from 'node:child_process'
import {AdminPage} from './pages/AdminPage'
const path = process.env.BFF_E2E_FIXTURE
if (!path) throw Error('Use isolated test:auth runner')
const { users, run_id } = JSON.parse(readFileSync(path, 'utf8')) as { run_id: string; users: {kind: string; username: string; password: string}[] }
for (const kind of ['pending', 'owner']) test(`real ${kind} signup, Owner access and responsive screens`, async ({ page, context, browser }) => {
  const identity = users.find(u => u.kind === kind)!
  const folder = '/private/tmp/magnum-signup'
  mkdirSync(folder, { recursive: true })
  if (kind === 'owner') { await new AdminPage(page).login(identity); await expect(page.getByText('Signed in as E2E',{exact:true})).toBeVisible() }
  await page.goto('/platform')
  await page.getByRole('link',{name:'Create a Business',exact:true}).click()
  await expect(page.getByRole('button', {name: 'I already have an account'})).toBeVisible()
  if (kind === 'pending') {await page.screenshot({fullPage: true, path: `${folder}/entry.png`});await page.setViewportSize({width:390,height:1000});await page.screenshot({fullPage:true,path:`${folder}/entry-390.png`});await page.setViewportSize({width:1440,height:1000})}
  await page.getByRole('button', {name: 'I already have an account'}).click()
  if(kind === 'pending'){
  await page.getByRole('textbox', {name: /email|username/i}).fill(identity.username)
  await page.getByLabel('Password', {exact: true}).fill(identity.password)
  await page.getByRole('button', {name: /sign in/i}).click()
  }
  await expect(page.getByLabel('Business name')).toBeVisible()
  if (kind === 'pending') {
    const proof = (await context.cookies()).find(cookie => cookie.name === 'magnum_onboarding_dev')!
    await context.addCookies([{...proof, expires: Math.floor(Date.now() / 1000) - 1}])
    await page.reload()
    await expect(page.getByRole('button', {name: 'I already have an account'})).toBeVisible()
    await page.getByRole('button', {name: 'I already have an account'}).click()
    await expect(page.getByLabel('Business name')).toBeVisible()
  }
  const isolated = await browser.newContext()
  expect((await isolated.request.post('http://localhost:5174/auth/signup/business',{headers:{Origin:'http://localhost:5174'},data:{business:{name:'No proof',slug:'no-proof'},shop:{name:'Main',slug:'main',timezone:'America/Denver'}}})).status()).toBe(403)
  await isolated.close()
  expect((await context.cookies()).filter(c => c.name.includes('onboarding')).every(c => c.httpOnly && c.sameSite === 'Lax')).toBe(true)
  await page.getByLabel('Business name').fill(`Signup ${kind}`)
  await page.getByLabel('Booking website address',{exact:true}).fill('magnum-detailing')
  await page.getByLabel('Shop name').fill('Initial shop')
  await expect(page.getByRole('combobox',{name:'Shop timezone'})).toBeVisible()
  await page.getByRole('combobox',{name:'Shop timezone'}).fill('America/Denver')
  if(kind === 'owner'){
    expect((await page.request.post('/auth/signup/business',{headers:{Origin:'https://evil.invalid'},data:{}})).status()).toBe(403)
    const denied=await page.evaluate(async()=>{
      const me=await (await fetch('/auth/signup')).json()
      const body=JSON.stringify({business:{name:'No creation',slug:'invalid-timezone'},shop:{name:'Main',slug:'main',timezone:'Invalid/Zone'}})
      const noCSRF=await fetch('/auth/signup/business',{method:'POST',headers:{'Content-Type':'application/json'},body})
      const badOrigin=await fetch('/auth/signup/business?bad=query',{method:'POST',headers:{'Content-Type':'application/json','x-csrf-token':me.csrf_token},body})
      const invalidZone=await fetch('/auth/signup/business',{method:'POST',headers:{'Content-Type':'application/json','x-csrf-token':me.csrf_token},body})
      return [noCSRF.status,badOrigin.status,invalidZone.status]
    })
    expect(denied).toEqual([403,422,422])
    execFileSync('mix',['run','--no-start','scripts/auth_e2e.exs','suspend_signup_owner'],{cwd:'../backend',env:process.env,stdio:'pipe'})
    expect((await page.request.get('/auth/signup')).status()).toBe(403)
    expect((await (await page.request.get('/api/me')).json()).authenticated).toBe(false)
    execFileSync('mix',['run','--no-start','scripts/auth_e2e.exs','restore_signup_owner'],{cwd:'../backend',env:process.env,stdio:'pipe'})
  }
  await page.getByRole('button', {name: 'Review business'}).click()
  if(kind === 'owner'){
    await page.route('**/auth/signup/business',route=>route.fulfill({status:503,contentType:'application/json',body:JSON.stringify({error:'operation_unavailable'})}),{times:1})
    await page.getByRole('button',{name:'Create business',exact:true}).click()
    await expect(page.getByRole('alert')).toContainText('temporarily unavailable')
    await expect(page.getByLabel('Business name',{exact:true})).toHaveValue('Signup owner')
    await page.getByRole('button',{name:'Review business'}).click()
  }
  await page.getByRole('button', {name: 'Create business', exact: true}).click()
  await expect(page.getByRole('alert')).toContainText('booking website address')
  if (kind === 'pending') {await page.screenshot({fullPage: true, path: `${folder}/validation.png`});await page.setViewportSize({width:390,height:1000});await page.screenshot({fullPage:true,path:`${folder}/validation-390.png`})}
  await page.getByLabel('Booking website address',{exact:true}).fill(`${run_id}-signup-${kind}`)
  for (const width of [1440, 1024, 768, 390, 320]) {
    await page.setViewportSize({width, height: 1000})
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true)
    await page.screenshot({fullPage: true, path: `${folder}/${kind}-form-${width}.png`})
  }
  const helpControl=page.getByLabel('Help: Booking website address',{exact:true})
  if(kind === 'owner'){await helpControl.focus();await page.keyboard.press('Enter')}else await helpControl.click()
  await expect(page.getByRole('note')).toContainText('reserves an identifier')
  await page.setViewportSize({width:320,height:1000})
  await page.screenshot({fullPage:true,path:`${folder}/${kind}-help-320.png`})
  await page.keyboard.press('Escape')
  await expect(page.getByLabel('Help: Booking website address',{exact:true})).toBeFocused()
  await page.getByRole('button', {name: 'Review business'}).click()
  let submissions = 0
  page.on('request', request => { if (request.url().endsWith('/auth/signup/business')) submissions++ })
  const creation = page.waitForRequest(r=>r.url().endsWith('/auth/signup/business') && r.method()==='POST')
  await page.getByRole('button', {name: 'Create business', exact: true}).evaluate(button => {
    (button as HTMLButtonElement).click(); (button as HTMLButtonElement).click()
  })
  await expect(page.getByText('Your business is ready')).toBeVisible()
  expect(submissions).toBe(1)
  const createdRequest=await creation
  if(kind === 'owner'){
  const receipts=await page.evaluate(async({body,csrf})=>{
    const send=(payload:unknown)=>fetch('/auth/signup/business',{method:'POST',headers:{'Content-Type':'application/json','x-csrf-token':csrf},body:JSON.stringify(payload)})
    const responses=await Promise.all([send(body),send(body)])
    const data=await Promise.all(responses.map(r=>r.json()))
    const changed=await send({...body,business:{...body.business,name:'Changed retry'}})
    return {statuses:responses.map(r=>r.status),ids:data.map(d=>d.data.business_id),changed:changed.status}
  },{body:createdRequest.postDataJSON(),csrf:createdRequest.headers()['x-csrf-token']})
  expect(receipts.statuses).toEqual([200,200]);expect(receipts.ids[0]).toBe(receipts.ids[1]);expect(receipts.changed).toBe(409)
  }
  await expect(page.getByText(`Signup ${kind}`,{exact:true})).toBeVisible()
  await page.screenshot({fullPage: true, path: `${folder}/${kind}-success.png`})
  await page.reload()
  await expect(page.getByText('Your business is ready')).toBeVisible()
  await expect(page.getByText(`Signup ${kind}`,{exact:true})).toBeVisible()
  await page.goto('/platform')
  await page.goBack()
  await expect(page.getByText('Your business is ready')).toBeVisible()
  await page.goForward()
  await expect(page).toHaveURL(/\/platform$/)
  await page.goBack()
  await expect(page.getByText('Your business is ready')).toBeVisible()
  // A completed refresh/history restore must not expose another create action or navigate to Admin.
  await expect(page).toHaveURL(/\/signup$/)
  expect(await page.getByRole('button',{name:'Create business',exact:true}).count()).toBe(0)
  for(const width of [1440,390]){await page.setViewportSize({width,height:1000});await page.screenshot({fullPage:true,path:`${folder}/${kind}-success-${width}.png`})}
  await page.setViewportSize({width: 1440, height: 1000})
  await page.getByRole('link', {name: 'Sign in to Magnum', exact: true}).click()
  await expect(page.getByText('Signed in as E2E', {exact: true})).toBeVisible()
  const businesses = await page.evaluate(async () => (await (await fetch('/api/admin/context')).json()).businesses)
  expect((await page.request.get('/api/admin/businesses/1/employees')).status()).toBe(403)
  expect(businesses).toHaveLength(kind === 'owner' ? 2 : 1)
  const created = businesses.find((business: {name: string}) => business.name === `Signup ${kind}`)
  expect(created.capabilities).toContain('access')
  if (kind === 'owner') await page.getByLabel('Business', {exact: true}).selectOption({label: `Signup ${kind}`})
  expect(await page.evaluate(() => localStorage.length + sessionStorage.length)).toBe(0)
  await page.getByRole('button', {name: 'Sign out', exact: true}).click()
  await expect(page.getByRole('link', {name: /Try signing in again/})).toBeVisible()
})
