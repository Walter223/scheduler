import { readFileSync, mkdirSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { test, expect } from '@playwright/test'
import { AdminPage } from './pages/AdminPage'
const fixture=process.env.BFF_E2E_FIXTURE
if(!fixture) throw Error('Use isolated test:auth runner')
const {users}=JSON.parse(readFileSync(fixture,'utf8')) as {users:{kind:string;username:string;password:string}[]}
for (const kind of ['owner', 'shop_manager']) {
test(`real ${kind} calendar agenda, crew detail and responsive visual acceptance`, async ({page})=>{
  execFileSync('mix',['run','--no-start','scripts/auth_e2e.exs','prepare_crew'],{cwd:'../backend',env:process.env,stdio:'pipe',timeout:120000})
  const admin=new AdminPage(page)
  await page.setViewportSize({width:1440,height:1000})
  await admin.login(users.find(u=>u.kind===kind)!)
  if (kind === 'owner') await admin.shop.selectOption({label:'All Shops'})
  else await expect(admin.shop.getByRole('option',{name:'All Shops',exact:true})).toHaveCount(0)
  await admin.openCalendar()
  const calendar=admin.calendar
  const appointment=calendar.getByRole('button',{name:'View Acceptance service · 9:00 AM · Acceptance a shop 1',exact:true})
  await expect(appointment).toBeVisible()
  mkdirSync('/private/tmp/magnum-calendar-ux',{recursive:true})
  async function capture(name:string,width:number) {
    await page.setViewportSize({width,height:1000})
    expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true)
    const clipped=await calendar.locator('button:visible, input:visible, select:visible').evaluateAll(nodes=>nodes.some(n=>{const r=n.getBoundingClientRect();return r.left<0 || r.right>innerWidth+1}))
    expect(clipped).toBe(false)
    expect(await calendar.locator('.calendar-summary').evaluateAll(nodes=>nodes.every(n=>n.getBoundingClientRect().width>=110))).toBe(true)
    await page.screenshot({path:`/private/tmp/magnum-calendar-ux/${kind === 'owner' ? '' : 'shop-manager-'}${name}-${width}.png`,fullPage:true,animations:'disabled'})
  }
  for(const view of ['list','day','week']) {
    await calendar.getByLabel('Calendar view').selectOption(view)
    await expect(appointment).toBeVisible()
    for(const width of [1440,1024,768,390,320]) await capture(view,width)
  }
  await appointment.focus()
  await page.keyboard.press('Enter')
  const details=page.getByRole('region',{name:'Appointment details',exact:true})
  await expect(admin.crew.getByText('Fixture Detailer · Lead',{exact:true})).toBeVisible()
  await admin.crew.getByRole('combobox',{name:'Eligible Detailer',exact:true}).selectOption({label:'Crew Candidate'})
  await admin.crew.getByRole('button',{name:'Add Detailer',exact:true}).click()
  await expect(admin.crew.getByRole('list',{name:'Assigned Detailers'}).getByRole('listitem')).toHaveCount(2)
  const revalidate=page.waitForResponse(r=>r.url().endsWith('/api/admin/context')&&r.status()===200)
  await page.evaluate(()=>window.dispatchEvent(new Event('focus')))
  await revalidate
  await expect(calendar.getByLabel('Calendar view')).toHaveValue('week')
  await expect(details).toBeVisible()
  await expect(admin.crew.getByRole('listitem')).toHaveCount(2)
  await details.getByText('Timezone details',{exact:true}).click()
  for(const width of [1440,1024,768,390,320]) {
    await details.evaluate(n=>n.scrollIntoView({block:'start'}))
    await capture('details',width)
  }
  // Display-only stress; persisted labels and authorization are unchanged.
  await details.getByRole('heading',{name:'Acceptance service',exact:true}).evaluate(n=>n.textContent='Signature exterior and interior detailing '.repeat(6))
  await details.getByRole('region',{name:'Appointment service and vehicle'}).locator('p').nth(1).evaluate(n=>n.textContent='Long vehicle make and model description '.repeat(5))
  await details.getByRole('region',{name:'Appointment service and vehicle'}).locator('p').nth(2).evaluate(n=>n.textContent='Long independent shop and location name '.repeat(6))
  await calendar.locator('.calendar-summary > span').first().evaluate(n=>n.textContent='Long independent shop and location name '.repeat(6)+' · America/Denver')
  await capture('long-labels',320)
  await admin.crew.getByRole('button',{name:'Remove Crew Candidate',exact:true}).click()
  await expect(admin.crew.getByRole('listitem')).toHaveCount(1)
  await details.getByRole('button',{name:'Close appointment',exact:true}).click()
  await calendar.getByLabel('Appointment status').selectOption('cancelled')
  await expect(appointment).toHaveCount(0)
  await expect(calendar.getByRole('button',{name:/View Acceptance service/})).toHaveCount(1)
  await capture('cancelled',390)
  if (kind === 'shop_manager') {
    await page.setViewportSize({width:1440,height:1000})
    await admin.shop.selectOption({label:'Acceptance a shop 2'})
    await admin.openCalendar()
    await expect(calendar.getByText('No appointments on this page.',{exact:true})).toBeVisible()
    await capture('empty-assigned-shop',768)
  }
  await admin.logout()
})
}
