import { afterEach, expect, test, vi } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import App from '../src/App'

vi.mock('../src/pages/HomePage', () => ({ default: () => <main>Public home</main> }))
vi.mock('../src/pages/ServicesPage', () => ({ default: () => <main>Public services</main> }))
vi.mock('../src/pages/BookingPage', () => ({ default: () => <main>Public booking</main> }))

afterEach(() => { cleanup(); window.history.replaceState({}, '', '/') })

function mount(path: string) {
  window.history.replaceState({}, '', path)
  vi.stubGlobal('scrollTo', vi.fn())
  return render(<MemoryRouter initialEntries={[path]}><App /></MemoryRouter>)
}

test.each(['/', '/services', '/contact'])('public route %s has no account UI, auth errors or session requests', (path) => {
  const fetcher = vi.fn()
  vi.stubGlobal('fetch', fetcher)
  mount(path + '?auth_error=provider_unavailable')
  expect(screen.queryByRole('region', { name: 'Account' })).toBeNull()
  expect(screen.queryByText(/Sign-in is temporarily unavailable/)).toBeNull()
  expect(screen.queryByRole('link', { name: /staff sign in/i })).toBeNull()
  expect(fetcher).not.toHaveBeenCalled()
})

test('direct admin entry owns login error and retry without querying privileged data', async () => {
  const fetcher = vi.fn(async (url: string) => {
    if (url !== '/api/me') throw new Error('Unexpected privileged API request')
    return Response.json({ authenticated: false, user: null, csrf_token: null })
  })
  vi.stubGlobal('fetch', fetcher)
  mount('/admin?auth_error=provider_unavailable')
  expect(screen.getByRole('heading', { name: 'Staff account' })).toBeTruthy()
  await screen.findByRole('link', { name: 'Try signing in again' })
  expect(screen.getByRole('status').textContent).toContain('Sign-in is temporarily unavailable')
  expect(screen.getByRole('link', { name: 'Try signing in again' }).getAttribute('href')).toBe('/auth/login')
  expect(fetcher).toHaveBeenCalledTimes(1)
  expect(fetcher.mock.calls[0]?.[0]).toBe('/api/me')
})

test('signed-in admin entry shows identity without implying authorization', async () => {
  const fetcher = vi.fn(async (url: string) => {
    if (url !== '/api/me') throw new Error('Unexpected privileged API request')
    return Response.json({ authenticated: true, user: { id: 1, email: 'staff@example.invalid', first_name: 'Alex' }, csrf_token: 'synthetic' })
  })
  vi.stubGlobal('fetch', fetcher)
  mount('/admin')
  await screen.findByText('Signed in as Alex')
  expect(screen.getByText(/does not grant business or shop access/)).toBeTruthy()
  expect(screen.getByRole('button', { name: 'Sign out' })).toBeTruthy()
  expect(fetcher).toHaveBeenCalledTimes(1)
  expect(screen.queryByRole('link', { name: /staff sign in/i })).toBeNull()
})
