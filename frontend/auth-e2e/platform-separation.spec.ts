import { readFileSync, mkdirSync } from 'node:fs'
import { test, expect } from '@playwright/test'
import { AdminPage } from './pages/AdminPage'
const file=process.env.BFF_E2E_FIXTURE
if(!file)throw Error('Use isolated runner')
const {users}=JSON.parse(readFileSync(file,'utf8')) as {users:{kind:string;username:string;password:string}[]}
const folder='/private/tmp/magnum-platform'
test('platform, signup and customer website have separate responsive identities',async({page})=>{
  mkdirSync(folder,{recursive:true})
  for(const width of [1440,1024,768,390,320]){
    await page.setViewportSize({width,height:1000})
    await page.goto('/platform')
    await expect(page.getByRole('link',{name:'Create a Business',exact:true})).toHaveAttribute('href','/signup')
    expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true)
    await page.screenshot({path:`${folder}/platform-${width}.png`,fullPage:true})
    await page.goto('/signup')
    await expect(page.getByRole('button',{name:'I already have an account'})).toBeVisible()
    await page.screenshot({path:`${folder}/signup-${width}.png`,fullPage:true})
  }
  for(const width of [1440,390]){
    await page.setViewportSize({width,height:1000});await page.goto('/')
    await expect(page.getByRole('link',{name:'Create a business',exact:true})).toHaveCount(0)
    await expect(page.getByRole('link',{name:'Services',exact:true})).toBeVisible()
    await page.screenshot({path:`${folder}/detailing-home-${width}.png`,fullPage:true})
  }
})
test('real multi-business Owner resumes dedicated Setup, preserves selection and loses access after logout',async({page})=>{
  mkdirSync(folder,{recursive:true})
  const admin=new AdminPage(page)
  await admin.login(users.find(u=>u.kind==='multi_owner')!)
  await expect(page.getByRole('link',{name:'Resume Setup'})).toBeVisible()
  const first=await admin.business.inputValue()
  const ids=await admin.business.getByRole('option').evaluateAll(options=>options.map(o=>(o as HTMLOptionElement).value).filter(v=>v!=='0'))
  const second=ids.find(id=>id!==first)!
  await admin.business.selectOption(second)
  await expect(page).toHaveURL(new RegExp(`business=${second}`))
  await admin.business.selectOption(first)
  await expect(page).toHaveURL(new RegExp(`business=${first}`))
  await page.screenshot({path:`${folder}/admin-resume-1440.png`,fullPage:true})
  await page.setViewportSize({width:390,height:1000})
  await page.screenshot({path:`${folder}/admin-resume-390.png`,fullPage:true})
  await page.setViewportSize({width:1440,height:1000})
  await page.getByRole('link',{name:'Resume Setup'}).click()
  await expect(page).toHaveURL(`/setup/${first}`)
  await expect(page.getByRole('heading',{name:'Business Setup',exact:true})).toBeVisible()
  await expect(page.getByRole('navigation',{name:'Admin areas'})).toHaveCount(0)
  await expect(page.getByText('Saved setup loaded.')).toBeVisible()
  for(const width of [1440,1024,768,390,320]){
    await page.setViewportSize({width,height:1000})
    expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true)
    await page.screenshot({path:`${folder}/setup-${width}.png`,fullPage:true})
  }
  await page.getByLabel('Business',{exact:true}).selectOption(second)
  await expect(page).toHaveURL(`/setup/${second}`)
  await expect(page.getByText('Begin setup to save private proposals for this business.')).toBeVisible()
  await page.getByLabel('Business',{exact:true}).selectOption(first)
  await expect(page.getByText('Saved setup loaded.')).toBeVisible()
  await page.getByRole('link',{name:'Open management workspace'}).click()
  await page.setViewportSize({width:1440,height:1000})
  await expect(admin.business).toHaveValue(first)
  await page.screenshot({path:`${folder}/admin-resume-return-1440.png`,fullPage:true})
  await page.goBack()
  await expect(page.getByText('Saved setup loaded.')).toBeVisible()
  await page.getByRole('button',{name:'Sign out',exact:true}).click()
  await page.reload()
  await expect(page.getByRole('link',{name:'Staff sign in'})).toBeVisible()
  await expect(page.getByRole('region',{name:'Business setup'})).toHaveCount(0)
})
