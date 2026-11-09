import { readFileSync } from 'node:fs'
import { execFileSync } from 'node:child_process'
import { test, expect } from '@playwright/test'
const file=process.env.BFF_E2E_FIXTURE
if(!file)throw Error('Use isolated runner')
const {users}=JSON.parse(readFileSync(file,'utf8')) as {users:{kind:string;username:string;password:string}[]}
function control(action:string){execFileSync('python3',['../scripts/bff_backend_control.py',action],{env:process.env,stdio:'pipe',timeout:70000})}
test('owned Phoenix outage preserves Admin and restart restores ordinary real Owner login',async({page})=>{
  test.setTimeout(120000)
  await page.goto('/admin?auth_error=login_failed&business=1')
  await expect(page.getByRole('link',{name:'Try signing in again'})).toBeVisible()
  control('stop')
  try {
    await page.getByRole('link',{name:'Try signing in again'}).click()
    await expect(page.getByText(/Magnum cannot reach its backend/)).toBeVisible()
    await expect(page).toHaveURL(/\/admin\?business=1$/)
  } finally {control('start')}
  await page.getByRole('link',{name:'Try signing in again'}).click()
  const owner=users.find(u=>u.kind==='owner')!
  await page.getByRole('textbox',{name:/email|username/i}).fill(owner.username)
  await page.getByLabel('Password',{exact:true}).fill(owner.password)
  await page.getByRole('button',{name:/sign in/i}).click()
  await expect(page).toHaveURL(/\/admin$/)
  await expect(page.getByText('Signed in as E2E',{exact:true})).toBeVisible()
  await expect(page.getByRole('link',{name:'Resume Setup'})).toBeVisible()
  await page.getByRole('button',{name:'Sign out',exact:true}).click()
})
