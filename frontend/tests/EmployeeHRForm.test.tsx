import { afterEach, beforeEach, expect, test, vi } from 'vitest'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import EmployeeHRForm from '../src/components/EmployeeHRForm'
import type { HRAction } from '../src/components/EmployeeHRForm'
beforeEach(() => {
  HTMLDialogElement.prototype.showModal = function () { this.open = true }
  HTMLDialogElement.prototype.close = function () { this.open = false }
})
afterEach(cleanup)
const employee = { employee_id: 10, period_id: 30, first_name: 'Taylor', last_name: 'Worker', classification: 'detailer' }
function mount(action: HRAction, overrides = {}) {
  const saved = vi.fn(), denied = vi.fn(), close = vi.fn()
  const view = render(<EmployeeHRForm action={action} businessId={1} employee={action === 'create' ? undefined : employee} shops={[{ id: 1, name: 'Shop A' }, { id: 2, name: 'Shop B' }]} assignmentId={99} assignmentName="Shop A" onSaved={saved} onDenied={denied} onClose={close} {...overrides} />)
  return { ...view, saved, denied, close }
}
function fetcher() {
  const mock = vi.fn(async (url: string) => url === '/api/me' ? Response.json({ authenticated: true, csrf_token: 'masked-test-csrf' }) : Response.json({ data: {} }))
  vi.stubGlobal('fetch', mock)
  return mock
}
test('create uses ephemeral masked CSRF and an explicit payload with no account or ownership fields', async () => {
  const mock = fetcher(), { saved } = mount('create')
  fireEvent.change(screen.getByLabelText('First name'), { target: { value: ' Alex ' } })
  fireEvent.change(screen.getByLabelText('Last name'), { target: { value: ' Driver ' } })
  fireEvent.change(screen.getByLabelText('Employment start date'), { target: { value: '2026-01-01' } })
  const form = screen.getByRole('button', { name: 'Save changes' }).closest('form')!
  const injection = document.createElement('input'); injection.name = 'user_id'; injection.value = '1'; form.append(injection)
  fireEvent.submit(form)
  await waitFor(() => expect(saved).toHaveBeenCalled())
  const [url, options] = (mock.mock.calls as unknown as [string, RequestInit][])[1]!
  expect(url).toBe('/api/admin/businesses/1/employees')
  expect(options.headers).toEqual({ 'content-type': 'application/json', 'x-csrf-token': 'masked-test-csrf' })
  expect(JSON.parse(options.body as string)).toEqual({ first_name: 'Alex', last_name: 'Driver', phone: '', email: '', home_address: '', classification: 'detailer', starts_on: '2026-01-01' })
})
test('classification keeps employee/period identifiers separate and sends no grants', async () => {
  const mock = fetcher(), { saved } = mount('classification')
  expect(screen.getByText(/does not grant application roles/)).toBeTruthy()
  fireEvent.change(screen.getByLabelText('Employment classification'), { target: { value: 'shop_manager' } })
  fireEvent.click(screen.getByRole('checkbox'))
  fireEvent.submit(screen.getByRole('button', { name: 'Save changes' }).closest('form')!)
  await waitFor(() => expect(saved).toHaveBeenCalled())
  const [url, options] = (mock.mock.calls as unknown as [string, RequestInit][])[1]!
  expect(url).toBe('/api/admin/businesses/1/employees/10/periods/30/classification')
  expect(JSON.parse(options.body as string)).toEqual({ classification: 'shop_manager' })
})
test('multiple shop assignments report partial success honestly', async () => {
  let writes = 0
  vi.stubGlobal('fetch', vi.fn(async (url: string) => url === '/api/me'
    ? Response.json({ authenticated: true, csrf_token: 'masked' })
    : ++writes === 1 ? Response.json({ data: {} }, { status: 201 }) : Response.json({ error: 'outstanding_work' }, { status: 409 })))
  const { saved } = mount('assign')
  fireEvent.click(screen.getByLabelText('Shop A')); fireEvent.click(screen.getByLabelText('Shop B'))
  fireEvent.change(screen.getByLabelText('Shop assignment start date'), { target: { value: '2026-01-01' } })
  fireEvent.submit(screen.getByRole('button', { name: 'Save changes' }).closest('form')!)
  await waitFor(() => expect(saved).toHaveBeenCalledWith(expect.stringContaining('1 shop assignment(s) saved.')))
})
test.each([401, 403, 409, 422, 503])('write failure %s is bounded, keeps server authority and reports denial', async status => {
  vi.stubGlobal('fetch', vi.fn(async (url: string) => url === '/api/me' ? Response.json({ authenticated: true, csrf_token: 'masked' }) : Response.json({ error: 'outstanding_work', private_detail: 'DO_NOT_RENDER' }, { status })))
  const { denied, saved } = mount('end')
  fireEvent.change(screen.getByLabelText('Shop assignment end date'), { target: { value: '2026-10-31' } })
  fireEvent.submit(screen.getByRole('button', { name: 'Save changes' }).closest('form')!)
  if (status === 401 || status === 403) await waitFor(() => expect(denied).toHaveBeenCalled())
  else await screen.findByRole('alert')
  expect(saved).not.toHaveBeenCalled(); expect(document.body.textContent).not.toContain('DO_NOT_RENDER')
})
test('duplicate submits are locked and unmount prevents a late success from crossing contexts', async () => {
  let finish!: (response: Response) => void
  let count = 0
  vi.stubGlobal('fetch', vi.fn(async (url: string) => {
    if (url === '/api/me') return Response.json({ authenticated: true, csrf_token: 'masked' })
    count++; return new Promise<Response>(r => { finish = r })
  }))
  const { saved, unmount } = mount('contact')
  const form = screen.getByRole('button', { name: 'Save changes' }).closest('form')!
  fireEvent.submit(form); fireEvent.submit(form)
  await waitFor(() => expect(count).toBe(1))
  expect((screen.getByRole('button', { name: 'Saving…' }).closest('fieldset') as HTMLFieldSetElement).disabled).toBe(true)
  unmount()
  await act(async () => finish(Response.json({ data: {} })))
  expect(saved).not.toHaveBeenCalled()
})
test('termination confirmation describes atomic offboarding and sends only an empty payload', async () => {
  const mock = vi.fn(async (url: string) => url === '/api/me' ? Response.json({ authenticated: true, csrf_token: 'masked-test-csrf' }) : Response.json({ data: { employment: { employee_id: 10, period_id: 30, status: 'ended' }, already_terminated: false } }))
  vi.stubGlobal('fetch', mock)
  const { saved } = mount('terminate')
  expect(screen.getByText(/Unassign future jobs and cancel future shifts/)).toBeTruthy()
  expect(screen.getByText(/Retain complete employment/)).toBeTruthy()
  expect(screen.getByText(/unrelated businesses remain unchanged/)).toBeTruthy()
  fireEvent.click(screen.getByRole('checkbox', { name: /I confirm employment termination/ }))
  const form = screen.getByRole('button', { name: 'Save changes' }).closest('form')!
  const extra = document.createElement('input'); extra.name = 'user_id'; extra.value = '1'; form.append(extra)
  fireEvent.submit(form)
  await waitFor(() => expect(saved).toHaveBeenCalled())
  const [url, options] = (mock.mock.calls as unknown as [string, RequestInit][])[1]!
  expect(url).toBe('/api/admin/businesses/1/employees/10/periods/30/terminate')
  expect(JSON.parse(options.body as string)).toEqual({})
})
test('rehire requires a later inclusive date and creates a new period on the stable identity path', async () => {
  const mock = fetcher(), { saved } = mount('rehire', { employee: { ...employee, ends_on: '2026-10-31' } })
  const input = screen.getByLabelText('Rehire start date')
  expect(input.getAttribute('min')).toBe('2026-11-01')
  expect(screen.getByText(/It restores no business memberships/)).toBeTruthy()
  fireEvent.click(screen.getByRole('checkbox', { name: /I confirm a new employment period/ }))
  fireEvent.change(input, { target: { value: '2026-10-31' } })
  const form = screen.getByRole('button', { name: 'Save changes' }).closest('form')!
  fireEvent.submit(form)
  await screen.findByRole('alert')
  expect(mock).not.toHaveBeenCalled()
  fireEvent.change(input, { target: { value: '2026-11-01' } })
  fireEvent.submit(form)
  await waitFor(() => expect(saved).toHaveBeenCalled())
  const [url, options] = (mock.mock.calls as unknown as [string, RequestInit][])[1]!
  expect(url).toBe('/api/admin/businesses/1/employees/10/periods/30/rehire')
  expect(JSON.parse(options.body as string)).toEqual({ starts_on: '2026-11-01' })
})
test.each(['work_in_progress', 'future_assignment_dates', 'last_owner', 'offboarding_required'])('termination blocker %s never reports success', async code => {
  vi.stubGlobal('fetch', vi.fn(async (url: string) => url === '/api/me' ? Response.json({ authenticated: true, csrf_token: 'masked' }) : Response.json({ error: code, secret: 'PRIVATE' }, { status: 409 })))
  const { saved } = mount('terminate')
  fireEvent.click(screen.getByRole('checkbox'))
  fireEvent.submit(screen.getByRole('button', { name: 'Save changes' }).closest('form')!)
  await screen.findByRole('alert')
  expect(saved).not.toHaveBeenCalled()
  expect(document.body.textContent).not.toContain('PRIVATE')
})
test('duplicate termination is locked and a context teardown discards late completion', async () => {
  let finish!: (v: Response) => void
  let writes = 0
  vi.stubGlobal('fetch', vi.fn(async (url: string) => {
    if (url === '/api/me') return Response.json({ authenticated: true, csrf_token: 'masked' })
    writes++; return new Promise<Response>(resolve => { finish = resolve })
  }))
  const { saved, unmount } = mount('terminate')
  fireEvent.click(screen.getByRole('checkbox'))
  const form = screen.getByRole('button', { name: 'Save changes' }).closest('form')!
  fireEvent.submit(form); fireEvent.submit(form)
  await waitFor(() => expect(writes).toBe(1))
  unmount()
  await act(async () => finish(Response.json({ data: {} })))
  expect(saved).not.toHaveBeenCalled()
})

test('already-terminated responses report a no-op rather than new offboarding', async () => {
  vi.stubGlobal('fetch', vi.fn(async (url: string) => url === '/api/me' ? Response.json({ authenticated: true, csrf_token: 'masked' }) : Response.json({ data: { employment: { employee_id: 10, period_id: 30, status: 'ended' }, already_terminated: true } })))
  const { saved } = mount('terminate')
  fireEvent.click(screen.getByRole('checkbox'))
  fireEvent.submit(screen.getByRole('button', { name: 'Save changes' }).closest('form')!)
  await waitFor(() => expect(saved).toHaveBeenCalledWith(expect.stringContaining('already terminated')))
})
test('Escape cannot dismiss a pending save and becomes available after completion', async () => {
  let finish!: (value: Response) => void
  const mock = vi.fn((url: string) => url === '/api/me' ? Promise.resolve(Response.json({authenticated:true,csrf_token:'synthetic'})) : new Promise<Response>(r => { finish=r }))
  vi.stubGlobal('fetch',mock)
  const {close,saved}=mount('contact')
  fireEvent.submit(screen.getByRole('button',{name:'Save changes'}).closest('form')!)
  await waitFor(()=>expect(mock).toHaveBeenCalledTimes(2))
  const dialog=screen.getByRole('dialog')
  fireEvent(dialog,new Event('cancel',{cancelable:true}))
  expect(close).not.toHaveBeenCalled()
  await act(async()=>finish(Response.json({data:{}})))
  await waitFor(()=>expect(saved).toHaveBeenCalled())
  fireEvent(dialog,new Event('cancel',{cancelable:true}))
  expect(close).toHaveBeenCalledOnce()
})
