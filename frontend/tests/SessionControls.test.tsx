import { afterEach, expect, test, vi } from 'vitest'
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import SessionControls from '../src/components/SessionControls'

afterEach(() => { cleanup(); window.history.replaceState({}, '', '/') })

test('signed-out admin entry provides the Phoenix login link', async () => {
  const fetcher = vi.fn(async () => Response.json({ authenticated: false, user: null, csrf_token: null }))
  vi.stubGlobal('fetch', fetcher)
  render(<SessionControls />)
  await screen.findByRole('link', { name: 'Staff sign in' })
  expect(fetcher).toHaveBeenCalledTimes(1)
  expect(screen.getByRole('link', { name: 'Staff sign in' }).getAttribute('href')).toBe('/auth/login')
  expect(screen.queryByRole('button', { name: 'Sign out' })).toBeNull()
})

test('authenticated logout sends the masked CSRF token and clears local profile', async () => {
  const fetcher = vi.fn(async (url: string) => url === '/api/me'
    ? Response.json({ authenticated: true, user: { id: 1, email: 'staff@example.invalid', first_name: 'Alex', last_name: 'Staff' }, csrf_token: 'synthetic-masked-csrf' })
    : Response.json({ ok: true }))
  vi.stubGlobal('fetch', fetcher)
  render(<SessionControls />)
  fireEvent.click(await screen.findByRole('button', { name: 'Sign out' }))
  await waitFor(() => expect(screen.queryByRole('button', { name: 'Sign out' })).toBeNull())
  expect(fetcher).toHaveBeenLastCalledWith('/auth/logout', {
    method: 'POST', headers: { 'x-csrf-token': 'synthetic-masked-csrf' },
  })
  expect(screen.queryByText('Signed in as Alex')).toBeNull()
  expect(screen.getByRole('status').textContent).toContain('Signed out of Magnum')
})

test('failed logout does not claim the server session was revoked', async () => {
  vi.stubGlobal('fetch', vi.fn(async (url: string) => url === '/api/me'
    ? Response.json({ authenticated: true, user: { id: 1, email: 'staff@example.invalid', first_name: 'Alex' }, csrf_token: 'synthetic' })
    : Response.json({ error: 'unavailable' }, { status: 503 })))
  render(<SessionControls />)
  fireEvent.click(await screen.findByRole('button', { name: 'Sign out' }))
  expect((await screen.findByRole('status')).textContent).toContain('could not be completed')
  expect(screen.getByText('Signed in as Alex')).toBeTruthy()
})

test('pending denial uses a bounded message; unexpected provider text is never reflected', async () => {
  window.history.replaceState({}, '', '/admin?auth_error=account_unavailable&error_description=untrusted')
  vi.stubGlobal('fetch', vi.fn(async () => Response.json({ authenticated: false })))
  render(<SessionControls />)
  await waitFor(() => expect(screen.getByRole('status').textContent).toContain('Contact your administrator'))
  expect(document.body.textContent).not.toContain('untrusted')
})

test('invalid session responses show a safe error without affecting booking', async () => {
  vi.stubGlobal('fetch', vi.fn(async () => Response.json({ authenticated: true, user: null })))
  render(<SessionControls />)
  await waitFor(() => expect(screen.getByRole('status').textContent).toContain('Account status is temporarily unavailable'))
})

test('authenticated validation clears stale login error and consumes only auth_error without reload', async () => {
  window.history.replaceState({ keep: true }, '', '/admin?auth_error=login_failed&other=keep#workspace')
  vi.stubGlobal('fetch', vi.fn(async () => Response.json({ authenticated: true, user: { id:1, email:'test@example.invalid' }, csrf_token:'synthetic' })))
  render(<SessionControls />)
  await screen.findByRole('button', { name: 'Sign out' })
  expect(screen.queryByText(/Sign-in could not be completed/)).toBeNull()
  expect(window.location.search).toBe('?other=keep')
  expect(window.location.hash).toBe('#workspace')
  expect(window.history.state).toEqual({ keep: true })
})
test('genuine login failure remains visible after its URL parameter is consumed', async () => {
  window.history.replaceState({}, '', '/admin?auth_error=login_failed')
  vi.stubGlobal('fetch', vi.fn(async () => Response.json({authenticated:false})))
  render(<SessionControls />)
  await screen.findByText('Sign-in could not be completed. Please start a new login.')
  expect(window.location.search).toBe('')
  expect(screen.getByRole('link', { name:'Try signing in again' })).toBeTruthy()
})

test('backend outage preserves page and retries only a read-only health probe',async()=>{
  window.history.replaceState({},'', '/admin?business=2')
  const fetcher=vi.fn(async()=>new Response(null,{status:502}))
  vi.stubGlobal('fetch',fetcher)
  render(<SessionControls/>)
  fireEvent.click(await screen.findByRole('link',{name:'Try signing in again'}))
  await screen.findByText(/Magnum cannot reach its backend/)
  expect(window.location.search).toBe('?business=2')
  expect(fetcher.mock.calls.length).toBe(2)
  expect(fetcher).toHaveBeenLastCalledWith('/api/me',expect.objectContaining({cache:'no-store'}))
  expect(screen.getByRole('link',{name:'Try signing in again'}).getAttribute('href')).toBe('/auth/login')
})
