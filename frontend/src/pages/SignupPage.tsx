import { useEffect, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import './signup.css'
import FieldHelp from '../components/FieldHelp'
import TimezonePicker from '../components/TimezonePicker'

type Details = { business: { name: string; slug: string }; shop: { name: string; slug: string; timezone: string } }
const empty: Details = { business: { name: '', slug: '' }, shop: { name: '', slug: 'main', timezone: Intl.DateTimeFormat().resolvedOptions().timeZone || 'Etc/UTC' } }
function identifier(name:string){return name.normalize('NFKD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'').slice(0,255).replace(/-$/,'')}
const messages: Record<number, string> = {
  403: 'Verification expired or could not be confirmed. Start verification again.',
  409: 'That booking website address is unavailable, or this request has already changed. Choose a different address identifier or restart verification.',
  422: 'Check the names, lowercase hyphenated address identifiers and shop timezone, then try again.',
  429: 'Too many attempts. Please wait before trying again. New business creation is limited to one per day.',
  503: 'Signup is temporarily unavailable. Please try again later.',
}
export default function SignupPage() {
  const [phase, setPhase] = useState<'loading' | 'verify' | 'form' | 'review' | 'uncertain' | 'success'>('loading')
  const [details, setDetails] = useState<Details>(empty)
  const [created, setCreated] = useState<{business_id:number;shop_id:number;business_name:string}|null>(null)
  const [csrf, setCSRF] = useState('')
  const [message, setMessage] = useState('')
  const [busy, setBusy] = useState(false)
  const businessEdited = useRef(false), shopEdited = useRef(false)
  const pending = useRef(false)
  const alive = useRef(true)
  useEffect(() => {
    alive.current = true
    const controller = new AbortController()
    const failed = new URLSearchParams(window.location.search).has('auth_error')
    const url = new URL(window.location.href)
    url.searchParams.delete('auth_error')
    window.history.replaceState(window.history.state, '', url.pathname + url.search + url.hash)
    fetch('/auth/signup', { cache: 'no-store', signal: controller.signal }).then(async response => {
      if (response.status === 403) {
        if (!controller.signal.aborted) {
          setPhase('verify')
          setMessage(failed ? 'Verification was canceled or could not be completed. Please try again.' : 'Business-creation verification is missing, expired or could not be confirmed. Your ordinary Magnum sign-in is separate. Choose Continue to verification to restart signup and return here. Nothing is created until you review and confirm.')
        }
        return
      }
      if (!response.ok) throw new Error('proof unavailable')
      const body = await response.json()
      if (body.completed === true && Number.isInteger(body.data?.business_id) && Number.isInteger(body.data?.shop_id) && typeof body.data?.business_name === 'string') { if(!controller.signal.aborted){setCreated(body.data);setPhase('success')}return }
      if (typeof body.csrf_token !== 'string') throw new Error('invalid proof')
      if (!controller.signal.aborted) { setCSRF(body.csrf_token); setPhase('form') }
    }).catch(() => {
      if (!controller.signal.aborted) {
        setPhase('verify')
        setMessage(failed ? 'Verification was canceled or could not be completed. Please try again.' : 'Signup verification could not be checked. Check your connection and try Continue to verification again.')
      }
    })
    return () => { alive.current = false; controller.abort() }
  }, [])

  async function verify(register = false) {
    if (pending.current) return
    pending.current = true; setBusy(true); setMessage('')
    try {
      const response = await fetch('/auth/signup/login', { method: 'POST', headers: { 'Content-Type': 'application/json', Accept: 'application/json' }, body: JSON.stringify(register ? {mode:'register'} : {}) })
      if (!response.ok) { setMessage(messages[response.status] || 'Verification could not start. Please try again.'); return }
      const body = await response.json()
      const destination = new URL(body.redirect_to)
      if (!['http:', 'https:'].includes(destination.protocol)) throw new Error('invalid redirect')
      window.location.assign(destination.href)
    } catch { if (alive.current) setMessage('Verification could not start. Please try again.') }
    finally { pending.current = false; if (alive.current) setBusy(false) }
  }
  async function submit() {
    if (pending.current) return
    pending.current = true; setBusy(true); setMessage('')
    try {
      const response = await fetch('/auth/signup/business', { method: 'POST', headers: { 'Content-Type': 'application/json', 'x-csrf-token': csrf }, body: JSON.stringify(details), redirect: 'error' })
      if (!alive.current) return
      if (!response.ok) {
        setMessage(messages[response.status] || 'The request could not be completed. Please try again.')
        setPhase(response.status === 403 ? 'verify' : 'form')
        return
      }
      const body = await response.json()
      if (!Number.isInteger(body.data?.business_id) || !Number.isInteger(body.data?.shop_id) || typeof body.data?.business_name !== 'string') throw new Error('unconfirmed')
      setCreated(body.data); setCSRF(''); setPhase('success')
    } catch {
      if (alive.current) { setPhase('uncertain'); setMessage('We could not confirm the result. Retry the same request safely before starting another signup.') }
    } finally { pending.current = false; if (alive.current) setBusy(false) }
  }
  return <main className="signup-page"><section className="signup-panel" aria-labelledby="signup-title">
    <p className="signup-eyebrow">MAGNUM · FOR DETAILING BUSINESSES</p>
    <h1 id="signup-title">Create a business</h1>
    <p>Set up your company on the Magnum platform. Your business and customer booking stay independent.</p>
    {message && <p role="alert" className="signup-message">{message}</p>}
    {phase === 'loading' && <p role="status">Checking signup verification…</p>}
    {phase === 'verify' && <><h2>First, verify your identity</h2><p>Continue to Keycloak to sign in with a verified account. If you need an account, follow the registration options provided there. No business access is granted until setup succeeds.</p><button disabled={busy} onClick={()=>verify()}>{busy ? 'Connecting…' : 'Continue to verification'}</button><button disabled={busy} onClick={()=>verify(true)}>Create Account in Keycloak</button></>}
    {phase === 'form' && <form onSubmit={event => { event.preventDefault(); setMessage(''); setPhase('review') }}>
      <fieldset><legend>Your business</legend>
        <label>Business name<input required maxLength={255} value={details.business.name} onChange={e => setDetails({ ...details, business: { ...details.business, name: e.target.value, ...(!businessEdited.current?{slug:identifier(e.target.value)}:{}) } })} /></label>
        <div className="signup-field-heading"><label htmlFor="business-url">Booking website address</label><FieldHelp label="Booking website address">Choose a unique URL identifier for your business. Use lowercase letters, numbers and hyphens. This reserves an identifier; it does not publish a booking website or claim an existing company.</FieldHelp></div><input id="business-url" required maxLength={255} pattern="[a-z0-9]+(-[a-z0-9]+)*" aria-describedby="slug-help" value={details.business.slug} onChange={e => {businessEdited.current=true;setDetails({ ...details, business: { ...details.business, slug: e.target.value } })}} />
        <small id="slug-help">Unique lowercase letters and numbers, separated by hyphens. A matching name never claims an existing business.</small>
      </fieldset><fieldset><legend>First shop</legend>
        <label>Shop name<input required maxLength={255} value={details.shop.name} onChange={e => setDetails({ ...details, shop: { ...details.shop, name: e.target.value, ...(!shopEdited.current?{slug:identifier(e.target.value)}:{}) } })} /></label>
        <div className="signup-field-heading"><label htmlFor="shop-url">First-shop URL identifier</label><FieldHelp label="First-shop URL identifier">A short address identifier for this location within your company. Other locations can have different identifiers. This creates the first shop, not public booking availability.</FieldHelp></div><input id="shop-url" required maxLength={255} pattern="[a-z0-9]+(-[a-z0-9]+)*" value={details.shop.slug} onChange={e => {shopEdited.current=true;setDetails({ ...details, shop: { ...details.shop, slug: e.target.value } })}} />
        <TimezonePicker value={details.shop.timezone} onChange={timezone=>setDetails({...details,shop:{...details.shop,timezone}})} />
      </fieldset><button type="submit">Review business</button>
    </form>}
    {(phase === 'review' || phase === 'uncertain') && <><h2>Review your workspace</h2><dl><dt>Business</dt><dd>{details.business.name}</dd><dt>Booking website address</dt><dd>{details.business.slug}</dd><dt>First shop</dt><dd>{details.shop.name} · {details.shop.slug}</dd><dt>Timezone</dt><dd>{details.shop.timezone}</dd></dl><p>You will become this new business’s Owner. Your shop will not be published for public booking. No catalog or other business data is copied.</p><div className="signup-actions">{phase === 'review' && <button disabled={busy} onClick={() => setPhase('form')}>Edit details</button>}<button disabled={busy} onClick={submit}>{busy ? 'Creating…' : phase === 'uncertain' ? 'Retry same request' : 'Create business'}</button></div></>}
    {phase === 'success' && <div role="status"><h2>Your business is ready</h2><p><strong>{created?.business_name}</strong> has been created with its first shop and Owner membership.</p><p>Setup is confirmed. No new session was created. Sign in through the normal Magnum flow, then choose Resume Setup in your Owner workspace.</p><a href="/auth/login">Sign in to Magnum</a></div>}
    <footer><Link to="/admin">Sign in</Link><Link to="/platform">Back to Magnum platform</Link></footer>
  </section></main>
}
