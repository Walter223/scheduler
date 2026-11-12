import {StrictMode} from 'react'
import { afterEach, test, expect, vi } from 'vitest'
import { cleanup, render, screen, fireEvent, waitFor, within } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import SignupPage from '../src/pages/SignupPage'
afterEach(() => { cleanup(); vi.unstubAllGlobals() })
function show() { render(<MemoryRouter><SignupPage /></MemoryRouter>) }
async function fill() {
  fireEvent.change(await screen.findByLabelText('Business name'), { target: { value: 'New Detail' } })
  fireEvent.change(screen.getByLabelText('Booking website address'), { target: { value: 'new-detail' } })
  fireEvent.change(screen.getByLabelText('Shop name'), { target: { value: 'Main' } })
  fireEvent.click(screen.getByRole('button', { name: 'Review business' }))
}
test('missing proof offers separate verification and normal employee entry', async () => {
  vi.stubGlobal('fetch', vi.fn(async () => new Response(null, { status: 403 })))
  show()
  expect(await screen.findByRole('button', { name: 'I already have an account' })).toBeTruthy()
  expect(screen.getByRole('link', { name: 'Sign in' }).getAttribute('href')).toBe('/admin')
})
test('review, exact CSRF payload, duplicate protection and confirmed success', async () => {
  const fetcher = vi.fn(async (url: string) => url === '/auth/signup' ? Response.json({ csrf_token: 'masked' }) : Response.json({ data: { business_id: 9, shop_id: 10, business_name: 'New Detail' } }))
  vi.stubGlobal('fetch', fetcher); show(); await fill()
  fireEvent.click(screen.getByRole('button', { name: 'Create business' }))
  await screen.findByText('Your business is ready')
  expect(fetcher.mock.calls.filter(([url])=>url !== '/auth/signup/timezones').length).toBe(2)
  expect(screen.getByRole('link', { name: 'Sign in to Magnum' }).getAttribute('href')).toBe('/auth/login')
})
for (const status of [403, 409, 422, 429, 503]) test(`safe server error ${status} never claims success`, async () => {
  vi.stubGlobal('fetch', vi.fn(async (url: string) => url === '/auth/signup' ? Response.json({ csrf_token: 'masked' }) : new Response(null, { status })))
  show(); await fill(); fireEvent.click(screen.getByRole('button', { name: 'Create business' }))
  await screen.findByRole('alert')
  expect(screen.queryByText('Your business is ready')).toBeNull()
})
test('uncertain result permits only identical retry', async () => {
  const fetcher = vi.fn(async (url: string) => { if (url === '/auth/signup') return Response.json({ csrf_token: 'masked' }); throw Error('network') })
  vi.stubGlobal('fetch', fetcher); show(); await fill()
  fireEvent.click(screen.getByRole('button', { name: 'Create business' }))
  fireEvent.click(await screen.findByRole('button', { name: 'Retry same request' }))
  await waitFor(() => expect(fetcher.mock.calls.filter(([url])=>url !== '/auth/signup/timezones')).toHaveLength(3))
  expect(screen.queryByRole('button', { name: 'Edit details' })).toBeNull()
})
test('completed proof restores named success without provisioning or navigation',async()=>{
 vi.stubGlobal('fetch',vi.fn(async()=>Response.json({completed:true,data:{business_id:9,shop_id:10,business_name:'Confirmed company'}})))
 show();await screen.findByText('Confirmed company');expect(screen.queryByRole('button',{name:'Create business'})).toBeNull()
})
test('name-derived address stops changing after manual customization; help closes with Escape',async()=>{
 vi.stubGlobal('fetch',vi.fn(async(url:string)=>url.endsWith('/timezones')?Response.json({timezones:['America/Denver','Europe/Paris','Etc/UTC']}):Response.json({csrf_token:'masked'})))
 show();fireEvent.change(await screen.findByLabelText('Business name'),{target:{value:'A New Studio'}})
 expect(screen.getByLabelText('Booking website address')).toHaveProperty('value','a-new-studio')
 fireEvent.change(screen.getByLabelText('Booking website address'),{target:{value:'my-address'}})
 fireEvent.change(screen.getByLabelText('Business name'),{target:{value:'Another name'}})
 expect(screen.getByLabelText('Booking website address')).toHaveProperty('value','my-address')
 const help=screen.getByLabelText('Help: Booking website address');fireEvent.click(help)
 fireEvent.keyDown(help,{key:'Escape'});expect(help.closest('details')!.open).toBe(false)
})
test('help disclosure has an explicit close action and no submit side effect',async()=>{
 vi.stubGlobal('fetch',vi.fn(async()=>Response.json({csrf_token:'masked'})))
 show();await screen.findByLabelText('Business name')
 const summary=screen.getByLabelText('Help: First-shop URL identifier')
 fireEvent.click(summary)
 fireEvent.click(within(summary.closest('details')!).getByRole('button',{name:'Close help'}))
 expect(summary.closest('details')!.open).toBe(false)
 expect(screen.getByLabelText('Business name')).toBeTruthy()
})
test('missing signup verification explains restart without automatically initiating OIDC',async()=>{
 const fetcher=vi.fn(async()=>new Response(JSON.stringify({error:'signup_unavailable'}),{status:403,headers:{'Content-Type':'application/json'}}))
 vi.stubGlobal('fetch',fetcher);show()
 await screen.findByRole('button',{name:'I already have an account'})
 expect(fetcher.mock.calls).toHaveLength(1)
 expect(screen.queryByLabelText('Business name')).toBeNull()
 expect(screen.getByRole('button',{name:'I already have an account'})).toBeTruthy()
})

test('StrictMode repeats only read-only status requests and never initiates OIDC automatically',async()=>{
 const calls:{url:string;method:string}[]=[]
 vi.stubGlobal('fetch',vi.fn(async(url:string,opts?:RequestInit)=>{calls.push({url,method:opts?.method || 'GET'});return new Response(JSON.stringify({error:'signup_unavailable'}),{status:403})}))
 render(<StrictMode><MemoryRouter><SignupPage/></MemoryRouter></StrictMode>)
 await screen.findByRole('button',{name:'I already have an account'})
 expect(calls).toEqual([{url:'/auth/signup',method:'GET'},{url:'/auth/signup',method:'GET'}])
})

test('normal first visit offers account choices without a missing-proof alert',async()=>{
 vi.stubGlobal('fetch',vi.fn(async()=>Response.json({error:'signup_verification_required'},{status:403})))
 show();await screen.findByRole('button',{name:'Create an account'})
 expect(screen.getByRole('button',{name:'I already have an account'})).toBeTruthy()
 expect(screen.queryByRole('alert')).toBeNull()
})
