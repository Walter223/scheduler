import { readFileSync, mkdirSync } from 'node:fs'
import { test, expect } from '@playwright/test'
import { AdminPage } from './pages/AdminPage'
const file=process.env.BFF_E2E_FIXTURE
if(!file)throw Error('Use isolated runner')
const {users}=JSON.parse(readFileSync(file,'utf8')) as {users:{kind:string;username:string;password:string}[]}
test('real Owner edits, resumes and reviews multi-location proposals with conflict recovery',async({page})=>{
  const admin=new AdminPage(page)
  await admin.login(users.find(u=>u.kind==='owner')!)
  await page.getByRole('link',{name:'Resume Setup',exact:true}).click()
  const setup=page.getByRole('region',{name:'Business setup'})
  await expect(setup.getByText('Saved setup loaded.')).toBeVisible()
  mkdirSync('/private/tmp/magnum-setup',{recursive:true})
  await setup.screenshot({path:'/private/tmp/magnum-setup/overview.png'})
  await setup.getByRole('button',{name:'Business',exact:true}).click()
  await setup.getByRole('button',{name:'Locations',exact:true}).click()
  const first=setup.getByRole('group',{name:'Location 1',exact:true})
  await first.getByLabel('Shop address', {exact:true}).fill('100 Fictional Way')
  await first.getByRole('combobox',{name:'Location timezone'}).fill('Invalid/Zone')
  await setup.getByRole('button',{name:'Save draft',exact:true}).click()
  await expect(setup.getByRole('status')).toContainText('not saved')
  await setup.screenshot({path:'/private/tmp/magnum-setup/validation.png'})
  await first.getByRole('combobox',{name:'Location timezone'}).fill('America/Denver')
  await setup.getByRole('button',{name:'Add another planned location'}).click()
  await setup.getByRole('group',{name:'Location 2',exact:true}).getByLabel('Location name').fill('Mobile preview')
  const second=setup.getByRole('group',{name:'Location 2',exact:true})
  await second.getByLabel('Shop address',{exact:true}).fill('200 Fictional Way')
  await second.getByRole('radio',{name:/Both/}).check()
  await second.getByLabel('Cities or service areas (one per line)').fill('Denver')
  await second.getByRole('combobox',{name:'Where does your team start?',exact:true}).selectOption('this_location')
  await second.getByLabel('Extra travel time (minutes)').fill('30')
  await setup.getByRole('button',{name:'Save draft',exact:true}).click()
  await expect(setup.getByRole('status')).toHaveText('Saved to this business.')
  for(const width of [1440,1024,768,390,320]){
    await page.setViewportSize({width,height:1000})
    expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true)
    await setup.screenshot({path:`/private/tmp/magnum-setup/locations-${width}.png`})
  }
  await page.setViewportSize({width:1440,height:1000})
  await page.reload()
  await setup.getByRole('button',{name:'Review',exact:true}).click()
  await expect(setup.getByText(/2 location proposals/)).toBeVisible()
  await setup.screenshot({path:'/private/tmp/magnum-setup/review.png'})
  await page.evaluate(async () => {
    const business = (await (await fetch('/api/admin/context')).json()).businesses[0]
    const path = `/api/admin/businesses/${business.id}/onboarding`
    const draft = (await (await fetch(path)).json()).data
    const me = await (await fetch('/api/me')).json()
    await fetch(path,{method:'PUT',headers:{'Content-Type':'application/json','x-csrf-token':me.csrf_token},body:JSON.stringify({revision:draft.revision,request_id:crypto.randomUUID(),state:draft.state,proposal:draft.proposal})})
  })
  await setup.getByRole('button',{name:'Save draft',exact:true}).click()
  await expect(setup.getByRole('status')).toContainText('Another save changed')
  await setup.getByRole('button',{name:'Discard local edits and reload'}).click()
  await expect(setup.getByRole('status')).toHaveText('Saved setup loaded.')
  await expect(setup.getByText(/2 location proposals/)).toBeVisible()
  await admin.logout()
})
