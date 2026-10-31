import { afterEach, expect, test, vi } from 'vitest'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import AdminPage from '../src/pages/AdminPage'
afterEach(cleanup)
const shop = (id: number) => ({ id, name: `Shop ${id}`, capabilities: ['appointments', 'schedules'] })
function mount(businesses: unknown[]) {
  vi.stubGlobal('fetch', vi.fn(async (url: string) => Response.json(url === '/api/me'
    ? { authenticated: true, user: { id: 1, email: 'test@example.invalid' }, csrf_token: 'test' }
    : { businesses })))
  render(<AdminPage />)
}
test('server capabilities control navigation and switching clears shop and page context', async () => {
  mount([
    { id: 1, name: 'Owner business', capabilities: ['dashboard', 'employees', 'settings', 'access'], all_shops: ['appointments'], shops: [shop(11), shop(12)] },
    { id: 2, name: 'Manager business', capabilities: ['dashboard', 'employees', 'compensation', 'access'], all_shops: [], shops: [] },
  ])
  await screen.findByRole('button', { name: 'Business settings' })
  fireEvent.change(screen.getByLabelText('Shop'), { target: { value: '12' } })
  expect((screen.getByLabelText('Shop') as HTMLSelectElement).value).toBe('12')
  fireEvent.click(screen.getByRole('button', { name: 'Appointments and calendar' }))
  fireEvent.change(screen.getByLabelText('Business'), { target: { value: '2' } })
  expect(screen.queryByLabelText('Shop')).toBeNull()
  expect(screen.queryByRole('button', { name: 'Business settings' })).toBeNull()
  expect(screen.queryByRole('button', { name: 'Appointments and calendar' })).toBeNull()
  expect(screen.getByRole('heading', { name: 'Dashboard' })).toBeTruthy()
  expect(screen.queryByText('Shop 12')).toBeNull()
})
test('assigned-shop navigation and accessible mobile toggle do not create management permissions', async () => {
  mount([{ id: 1, name: 'Operations', capabilities: ['dashboard'], all_shops: [], shops: [shop(11), shop(12)] }])
  await screen.findByRole('button', { name: 'Staff schedules' })
  expect(screen.queryByRole('button', { name: 'Compensation' })).toBeNull()
  expect(screen.queryByRole('option', { name: 'All Shops' })).toBeNull()
  const menu = screen.getByRole('button', { name: 'Menu' })
  fireEvent.click(menu)
  expect(menu.getAttribute('aria-expanded')).toBe('true')
})
test('authenticated employee with no management context sees no management areas', async () => {
  mount([])
  await screen.findByText(/No management workspaces/)
  expect(screen.queryByRole('button', { name: 'Employees and HR' })).toBeNull()
})
test('two Owner businesses keep selections independent', async () => {
  mount([1, 2].map(id => ({ id, name: `Business ${id}`, capabilities: ['dashboard', 'employees', 'settings'], all_shops: ['appointments'], shops: [shop(id * 10)] })))
  await screen.findByRole('button', { name: 'Business settings' })
  fireEvent.change(screen.getByLabelText('Business'), { target: { value: '2' } })
  expect((screen.getByLabelText('Shop') as HTMLSelectElement).value).toBe('20')
  expect(screen.queryByText('Shop 10')).toBeNull()
  expect(screen.getByRole('button', { name: 'Business settings' })).toBeTruthy()
})
test('refresh clears stale private context when permission has been revoked', async () => {
  const fetcher = vi.fn(async (url: string) => Response.json(url === '/api/me'
    ? { authenticated: true, user: { id: 1, email: 'staff@example.invalid' }, csrf_token: 'test' }
    : { businesses: [{ id: 1, name: 'Private business', capabilities: ['dashboard', 'employees'], all_shops: [], shops: [] }] }))
  vi.stubGlobal('fetch', fetcher)
  render(<AdminPage />)
  await screen.findByRole('button', { name: 'Employees and HR' })
  fetcher.mockImplementation(async () => Response.json({ error: 'forbidden' }, { status: 403 }))
  fireEvent.click(screen.getByRole('button', { name: 'Refresh access' }))
  await screen.findByText(/Access is unavailable/)
  expect(screen.queryByText('Private business')).toBeNull()
  expect(screen.queryByRole('button', { name: 'Employees and HR' })).toBeNull()
})
