import {readFileSync,mkdirSync} from 'node:fs'
import {join} from 'node:path'
import {homedir} from 'node:os'
import {test,expect} from '@playwright/test'
import {AdminPage} from './pages/AdminPage'
const {users}=JSON.parse(readFileSync(process.env.BFF_E2E_FIXTURE!,'utf8'))
test('first location saves physical, mobile and combined plans without duplicating a shop',async({page})=>{
 const admin=new AdminPage(page);await admin.login(users.find((u:{kind:string})=>u.kind==='golden_owner'))
 await expect(page.getByRole('link',{name:'Resume Setup',exact:true})).toBeVisible()
 const before=await (await page.request.get('/api/admin/context')).json()
 const business=before.businesses.find((b:{name:string})=>b.name==='Golden Independent Studio')||before.businesses[0]
 await page.goto(`/setup/${business.id}`)
 await expect(page.getByRole('region',{name:'Business setup'}).getByRole('status')).toHaveText(/Begin setup to save|Saved setup loaded/)
 if(await page.getByRole('button',{name:'Begin setup',exact:true}).isVisible())await page.getByRole('button',{name:'Begin setup',exact:true}).click()
 const setup=page.getByRole('region',{name:'Business setup'})
 await expect(setup.getByRole('button',{name:'Business',exact:true})).toBeVisible()
 const endpoint=`/api/admin/businesses/${business.id}/onboarding`
 const initial=(await (await page.request.get(endpoint)).json()).data
 const shopId=initial.applied.shops[0].id
 if(initial.state==='provisioning_complete'){
  await setup.getByRole('button',{name:'Business',exact:true}).click()
  await setup.getByRole('button',{name:'Save and continue',exact:true}).click()
 }else await setup.getByRole('button',{name:'Locations',exact:true}).click()
 const folder=join(process.env.MAGNUM_SCREENSHOT_ARCHIVE||(!process.env.CI?join(homedir(),'projects','Magnum-Screenshots'):test.info().outputDir),'ux-c1-first-location',new Date().toISOString().replaceAll(':','-'))
 mkdirSync(folder,{recursive:true})
 async function capture(state:string){for(const width of [1440,768,390]){await page.setViewportSize({width,height:1000});expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);await page.screenshot({path:join(folder,`${state}-${width}.png`),fullPage:true})}}
 await expect(setup.getByRole('heading',{name:'Where will you serve customers?'})).toBeVisible()
 await setup.getByRole('button',{name:'Save and continue',exact:true}).click()
 await expect(setup.getByText('Enter the shop address.',{exact:true})).toBeVisible()
 await expect(page.getByRole('progressbar')).toHaveAttribute('aria-valuenow','17')
 await capture('physical-required-address')
 await setup.getByLabel('Location name',{exact:true}).fill('Preview studio')
 await setup.getByLabel('Shop address',{exact:true}).fill('100 Fictional Way')
 await capture('physical')
 await setup.getByRole('radio',{name:/Both/}).check()
 await setup.getByLabel('Cities or service areas (one per line)').fill('Denver\nAurora')
 await setup.getByRole('combobox',{name:'Where does your team start?',exact:true}).selectOption('this_location')
 await setup.getByLabel('Extra travel time (minutes)').fill('30')
 await setup.getByRole('button',{name:'Save draft',exact:true}).click()
 await expect(setup.getByRole('status')).toHaveText('Saved to this business.')
 await page.reload();await expect(setup.getByLabel('Location name',{exact:true})).toHaveValue('Preview studio')
 await expect(setup.getByRole('radio',{name:/Both/})).toBeChecked()
 await capture('combined-saved')
 await setup.getByRole('radio',{name:/We travel/}).check()
 await setup.getByRole('button',{name:'Save draft',exact:true}).click()
 await expect(setup.getByRole('status')).toHaveText('Saved to this business.')
 await page.reload();await expect(setup.getByLabel('Dispatch / base address')).toHaveValue('100 Fictional Way')
 await capture('mobile-saved')
 await setup.getByRole('button',{name:'Back',exact:true}).click()
 await setup.getByRole('button',{name:'Locations',exact:true}).click()
 await expect(setup.getByLabel('Cities or service areas (one per line)')).toHaveValue('Denver\nAurora')
 await setup.getByRole('button',{name:'Save and continue',exact:true}).click()
 await expect(page.getByRole('progressbar')).toHaveAttribute('aria-valuenow','33')
 const saved=(await (await page.request.get(endpoint)).json()).data
 expect(saved.proposal.locations).toHaveLength(1)
 expect(saved.proposal.locations[0]).toMatchObject({existing_shop_id:shopId,operating_model:'mobile',mobile:{service_areas:['Denver','Aurora'],travel_buffer_minutes:30,dispatch_source:'this_location'}})
 expect(saved.applied.shops).toEqual(initial.applied.shops)
 await admin.logout()
})
