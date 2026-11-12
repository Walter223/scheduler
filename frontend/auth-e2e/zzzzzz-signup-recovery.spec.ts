import {readFileSync} from 'node:fs'
import {randomBytes} from 'node:crypto'
import {test,expect} from '@playwright/test'
import {AdminPage} from './pages/AdminPage'
const {users}=JSON.parse(readFileSync(process.env.BFF_E2E_FIXTURE!,'utf8'))
test('Owner with only temporary login binding gets JSON 403, restarts signup, and repeated reads never consume proof',async({page,context})=>{
 const admin=new AdminPage(page)
 await admin.login(users.find((u:{kind:string})=>u.kind==='owner'))
 await expect(page.getByText('Signed in as E2E',{exact:true})).toBeVisible()
 // This is a generated credential in this disposable browser, never a personal cookie.
 await context.addCookies([{name:'magnum_login_dev',value:randomBytes(32).toString('base64url'),url:'http://localhost:5174',httpOnly:true,sameSite:'Lax',expires:Math.floor(Date.now()/1000)+600}])
 const status=page.waitForResponse(r=>r.url().endsWith('/auth/signup') && r.request().method()==='GET')
 const abortedReads:string[]=[]
 page.on('requestfailed',r=>{if(r.url().endsWith('/auth/signup'))abortedReads.push(r.failure()?.errorText || 'unknown')})
 let initiations=0
 page.on('request',r=>{if(r.url().endsWith('/auth/signup/login') && r.method()==='POST')initiations++})
 await page.goto('/signup')
 const response=await status
 expect(response.status()).toBe(403)
 // StrictMode may abort the first response after headers; inspect a completed read
 // rather than asking Chromium for the body of a deliberately aborted fetch.
 const completed=await page.request.get('/auth/signup')
 expect(completed.status()).toBe(403)
 expect(await completed.json()).toEqual({error:'signup_unavailable'})
 expect(abortedReads.every(reason=>reason.includes('ERR_ABORTED'))).toBe(true)
 await expect(page.getByText(/Your ordinary Magnum sign-in is separate/)).toBeVisible()
 expect((await (await page.request.get('/api/me')).json()).authenticated).toBe(true)
 for(let i=0;i<2;i++)expect((await page.request.get('/auth/signup')).status()).toBe(403)
 expect(initiations).toBe(0)
 await page.getByRole('button',{name:'Continue to verification'}).click()
 await expect(page.getByLabel('Business name',{exact:true})).toBeVisible()
 expect(initiations).toBe(1)
 const cookies=await context.cookies('http://localhost:5174')
 for(const name of ['magnum_onboarding_dev','magnum_onboarding_binding_dev']){
  const cookie=cookies.find(c=>c.name===name)!
  expect({path:cookie.path,domain:cookie.domain,httpOnly:cookie.httpOnly,secure:cookie.secure,sameSite:cookie.sameSite}).toEqual({path:'/',domain:'localhost',httpOnly:true,secure:false,sameSite:'Lax'})
 }
 expect(cookies.some(c=>c.name==='magnum_login_dev')).toBe(false)
 for(let i=0;i<2;i++)expect((await page.request.get('/auth/signup')).status()).toBe(200)
 await page.evaluate(()=>{window.dispatchEvent(new Event('blur'));window.dispatchEvent(new Event('focus'))})
 await page.reload();await expect(page.getByLabel('Business name',{exact:true})).toBeVisible()
 expect(initiations).toBe(1)
 const proof=cookies.find(c=>c.name==='magnum_onboarding_dev')!
 await context.addCookies([{...proof,expires:Math.floor(Date.now()/1000)-1}])
 await page.reload()
 await expect(page.getByText(/Your ordinary Magnum sign-in is separate/)).toBeVisible()
 await page.getByRole('button',{name:'Continue to verification'}).click()
 await expect(page.getByLabel('Business name',{exact:true})).toBeVisible()
 expect(initiations).toBe(2)
 await page.goto('/admin');await admin.logout()
})
