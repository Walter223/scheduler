import {readFileSync,mkdirSync} from 'node:fs'
import {test,expect} from '@playwright/test'
import {AdminPage} from './pages/AdminPage'
const {users}=JSON.parse(readFileSync(process.env.BFF_E2E_FIXTURE!,'utf8'))
test('real Owner reviews and approves structured guided setup edits and resumes history',async({page})=>{
 const admin=new AdminPage(page);await admin.login(users.find((u:{kind:string})=>u.kind==='owner'))
 await page.getByRole('link',{name:'Resume Setup',exact:true}).click()
 const setup=page.getByRole('region',{name:'Business setup'}),guide=page.getByRole('region',{name:'Guided setup assistant'})
 await setup.getByRole('button',{name:'Branding',exact:true}).click()
 await setup.getByLabel('Business display name',{exact:true}).fill('Guided Fictional Studio')
 await guide.getByRole('combobox',{name:'Setup topic'}).selectOption('branding')
 await guide.getByRole('button',{name:'Propose current editor changes'}).click()
 await expect(guide.getByRole('button',{name:'Approve proposed changes'})).toBeVisible()
 mkdirSync('/private/tmp/magnum-guided-onboarding',{recursive:true})
 for(const width of [1440,1024,768,390,320]){await page.setViewportSize({width,height:1000});expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);await guide.screenshot({path:`/private/tmp/magnum-guided-onboarding/proposal-${width}.png`})}
 await guide.getByRole('button',{name:'Approve proposed changes'}).click()
 await expect(guide.getByText(/You: approve branding/)).toBeVisible()
 await page.reload();await setup.getByRole('button',{name:'Branding',exact:true}).click()
 await expect(setup.getByLabel('Business display name',{exact:true})).toHaveValue('Guided Fictional Studio')
 await expect(guide.getByRole('list',{name:'Conversation history'})).toContainText('approve branding')
 await admin.logout()
})
