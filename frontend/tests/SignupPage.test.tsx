import { afterEach, test, expect, vi } from 'vitest'
import { cleanup, render, screen, fireEvent, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import SignupPage from '../src/pages/SignupPage'
afterEach(() => { cleanup(); vi.unstubAllGlobals() })
function show() { render(<MemoryRouter><SignupPage /></MemoryRouter>) }
async function fill() {
  fireEvent.change(await screen.findByLabelText('Business name'), { target: { value: 'New Detail' } })
  fireEvent.change(screen.getByLabelText('Business slug'), { target: { value: 'new-detail' } })
  fireEvent.change(screen.getByLabelText('Shop name'), { target: { value: 'Main' } })
  fireEvent.click(screen.getByRole('button', { name: 'Review business' }))
}
test('missing proof offers separate verification and normal employee entry', async () => {
  vi.stubGlobal('fetch', vi.fn(async () => new Response(null, { status: 403 })))
  show()
  expect(await screen.findByRole('button', { name: 'Continue to verification' })).toBeTruthy()
  expect(screen.getByRole('link', { name: 'Sign in' }).getAttribute('href')).toBe('/admin')
})
test('review, exact CSRF payload, duplicate protection and confirmed success', async () => {
  const fetcher = vi.fn(async (url: string) => url === '/auth/signup' ? Response.json({ csrf_token: 'masked' }) : Response.json({ data: { business_id: 9, shop_id: 10 } }))
  vi.stubGlobal('fetch', fetcher); show(); await fill()
  fireEvent.click(screen.getByRole('button', { name: 'Create business' }))
  await screen.findByText('Your business is ready')
  expect(fetcher.mock.calls.length).toBe(2)
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
  await waitFor(() => expect(fetcher).toHaveBeenCalledTimes(3))
  expect(screen.queryByRole('button', { name: 'Edit details' })).toBeNull()
})
