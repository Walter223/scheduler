import {readFileSync,mkdirSync} from 'node:fs'
import {test,expect} from '@playwright/test'
import {AdminPage} from './pages/AdminPage'
const {users}=JSON.parse(readFileSync(process.env.BFF_E2E_FIXTURE!,'utf8'))
test('Owner branding presets save resume and remain unpublished',async({page})=>{
 const admin=new AdminPage(page);await admin.login(users.find((u:{kind:string})=>u.kind==='owner'))
 await page.getByRole('link',{name:'Resume Setup',exact:true}).click()
 const setup=page.getByRole('region',{name:'Business setup'})
 await setup.getByRole('button',{name:'Branding',exact:true}).click()
 const fields={'Business display name':'Fictional Studio','Public contact email':'invalid','Public contact phone':'+1 555 010 1234','Primary color':'#173348','Secondary color':'#eff4f8','Accent color':'#755230'}
 for(const [label,value] of Object.entries(fields))await setup.getByLabel(label,{exact:true}).fill(value)
 await setup.getByRole('combobox',{name:'Website style preset'}).selectOption('modern')
 await setup.getByRole('button',{name:'Save draft',exact:true}).click()
 await expect(setup.getByRole('status')).toContainText('not saved')
 const folder='/private/tmp/magnum-branding-onboarding';mkdirSync(folder,{recursive:true})
 await setup.screenshot({path:`${folder}/validation.png`})
 await setup.getByLabel('Public contact email',{exact:true}).fill('public@example.invalid')
 for(const preset of ['modern','premium','minimal']){
  await setup.getByRole('combobox',{name:'Website style preset'}).selectOption(preset)
  await setup.getByRole('button',{name:'Save draft',exact:true}).click()
  await expect(setup.getByRole('status')).toHaveText('Saved to this business.')
  for(const width of [1440,1024,768,390,320]){await page.setViewportSize({width,height:1000});expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);await setup.screenshot({path:`${folder}/${preset}-${width}.png`})}
 }
 await setup.getByRole('button',{name:'Preview mobile'}).click()
 await setup.screenshot({path:`${folder}/mobile-preview.png`})
 await page.reload();await setup.getByRole('button',{name:'Branding',exact:true}).click()
 await expect(setup.getByLabel('Business display name',{exact:true})).toHaveValue('Fictional Studio')
 await setup.getByRole('button',{name:'Review',exact:true}).click()
 await setup.screenshot({path:`${folder}/review-320.png`})
 await admin.logout()
})
