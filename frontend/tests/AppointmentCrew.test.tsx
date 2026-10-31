import { afterEach, expect, test, vi } from 'vitest'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import AppointmentCrew from '../src/components/AppointmentCrew'
afterEach(cleanup)
const member = (id: number, is_lead = false) => ({ id, first_name: `Detailer${id}`, last_name: 'Test', is_lead })
const candidate = { assignment_id: 10, employee_id: 20, period_id: 30, first_name: 'New', last_name: 'Detailer' }
const base = '/api/admin/businesses/1/shops/2/appointments/3/team'
function setup(status = 200, code = '', editable = true) {
  let members = [member(1, true), member(2)]
  const changed = vi.fn(), denied = vi.fn()
  const fetcher = vi.fn(async (url: string, options?: RequestInit) => {
    if (url === '/api/me') return Response.json({ authenticated: true, csrf_token: 'masked-test-token' })
    if (options?.method === 'POST') {
      if (status !== 200) return Response.json({ error: code }, { status })
      if (url.endsWith('/remove')) members = members.filter(m => m.id !== 1)
      else if (url.endsWith('/clear-lead')) members = members.map(m => ({ ...m, is_lead: false }))
      else if (url.endsWith('/lead')) members = members.map(m => ({ ...m, is_lead: m.id === 2 }))
      else members = [...members, member(3)]
      return Response.json({ data: {} })
    }
    if (url.includes('/candidates')) return Response.json({ data: { candidates: [candidate], has_more: false, next_cursor: null } })
    return Response.json({ data: { assignments: members, has_more: false, next_cursor: null } })
  })
  vi.stubGlobal('fetch', fetcher)
  const props = { businessId: 1, shopId: 2, appointmentId: 3, editable, onChanged: changed, onDenied: denied }
  const view = render(<AppointmentCrew {...props} />)
  return { fetcher, changed, denied, view, props }
}
test('add, transfer, clear and remove operate on individuals with fresh session CSRF', async () => {
  const { fetcher, changed } = setup()
  await screen.findByText('Detailer1 Test · Lead')
  fireEvent.change(screen.getByLabelText('Eligible Detailer'), { target: { value: '10' } })
  fireEvent.click(screen.getByRole('button', { name: 'Add Detailer' }))
  await screen.findByText('Detailer3 Test')
  expect(screen.getByText('Detailer1 Test · Lead')).toBeTruthy()
  expect(screen.getByText('Detailer2 Test')).toBeTruthy()
  expect(fetcher).toHaveBeenCalledWith(base, expect.objectContaining({ method: 'POST', headers: expect.objectContaining({ 'x-csrf-token': 'masked-test-token' }), body: JSON.stringify({ employee_id: 20, period_id: 30, assignment_id: 10 }) }))
  fireEvent.click(screen.getByRole('button', { name: 'Make Detailer2 Test lead' }))
  await screen.findByText('Detailer2 Test · Lead')
  fireEvent.click(screen.getByRole('button', { name: 'Clear Lead Detailer' }))
  await waitFor(() => expect(screen.queryByText(/Test · Lead/)).toBeNull())
  fireEvent.click(screen.getByRole('button', { name: 'Remove Detailer1 Test' }))
  await waitFor(() => expect(screen.queryByText('Detailer1 Test')).toBeNull())
  expect(screen.getByText('Detailer2 Test')).toBeTruthy()
  expect(changed).toHaveBeenCalledTimes(4)
})
test.each([[409, 'overlap', 'overlapping assigned work'], [409, 'missing_covering_shift', '30-minute buffer'], [409, 'already_assigned', 'already assigned'], [503, '', 'could not be confirmed']])('safe mutation feedback %s/%s', async (status, code, text) => {
  setup(Number(status), code)
  fireEvent.click(await screen.findByRole('button', { name: 'Remove Detailer1 Test' }))
  expect((await screen.findByRole('alert')).textContent).toContain(text)
})
test.each([401,403])('revoked access %s clears crew and reports denial', async status => {
  const { denied } = setup(status)
  fireEvent.click(await screen.findByRole('button', { name: 'Remove Detailer1 Test' }))
  await waitFor(() => expect(denied).toHaveBeenCalledOnce())
  expect(screen.queryByText('Detailer1 Test · Lead')).toBeNull()
})
test('duplicate submissions are locked and unmounted responses cannot refresh another context', async () => {
  let finish!: (r: Response) => void
  const { fetcher, changed, view } = setup()
  await screen.findByText('Detailer1 Test · Lead')
  const original = fetcher.getMockImplementation()!
  fetcher.mockImplementation((url, opts) => opts?.method === 'POST' ? new Promise<Response>(r => { finish = r }) : original(url, opts))
  const remove = screen.getByRole('button', { name: 'Remove Detailer1 Test' })
  fireEvent.click(remove); fireEvent.click(remove)
  await waitFor(() => expect(fetcher.mock.calls.filter(([,o]) => o?.method === 'POST')).toHaveLength(1))
  expect((remove as HTMLButtonElement).disabled).toBe(true)
  view.unmount()
  await act(async () => finish(Response.json({ data: {} })))
  expect(changed).not.toHaveBeenCalled()
})
test('noneditable appointment shows team without mutation controls or candidates', async () => {
  const { fetcher } = setup(200, '', false)
  await screen.findByText('Detailer1 Test · Lead')
  expect(screen.queryByRole('button', { name: /Remove Detailer/ })).toBeNull()
  expect(screen.queryByLabelText('Eligible Detailer')).toBeNull()
  expect(fetcher.mock.calls.some(([u]) => u.includes('/candidates'))).toBe(false)
})
test('all team pages are followed without a hardcoded crew-size cap', async () => {
  const fetcher = vi.fn(async (url: string) => Response.json({ data: url.includes('cursor=next-page')
    ? { assignments: [member(101)], has_more: false, next_cursor: null }
    : { assignments: Array.from({ length: 100 }, (_, i) => member(i + 1)), has_more: true, next_cursor: 'next-page' } }))
  vi.stubGlobal('fetch', fetcher)
  render(<AppointmentCrew businessId={1} shopId={2} appointmentId={3} editable={false} onChanged={vi.fn()} onDenied={vi.fn()} />)
  await screen.findByText('Detailer101 Test')
  expect(screen.getAllByRole('listitem')).toHaveLength(101)
  expect(fetcher).toHaveBeenCalledTimes(2)
})
