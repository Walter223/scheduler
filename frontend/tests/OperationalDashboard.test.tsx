import { afterEach, expect, test, vi } from 'vitest'
import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import OperationalDashboard from '../src/components/OperationalDashboard'
afterEach(cleanup)
const data = (service = 'Mid Detail') => ({ metrics: { appointments: 1, unassigned: 0, detailers: 2, shifts: 2 }, shops: [{ id: 1, name: 'Shop A', timezone: 'America/Denver', date: '2026-11-01' }], appointments: [{ id: 1, shop_name: 'Shop A', timezone: 'America/Denver', starts_at: '2026-11-01T16:00:00Z', duration_minutes: 90, status: 'confirmed', service_name: service, crew_size: 2, lead_detailer: 'Alex Detailer' }] })
test('renders authorized totals, local appointment time, crew and lead with accessible refresh', async () => {
  vi.stubGlobal('fetch', vi.fn(async () => Response.json({ data: data() })))
  render(<OperationalDashboard businessId={1} shopId={1} />)
  await screen.findByRole('heading', { name: 'Mid Detail' })
  expect(screen.getByText('9:00 AM')).toBeTruthy()
  expect(screen.getByText('Lead: Alex Detailer')).toBeTruthy()
  expect(screen.getByText('2 Detailers')).toBeTruthy()
  fireEvent.click(screen.getByRole('button', { name: 'Refresh dashboard' }))
  await screen.findByRole('heading', { name: 'Mid Detail' })
})
test('context replacement discards prior data and rejects a late response even if transport ignores abort', async () => {
  let complete!: (v: Response) => void
  vi.stubGlobal('fetch', vi.fn((url: string) => url.includes('/1/dashboard')
    ? new Promise<Response>(resolve => { complete = resolve })
    : Promise.resolve(Response.json({ data: data('New business detail') }))))
  const view = render(<OperationalDashboard key="1" businessId={1} shopId={1} />)
  view.rerender(<OperationalDashboard key="2" businessId={2} shopId={2} />)
  await screen.findByRole('heading', { name: 'New business detail' })
  await act(async () => complete(Response.json({ data: data('Old private detail') })))
  expect(screen.queryByText('Old private detail')).toBeNull()
})
test.each([401, 403, 503])('failure %s clears private results and reports a useful error', async status => {
  const fetcher = vi.fn(async () => Response.json({ data: data() }))
  vi.stubGlobal('fetch', fetcher)
  render(<OperationalDashboard businessId={1} shopId={1} />)
  await screen.findByText('Lead: Alex Detailer')
  fetcher.mockImplementation(async () => Response.json({ error: 'denied' }, { status }))
  fireEvent.click(screen.getByRole('button', { name: 'Refresh dashboard' }))
  await screen.findByRole('alert')
  expect(screen.queryByText('Lead: Alex Detailer')).toBeNull()
})
test('empty day has accurate zeros and an explicit empty state', async () => {
  vi.stubGlobal('fetch', vi.fn(async () => Response.json({ data: { ...data(), metrics: { appointments: 0, unassigned: 0, detailers: 0, shifts: 0 }, appointments: [] } })))
  render(<OperationalDashboard businessId={1} shopId={0} />)
  await screen.findByText('No appointments scheduled today.')
  expect(screen.getAllByText('0')).toHaveLength(4)
})
