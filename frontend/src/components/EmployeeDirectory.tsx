import { useCallback, useEffect, useRef, useState } from 'react'
type Shop = { id: number; name: string; status: string; starts_on: string; ends_on: string | null }
type Employee = { employee_id: number; period_id: number; first_name: string; last_name: string; classification: string; status: string; starts_on: string; ends_on: string | null; phone?: string | null; email?: string | null; home_address?: string | null; shops?: Shop[] }
type Page = { employees: Employee[]; meta: { has_more: boolean; next_cursor: string | null } }
const roles = ['detailer', 'shop_manager', 'business_manager', 'business_owner']
const unavailable = 'Employee information is temporarily unavailable.'
const safeError = (e: unknown) => e instanceof Error && ['Your session has expired. Sign in again.', 'HR access is no longer available.'].includes(e.message) ? e.message : unavailable
const label = (value: string) => value.replaceAll('_', ' ')
async function get<T>(url: string, signal: AbortSignal): Promise<T> {
  const response = await fetch(url, { signal, cache: 'no-store' })
  if (!response.ok) throw new Error(response.status === 401 ? 'Your session has expired. Sign in again.' : response.status === 403 ? 'HR access is no longer available.' : 'Employee information is temporarily unavailable.')
  return response.json() as Promise<T>
}
function validEmployee(e: Employee) {
  return e && Number.isSafeInteger(e.employee_id) && Number.isSafeInteger(e.period_id) && typeof e.first_name === 'string' && typeof e.last_name === 'string' && roles.includes(e.classification) && ['active', 'ended'].includes(e.status) && typeof e.starts_on === 'string' && (e.ends_on === null || typeof e.ends_on === 'string') && [e.phone, e.email, e.home_address].every(v => v === undefined || v === null || typeof v === 'string') && (e.shops === undefined || (Array.isArray(e.shops) && e.shops.every(s => s && Number.isSafeInteger(s.id) && typeof s.name === 'string' && ['active', 'ended'].includes(s.status) && typeof s.starts_on === 'string' && (s.ends_on === null || typeof s.ends_on === 'string'))))
}
function validPage(value: Page) {
  return value && Array.isArray(value.employees) && value.employees.every(validEmployee) && value.meta && typeof value.meta.has_more === 'boolean' && (value.meta.next_cursor === null || typeof value.meta.next_cursor === 'string')
}
export default function EmployeeDirectory({ businessId, shopId, hr }: { businessId: number; shopId: number; hr: boolean }) {
  const [status, setStatus] = useState('active')
  const [q, setQ] = useState('')
  const [classification, setClassification] = useState('')
  const [search, setSearch] = useState('')
  const [cursor, setCursor] = useState('')
  const [page, setPage] = useState<Page | null>(null)
  const [error, setError] = useState('')
  const [revision, setRevision] = useState(0)
  const trigger = useRef<HTMLButtonElement | null>(null)
  const [employee, setEmployee] = useState<number | null>(null)
  const denied = useCallback((message: string) => { setEmployee(null); setPage(null); setError(message) }, [])
  const base = `/api/admin/businesses/${businessId}`
  useEffect(() => {
    const controller = new AbortController()
    async function load() {
      setPage(null); setError('')
      try {
        const params = new URLSearchParams({ limit: '20', ...(hr ? { status } : {}), ...(search ? { q: search } : {}), ...(classification ? { classification } : {}), ...(cursor ? { cursor } : {}) })
        const data = await get<Page>(`${base}${hr ? '' : `/shops/${shopId}`}/employees?${params}`, controller.signal)
        if (!validPage(data)) throw new Error('Employee information is temporarily unavailable.')
        if (!controller.signal.aborted) setPage(data)
      } catch (e) { if (!controller.signal.aborted) setError(safeError(e)) }
    }
    void load()
    return () => controller.abort()
  }, [base, shopId, hr, status, search, classification, cursor, revision])
  function reset() { setCursor(''); setEmployee(null); setPage(null) }
  return <section aria-label={hr ? 'Employee directory' : 'Current shop roster'} className="employee-directory">
    <p>{hr ? 'Business HR directory · retained employment history' : 'Current assigned-shop contacts only. HR history is restricted.'}</p>
    {hr && <div role="group" aria-label="Employment view">{[['active', 'Active Employees'], ['former', 'Former Employees']].map(([key, name]) => <button className="secondary-button" key={key} aria-pressed={status === key} onClick={() => { reset(); setStatus(key); setRevision(v => v + 1) }}>{name}</button>)}</div>}
    <form className="employee-filters" onSubmit={e => { e.preventDefault(); reset(); setSearch(q.trim()); setRevision(v => v + 1) }}>
      <label>Search employee names<input value={q} maxLength={100} onChange={e => setQ(e.target.value)} /></label>
      <label>Classification<select value={classification} onChange={e => { reset(); setClassification(e.target.value) }}><option value="">All classifications</option>{roles.map(r => <option key={r} value={r}>{label(r)}</option>)}</select></label>
      <button className="secondary-button" type="submit">Search</button>
    </form>
    <button className="secondary-button" onClick={() => { reset(); setRevision(v => v + 1) }}>Refresh employees</button>
    {error ? <p role="alert">{error}</p> : !page ? <p role="status">Loading employees…</p> : <>
      {!page.employees.length ? <p>No employees match this view.</p> : <ul className="employee-cards">{page.employees.map(e => <li key={e.employee_id}>
        <h3>{e.first_name} {e.last_name}</h3><p className="employee-classification">{label(e.classification)} · {e.status === 'ended' ? 'Former employee' : 'Active employment'}</p>
        <Contact employee={e} />
        {hr && <button className="secondary-button" onClick={event => { trigger.current = event.currentTarget; setEmployee(e.employee_id) }}>View profile and history for {e.first_name} {e.last_name}</button>}
      </li>)}</ul>}
      <nav aria-label="Employee pagination"><button className="secondary-button" disabled={!cursor} onClick={() => { reset(); setCursor('') }}>First page</button><button className="secondary-button" disabled={!page.meta.has_more || !page.meta.next_cursor} onClick={() => { setPage(null); setEmployee(null); setCursor(page.meta.next_cursor ?? '') }}>Next page</button></nav>
    </>}
    {employee !== null && hr && !error && <EmployeeProfile key={employee} base={base} employeeId={employee} onDenied={denied} close={() => { setEmployee(null); trigger.current?.focus() }} />}
  </section>
}
function Contact({ employee: e }: { employee: Employee }) {
  return <><dl className="employee-contact"><dt>Phone</dt><dd>{e.phone || 'Not provided'}</dd><dt>Email</dt><dd>{e.email || 'Not provided'}</dd><dt>Home address</dt><dd>{e.home_address || 'Not provided'}</dd><dt>Employment period</dt><dd>{e.starts_on} – {e.ends_on || 'Present'}</dd></dl>
    <p>Shop assignments: {e.shops?.length ? e.shops.map(s => `${s.name} (${s.status}, ${s.starts_on} – ${s.ends_on || 'Present'})`).join('; ') : 'None recorded'}</p></>
}
function EmployeeProfile({ base, employeeId, close, onDenied }: { base: string; employeeId: number; close: () => void; onDenied: (message: string) => void }) {
  const panel = useRef<HTMLElement | null>(null)
  const [profile, setProfile] = useState<Employee | null>(null)
  const [timeline, setTimeline] = useState<Page | null>(null)
  const [cursor, setCursor] = useState('')
  const [period, setPeriod] = useState<number | null>(null)
  useEffect(() => { panel.current?.focus() }, [period, cursor])
  const [error, setError] = useState('')
  useEffect(() => {
    const controller = new AbortController()
    async function load() {
      setProfile(null); setTimeline(null); setError('')
      try {
        const path = `${base}/employees/${employeeId}`
        const [p, t] = await Promise.all([get<{ employee: Employee }>(period ? `${path}/periods/${period}` : path, controller.signal), get<Page>(`${path}/periods?limit=20${cursor ? `&cursor=${encodeURIComponent(cursor)}` : ''}`, controller.signal)])
        if (!validEmployee(p.employee) || p.employee.employee_id !== employeeId || (period !== null && p.employee.period_id !== period) || !validPage(t) || t.employees.some(e => e.employee_id !== employeeId)) throw new Error('Employee information is temporarily unavailable.')
        if (!controller.signal.aborted) { setProfile(p.employee); setTimeline(t) }
      } catch (e) {
        if (!controller.signal.aborted) {
          const message = safeError(e)
          if (message !== unavailable) onDenied(message)
          else setError(message)
        }
      }
    }
    void load()
    return () => controller.abort()
  }, [base, employeeId, period, cursor, onDenied])
  return <section ref={panel} tabIndex={-1} aria-label="Employee profile and employment history" className="employee-profile">
    <button className="secondary-button" onClick={close}>Close profile</button>
    {error ? <p role="alert">{error}</p> : !profile || !timeline ? <p role="status">Loading profile and history…</p> : <>
      <h3>{profile.first_name} {profile.last_name}</h3><p>Stable employee #{employeeId} · Period #{profile.period_id} · {profile.status === 'ended' ? 'Historical / former period' : 'Active period'}</p>
      <Contact employee={profile} />
      <h4>Employment timeline</h4><ol>{timeline.employees.map(e => <li key={e.period_id}>
        <p>Period #{e.period_id}: {e.starts_on} – {e.ends_on || 'Present'} · {label(e.classification)} · {e.period_id === e.employee_id ? 'Original employment' : 'Rehire period'} · {e.status === 'ended' ? 'Termination recorded' : 'Active status (see effective dates)'}</p>
        <button className="secondary-button" onClick={() => setPeriod(e.period_id)}>View period {e.period_id}</button>
      </li>)}</ol>
      <button className="secondary-button" disabled={!cursor} onClick={() => setCursor('')}>First timeline page</button>
      <button className="secondary-button" disabled={!timeline.meta.has_more || !timeline.meta.next_cursor} onClick={() => setCursor(timeline.meta.next_cursor ?? '')}>Next timeline page</button>
    </>}
  </section>
}
