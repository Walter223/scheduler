import { useEffect, useRef, useState } from 'react'
type Member = { id: number; first_name: string; last_name: string; is_lead: boolean }
type Candidate = { assignment_id: number; employee_id: number; period_id: number; first_name: string; last_name: string }
type Page<T> = { has_more: boolean; next_cursor: string | null } & T
const errors: Record<string, string> = {
  missing_covering_shift: 'A single active shift must cover the appointment and its 30-minute buffer.',
  overlap: 'This Detailer already has overlapping assigned work.',
  ineligible_assignment: 'The shop assignment is no longer eligible.',
  ineligible_detailer: 'This employee is no longer an active eligible Detailer.',
  invalid_appointment: 'This appointment cannot receive crew changes in its current state.',
  already_assigned: 'This Detailer is already assigned. The team has been refreshed.',
}
function failure(status: number, code: string) {
  if (status === 401) return 'Your session has expired. Sign in again.'
  if (status === 403) return 'Crew access is no longer available. Refresh access.'
  if (status === 409) return errors[code] ?? 'The team changed or this action is no longer applicable. Review the refreshed team.'
  if (status === 422) return 'The submitted crew change is invalid.'
  return 'The crew change could not be confirmed. Refresh before retrying.'
}
export default function AppointmentCrew({ businessId, shopId, appointmentId, editable, onChanged, onDenied }: {
  businessId: number; shopId: number; appointmentId: number; editable: boolean; onChanged: () => void; onDenied: (message: string) => void
}) {
  const [members, setMembers] = useState<Member[] | null>(null)
  const [candidates, setCandidates] = useState<Candidate[]>([])
  const [cursor, setCursor] = useState('')
  const [next, setNext] = useState<string | null>(null)
  const [choice, setChoice] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [revision, setRevision] = useState(0)
  const [message, setMessage] = useState('')
  const locked = useRef(false)
  const alive = useRef<AbortController>(new AbortController())
  const base = `/api/admin/businesses/${businessId}/shops/${shopId}/appointments/${appointmentId}/team`
  useEffect(() => {
    const abort = new AbortController(); alive.current = abort
    return () => abort.abort()
  }, [base])
  useEffect(() => {
    const abort = new AbortController()
    async function get<T>(url: string): Promise<T> {
      const response = await fetch(url, { cache: 'no-store', signal: abort.signal })
      if (!response.ok) {
        if ([401, 403].includes(response.status) && !abort.signal.aborted) onDenied(failure(response.status, ''))
        throw new Error('Crew information is temporarily unavailable.')
      }
      return (await response.json() as { data: T }).data
    }
    async function load() {
      setMembers(null); setCandidates([]); setChoice(''); setNext(null)
      try {
        const all: Member[] = []
        let position: string | null = null
        do {
          const page: Page<{ assignments: Member[] }> = await get(`${base}?limit=100${position ? `&cursor=${encodeURIComponent(position)}` : ''}`)
          if (!Array.isArray(page.assignments) || page.assignments.some(m => !Number.isSafeInteger(m.id) || typeof m.first_name !== 'string' || typeof m.last_name !== 'string' || typeof m.is_lead !== 'boolean') || (page.has_more && (!page.next_cursor || page.next_cursor === position))) throw new Error('invalid team')
          all.push(...page.assignments)
          position = page.has_more ? page.next_cursor : null
        } while (position && !abort.signal.aborted)
        const page = editable ? await get<Page<{ candidates: Candidate[] }>>(`${base}/candidates?limit=50${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`) : null
        if (page && (!Array.isArray(page.candidates) || page.candidates.some(c => ![c.assignment_id,c.employee_id,c.period_id].every(Number.isSafeInteger) || typeof c.first_name !== 'string' || typeof c.last_name !== 'string') || typeof page.has_more !== 'boolean' || !(page.next_cursor === null || typeof page.next_cursor === 'string'))) throw new Error('invalid candidates')
        if (!abort.signal.aborted) { setMembers(all); setCandidates(page?.candidates ?? []); setNext(page?.has_more ? page.next_cursor : null) }
      } catch { if (!abort.signal.aborted) { setMembers(null); setCandidates([]); setError('Crew information is temporarily unavailable.') } }
    }
    void load()
    return () => abort.abort()
  }, [base, cursor, editable, revision, onDenied])
  async function mutate(path: string, body: object = {}) {
    if (locked.current) return
    locked.current = true; setBusy(true); setError(''); setMessage('')
    const signal = alive.current.signal
    try {
      const me = await fetch('/api/me', { signal, cache: 'no-store' })
      const session = await me.json() as { authenticated?: boolean; csrf_token?: string }
      if (signal.aborted) return
      if (!me.ok || !session.authenticated || typeof session.csrf_token !== 'string') { onDenied(failure(401, '')); return }
      const response = await fetch(`${base}${path}`, { method: 'POST', signal, headers: { 'content-type': 'application/json', 'x-csrf-token': session.csrf_token }, body: JSON.stringify(body) })
      if (signal.aborted) return
      const value = await response.json() as { error?: string }
      if (signal.aborted) return
      if ([401,403].includes(response.status)) { setMembers(null); setCandidates([]); onDenied(failure(response.status, '')); return }
      if (!response.ok) setError(failure(response.status, value.error ?? ''))
      else setMessage('Crew updated.')
      setCursor(''); setRevision(v => v + 1); onChanged()
    } catch { if (!signal.aborted) { setMembers(null); setCandidates([]); setError(failure(503, '')) } }
    finally { locked.current = false; if (!signal.aborted) setBusy(false) }
  }
  return <section aria-label="Appointment crew" className="appointment-crew" aria-busy={busy}>
    <div className="calendar-section-header"><h4>Appointment crew</h4><button className="secondary-button" disabled={busy} onClick={() => { setError(''); setRevision(v => v + 1); onChanged() }}>Refresh crew</button></div>
    {error && <p role="alert">{error}</p>}{message && <p role="status">{message}</p>}
    {!members ? <p role="status">{error ? 'Refresh to review current crew.' : 'Loading crew…'}</p> : <>
      {!members.length ? <p>No Detailers assigned.</p> : <ul aria-label="Assigned Detailers" className="crew-roster">{members.map(m => <li key={m.id}>
        <span>{m.first_name} {m.last_name}{m.is_lead ? ' · Lead' : ''}</span>
        {editable && <div className="crew-member-actions"><button className="secondary-button" disabled={busy || m.is_lead} onClick={() => void mutate(`/${m.id}/lead`)} aria-label={`Make ${m.first_name} ${m.last_name} lead`}>Set Lead</button><button className="secondary-button" disabled={busy} onClick={() => void mutate(`/${m.id}/remove`)} aria-label={`Remove ${m.first_name} ${m.last_name}`}>Remove</button></div>}
      </li>)}</ul>}
      {editable && <div className="crew-controls"><button className="secondary-button" disabled={busy || !members.some(m => m.is_lead)} onClick={() => void mutate('/clear-lead')}>Clear Lead Detailer</button>
        <form onSubmit={e => { e.preventDefault(); const c = candidates.find(c => String(c.assignment_id) === choice); if (c) void mutate('', { employee_id: c.employee_id, period_id: c.period_id, assignment_id: c.assignment_id }) }}>
          <label>Eligible Detailer<select disabled={busy} value={choice} onChange={e => setChoice(e.target.value)}><option value="">Choose a Detailer</option>{candidates.map(c => <option key={c.assignment_id} value={c.assignment_id}>{c.first_name} {c.last_name}</option>)}</select></label>
          <button className="secondary-button" disabled={busy || !choice}>Add Detailer</button>
        </form>
        {!candidates.length && <p>No eligible Detailers on this page. A covering shift including the buffer and no overlapping job are required.</p>}
        <nav aria-label="Eligible Detailer pages"><button className="secondary-button" disabled={busy || !cursor} onClick={() => { setCursor(''); setError('') }}>First candidates</button><button className="secondary-button" disabled={busy || !next} onClick={() => { setCursor(next ?? ''); setError('') }}>Next candidates</button></nav>
      </div>}
    </>}
    <p className="crew-policy-note">Removing the Lead leaves the role vacant; no other team member is automatically promoted.</p>
  </section>
}
