import { afterEach, describe, expect, test, vi } from 'vitest'
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import BookingPage from '../src/pages/BookingPage'

afterEach(cleanup)

function mount() {
  return render(<MemoryRouter initialEntries={['/contact?service=1&size=1']}>
    <BookingPage />
  </MemoryRouter>)
}

describe('catalog failure presentation', () => {
  const cases = [
    { name: 'HTTP error', response: () => Promise.resolve(Response.json({ error: 'Unavailable' }, { status: 503 })) },
    { name: 'invalid JSON', response: () => Promise.resolve(new Response('not JSON')) },
    { name: 'network failure', response: () => Promise.reject(new TypeError('Failed to fetch')) },
    { name: 'unexpected object', response: () => Promise.resolve(Response.json({ services: [] })) },
    { name: 'malformed nested prices', response: () => Promise.resolve(Response.json([
      { id: 1, name: 'Detail', description: '', prices: [null] },
    ])) },
  ]
  test.each(cases)('$name shows loading then a meaningful error instead of no selection', async ({ response }) => {
    let release = () => {}
    const pending = new Promise<Response>((resolve, reject) => {
      release = () => { void response().then(resolve, reject) }
    })
    vi.stubGlobal('fetch', vi.fn(() => pending))
    mount()
    expect(screen.getByRole('status').textContent).toBe('Loading detailing services...')
    expect(screen.queryByText('No Detail Selected')).toBeNull()
    await act(async () => { release() })
    expect((await screen.findByRole('alert')).textContent).toContain('Please reload the page to try again.')
    expect(screen.queryByText('No Detail Selected')).toBeNull()
    expect(screen.queryByRole('button', { name: 'Book Appointment' })).toBeNull()
  })
})

const catalog = [{
  id: 1, name: 'Mid Detail', description: 'Component test catalog',
  prices: [{ service_price_id: 4, vehicle_size_id: 1, vehicle_size: 'Small',
    price_cents: 8999, duration_minutes: 90 }],
}]
const customer = {
  'First Name': 'Alex', 'Last Name': 'Driver', Email: 'alex@example.com',
  Phone: '303-555-0100', Make: 'Toyota', Model: 'Camry', Notes: 'Call on arrival.',
}

async function submitRejectedBooking(errors: unknown) {
  vi.stubGlobal('fetch', vi.fn(async (input: string, init?: RequestInit) => {
    if (input.endsWith('/api/services')) return Response.json(catalog)
    if (input.includes('/api/availability?')) return Response.json({ available_times: ['09:00'] })
    if (input.endsWith('/api/appointments') && init?.method === 'POST') {
      return Response.json({ errors }, { status: 422 })
    }
    throw new Error(`Unexpected test request: ${input}`)
  }))
  mount()
  const date = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10)
  fireEvent.change(await screen.findByLabelText('Choose a Date'), { target: { value: date } })
  fireEvent.click(await screen.findByRole('button', { name: '9:00 AM' }))
  for (const [label, value] of Object.entries(customer)) {
    fireEvent.change(screen.getByLabelText(label, { exact: true }), { target: { value } })
  }
  const submit = screen.getByRole('button', { name: 'Book Appointment' })
  await waitFor(() => expect(submit).toHaveProperty('disabled', false))
  fireEvent.click(submit)
  return screen.findByRole('alert')
}

describe('backend field-error presentation', () => {
  test.each([
    ['customer_first_name', 'First name', 'should be at most 100 character(s)'],
    ['customer_last_name', 'Last name', 'should be at most 100 character(s)'],
    ['customer_email', 'Email', 'has invalid format'],
    ['customer_phone', 'Phone', "can't be blank"],
    ['vehicle_make', 'Vehicle make', 'should be at most 255 character(s)'],
    ['vehicle_model', 'Vehicle model', 'should be at most 255 character(s)'],
    ['notes', 'Notes', 'is invalid'],
    ['service_price_id', 'Selected service', 'does not exist'],
    ['starts_at', 'Appointment time', 'is invalid'],
    ['future_field', 'future field', 'is invalid'],
  ])('%s has a readable label and preserves the form', async (field, label, message) => {
    const alert = await submitRejectedBooking({ [field]: [message] })
    expect(alert.textContent).toContain(`${label}: ${message}`)
    for (const [name, value] of Object.entries(customer)) {
      expect(screen.getByLabelText(name, { exact: true })).toHaveProperty('value', value)
    }
  })

  test('multiple field errors are presented together', async () => {
    const alert = await submitRejectedBooking({ customer_first_name: ["can't be blank"], vehicle_model: ['is invalid'] })
    expect(alert.textContent).toBe("First name: can't be blank. Vehicle model: is invalid")
  })

  test.each([null, {}, { email: 'unexpected string' }, { email: [null, 42] }])(
    'unexpected error bodies safely fall back (%j)', async (errors) => {
      expect((await submitRejectedBooking(errors)).textContent).toBe('Could not book appointment')
    },
  )
})
