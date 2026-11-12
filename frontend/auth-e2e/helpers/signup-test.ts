import {test as base,expect} from '@playwright/test'
// Deliberately omit raw Playwright traces: OIDC URLs, headers and bodies contain secrets.
export const test=base.extend<{safeSignupDiagnostics:void}>({
 safeSignupDiagnostics:[async({page},use,testInfo)=>{
  const events:{method:string;path:string;status:number}[]=[]
  page.on('response',response=>{
   const url=new URL(response.url())
   if(url.origin==='http://localhost:5174')events.push({method:response.request().method(),path:url.pathname,status:response.status()})
  })
  await use()
  if(testInfo.status!==testInfo.expectedStatus){
   await testInfo.attach('redacted-signup-network',{body:JSON.stringify(events),contentType:'application/json'})
   if(new URL(page.url()).origin==='http://localhost:5174'){
    await testInfo.attach('signup-failure',{body:await page.screenshot({fullPage:true,mask:[page.locator('input,textarea')]}),contentType:'image/png'})
   }
  }
 },{auto:true}],
})
export {expect}
