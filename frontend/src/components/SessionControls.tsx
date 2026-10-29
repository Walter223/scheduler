import { useEffect, useState } from 'react'
import Button from './Button'

type Session = {
  authenticated: boolean
  user: { id: number; email: string; first_name: string | null; last_name: string | null } | null
  csrf_token: string | null
}

const anonymous: Session = { authenticated: false, user: null, csrf_token: null }
const errors: Record<string, string> = {
  account_unavailable: 'Your Magnum account is not available for sign-in. Contact your administrator.',
  provider_unavailable: 'Sign-in is temporarily unavailable. Please try again.',
  login_failed: 'Sign-in could not be completed. Please start a new login.',
}

function SessionControls() {
  const [session, setSession] = useState<Session>(anonymous)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState(() =>
    errors[new URLSearchParams(window.location.search).get('auth_error') ?? ''] ?? '')

  useEffect(() => {
    const controller = new AbortController()
    fetch('/api/me', { signal: controller.signal, cache: 'no-store' })
      .then(async (response) => {
        if (!response.ok) throw new Error('session unavailable')
        const data: unknown = await response.json()
        if (typeof data !== 'object' || data === null || !('authenticated' in data)) {
          throw new Error('invalid session')
        }
        const value = data as Session
        if (value.authenticated === false) setSession(anonymous)
        else if (value.authenticated === true && value.user && typeof value.user.email === 'string'
          && typeof value.csrf_token === 'string') setSession(value)
        else throw new Error('invalid session')
      })
      .catch(() => {
        if (!controller.signal.aborted) setMessage('Account status is unavailable. Booking is still available.')
      })
    return () => controller.abort()
  }, [])

  async function logout() {
    if (!session.csrf_token || busy) return
    setBusy(true)
    try {
      const response = await fetch('/auth/logout', {
        method: 'POST', headers: { 'x-csrf-token': session.csrf_token },
      })
      if (!response.ok && response.status !== 401) throw new Error('logout failed')
      setSession(anonymous)
      setMessage('Signed out of Magnum. Your identity-provider session may still be active.')
    } catch {
      setMessage('Sign-out could not be completed. Please try again.')
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="session-controls" aria-label="Account">
      {session.authenticated && session.user && <>
        <span>Signed in as {session.user.first_name || session.user.email}</span>
        <Button variant="confirmation" onClick={logout} disabled={busy}>Sign out</Button>
      </>}
      {message && <p role="status">{message}</p>}
    </section>
  )
}

export default SessionControls
