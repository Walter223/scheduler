import useModalDialog from '../hooks/useModalDialog'
import EmployeeHRForm from './EmployeeHRForm'
import type { HRAction, HRShop } from './EmployeeHRForm'
import { useCallback, useEffect, useRef, useState } from 'react'
type Shop = { assignment_id?: number; id: number; name: string; status: string; starts_on: string; ends_on: string | null }
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
export default function EmployeeDirectory({ businessId, shopId, hr, canManage = false, shops = [] }: { businessId: number; shopId: number; hr: boolean; canManage?: boolean; shops?: HRShop[] }) {
  const [creating, setCreating] = useState(false)
  const [message, setMessage] = useState('')
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
  const denied = useCallback((message: string) => { setEmployee(null); setCreating(false); setMessage(''); setPage(null); setError(message) }, [])
  const changed = useCallback((action?: HRAction) => {
    if (action === 'terminate' || action === 'rehire') { setStatus(action === 'terminate' ? 'former' : 'active'); setCursor(''); setSearch(''); setQ(''); setClassification('') }
    setRevision(v => v + 1)
  }, [])
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
    <div className="hr-directory-toolbar"><p>{hr ? 'Business HR directory · retained employment history' : 'Current assigned-shop contacts only. HR history is restricted.'}</p><div className="hr-directory-actions">
    {canManage && hr && !error && <button className="secondary-button" onClick={() => setCreating(true)}>Create employee</button>}
    <button className="secondary-button" onClick={() => { reset(); setRevision(v => v + 1) }}>Refresh employees</button></div></div>
    {message && <p role="status">{message}</p>}
    {hr && <div role="group" aria-label="Employment view">{[['active', 'Active Employees'], ['former', 'Former Employees']].map(([key, name]) => <button className="secondary-button" key={key} aria-pressed={status === key} onClick={() => { reset(); setStatus(key); setRevision(v => v + 1) }}>{name}</button>)}</div>}
    <form className="employee-filters" onSubmit={e => { e.preventDefault(); reset(); setSearch(q.trim()); setRevision(v => v + 1) }}>
      <label>Search employee names<input value={q} maxLength={100} onChange={e => setQ(e.target.value)} /></label>
      <label>Classification<select value={classification} onChange={e => { reset(); setClassification(e.target.value) }}><option value="">All classifications</option>{roles.map(r => <option key={r} value={r}>{label(r)}</option>)}</select></label>
      <button className="secondary-button" type="submit">Search</button>
    </form>
    {error ? <p role="alert">{error}</p> : !page ? <p role="status">Loading employees…</p> : <>
      {!page.employees.length ? <p>No employees match this view.</p> : <table className="employee-table" aria-label="Employees" role="table">
        <thead role="rowgroup"><tr role="row"><th scope="col">Employee</th><th scope="col">Classification</th><th scope="col">Status</th><th scope="col">Shops</th><th scope="col"><span className="hr-sr-only">Profile</span></th></tr></thead>
        <tbody role="rowgroup">{page.employees.map(e => <tr key={e.employee_id} role="row">
          <th scope="row" role="rowheader"><h3>{e.first_name} {e.last_name}</h3></th>
          <td role="cell" data-label="Classification"><span className="employee-classification">{label(e.classification)}</span></td>
          <td role="cell" data-label="Status"><span className={e.status === 'ended' ? 'employment-badge is-former' : 'employment-badge'}>{e.status === 'ended' ? 'Former employee' : 'Active employment'}</span></td>
          <td role="cell" data-label="Shops">{e.shops?.length ? Array.from(new Set(e.shops.map(s => s.name))).join(', ') : 'No shops recorded'}</td>
          <td role="cell"><button className="secondary-button admin-button--sm" aria-label={hr ? `View profile and history for ${e.first_name} ${e.last_name}` : `View contact details for ${e.first_name} ${e.last_name}`} onClick={event => { trigger.current = event.currentTarget; setEmployee(e.employee_id) }}>{hr ? 'View profile' : 'View contact'}</button></td>
        </tr>)}</tbody>
      </table>}
      <nav aria-label="Employee pagination"><button className="secondary-button" disabled={!cursor} onClick={() => { reset(); setCursor('') }}>First page</button><button className="secondary-button" disabled={!page.meta.has_more || !page.meta.next_cursor} onClick={() => { setPage(null); setEmployee(null); setCursor(page.meta.next_cursor ?? '') }}>Next page</button></nav>
    </>}
    {employee !== null && hr && !error && <EmployeeProfile key={employee} base={base} employeeId={employee} businessId={businessId} canManage={canManage} shops={shops} onChanged={changed} onDenied={denied} close={() => { setEmployee(null); trigger.current?.focus({ preventScroll: true }) }} />}
    {employee !== null && !hr && page && !error && page.employees.find(e => e.employee_id === employee) && <RosterContact employee={page.employees.find(e => e.employee_id === employee)!} close={() => setEmployee(null)} />}
    {creating && canManage && hr && !error && <EmployeeHRForm action="create" businessId={businessId} shops={shops} onClose={() => setCreating(false)} onDenied={denied} onSaved={text => { setCreating(false); reset(); setStatus('active'); setSearch(''); setQ(''); setClassification(''); setMessage(text); changed() }} />}
  </section>
}
function Contact({ employee: e }: { employee: Employee }) {
  return <section className="hr-profile-section" aria-label="Contact information"><h4>Contact information</h4><dl className="employee-contact"><dt>Phone</dt><dd>{e.phone || 'Not provided'}</dd><dt>Email</dt><dd>{e.email || 'Not provided'}</dd><dt>Home address</dt><dd>{e.home_address || 'Not provided'}</dd></dl></section>
}
function Assignments({ employee: e, end }: { employee: Employee; end?: (shop: Shop) => void }) {
  return <section className="hr-profile-section" aria-label="Shop assignments"><h4>Shop assignments</h4>{!e.shops?.length ? <p>Shop assignments: None recorded</p> : <ul className="hr-assignment-list">{e.shops.map((s,i) => <li key={s.assignment_id ?? `${s.id}:${i}`}><strong>{s.name}</strong><span>{s.status} · {s.starts_on} – {s.ends_on || 'Present'}</span>{end && s.status === 'active' && Number.isSafeInteger(s.assignment_id) && <button className="secondary-button admin-button--sm" aria-label={`End assignment to ${s.name}`} onClick={() => end(s)}>End assignment</button>}</li>)}</ul>}</section>
}
function RosterContact({ employee, close }: { employee: Employee; close: () => void }) {
  const dialog = useModalDialog()
  return <dialog ref={dialog} className="employee-drawer" aria-label="Current shop contact details" onCancel={e => { e.preventDefault(); close() }}><header className="hr-drawer-header"><h3>{employee.first_name} {employee.last_name}</h3><button className="secondary-button" onClick={close}>Close contact</button></header><p className="employee-classification">{label(employee.classification)} · Current assigned-shop contact</p><Contact employee={employee} /><Assignments employee={employee} /></dialog>
}
function EmployeeProfile({ base, employeeId, close, onDenied, businessId, canManage, shops, onChanged }: { base: string; employeeId: number; close: () => void; onDenied: (message: string) => void; businessId: number; canManage: boolean; shops: HRShop[]; onChanged: (action?: HRAction) => void }) {
  const [editing, setEditing] = useState<{ action: HRAction; assignmentId?: number; assignmentName?: string } | null>(null)
  const [revision, setRevision] = useState(0)
  const [message, setMessage] = useState('')
  const dialog = useModalDialog()
  const panel = useRef<HTMLElement | null>(null)
  const [profile, setProfile] = useState<Employee | null>(null)
  const [timeline, setTimeline] = useState<Page | null>(null)
  const [cursor, setCursor] = useState('')
  const [period, setPeriod] = useState<number | null>(null)
  useEffect(() => { panel.current?.focus() }, [period, cursor, revision])
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
  }, [base, employeeId, period, cursor, onDenied, revision])
  return <dialog ref={dialog} className="employee-drawer" aria-label="Employee details" onCancel={e => { if (e.target !== e.currentTarget) return; e.preventDefault(); if (!editing) close() }}><section ref={panel} tabIndex={-1} aria-label="Employee profile and employment history" className="employee-profile">
    <header className="hr-drawer-header"><span>Employee profile</span><button className="secondary-button" disabled={!!editing} onClick={close}>Close profile</button></header>
    {message && <p role="status">{message}</p>}
    {error ? <p role="alert">{error}</p> : !profile || !timeline ? <p role="status">Loading profile and history…</p> : <>
      <h3>{profile.first_name} {profile.last_name}</h3><p className="employee-classification">{label(profile.classification)} · {profile.status === 'ended' ? 'Former employee' : 'Active employment'}</p><p>Stable employee #{employeeId} · Period #{profile.period_id} · {profile.status === 'ended' ? 'Historical / former period' : 'Active period'}</p>
      <p className="hr-period-dates">Employment period: {profile.starts_on} – {profile.ends_on || 'Present'}</p>
      {period !== null && <p className="hr-history-notice">Read-only employment period. <button className="secondary-button admin-button--sm" onClick={() => setPeriod(null)}>Return to current profile</button></p>}
      <Contact employee={profile} />
      <Assignments employee={profile} end={canManage && period === null && profile.status === 'active' ? s => setEditing({ action: 'end', assignmentId: s.assignment_id, assignmentName: s.name }) : undefined} />
      <section className="hr-profile-section" aria-label="Employment history"><h4>Employment timeline</h4><ol className="hr-timeline">{timeline.employees.map(e => <li key={e.period_id}>
        <p>Period #{e.period_id}: {e.starts_on} – {e.ends_on || 'Present'} · {label(e.classification)} · {e.period_id === e.employee_id ? 'Original employment' : 'Rehire period'} · {e.status === 'ended' ? 'Termination recorded' : 'Active status (see effective dates)'}</p>
        <button className="secondary-button" onClick={() => setPeriod(e.period_id)}>View period {e.period_id}</button>
      </li>)}</ol>
      <button className="secondary-button" disabled={!cursor} onClick={() => setCursor('')}>First timeline page</button>
      <button className="secondary-button" disabled={!timeline.meta.has_more || !timeline.meta.next_cursor} onClick={() => setCursor(timeline.meta.next_cursor ?? '')}>Next timeline page</button>
    </section>
      {canManage && period === null && profile.status === 'active' && <section className="hr-profile-section" aria-label="Management actions"><h4>Management actions</h4><div className="hr-management-actions" role="group" aria-label="HR actions">
        <button className="secondary-button" onClick={() => setEditing({ action: 'contact' })}>Edit contact</button>
        <button className="secondary-button" onClick={() => setEditing({ action: 'classification' })}>Change classification</button>
        <button className="secondary-button" onClick={() => setEditing({ action: 'assign' })}>Assign shops</button>
        <div className="hr-danger-zone"><p>Termination retains history and offboards this business only.</p><button className="secondary-button admin-button--danger" onClick={() => setEditing({ action: 'terminate' })}>Terminate employee</button></div>
      </div></section>}
      {canManage && period === null && profile.status === 'ended' && <section className="hr-profile-section" aria-label="Management actions"><h4>Management actions</h4><button className="secondary-button" onClick={() => setEditing({ action: 'rehire' })}>Rehire employee</button></section>}
      {editing && canManage && period === null && ((profile.status === 'active' && editing.action !== 'rehire') || (profile.status === 'ended' && editing.action === 'rehire')) && <EmployeeHRForm key={editing.action + String(editing.assignmentId)} action={editing.action} businessId={businessId} employee={profile} shops={shops.filter(s => !profile.shops?.some(a => a.id === s.id && a.status === 'active'))} assignmentId={editing.assignmentId} assignmentName={editing.assignmentName} onClose={() => setEditing(null)} onDenied={onDenied} onSaved={text => { setEditing(null); setMessage(editing.action === 'rehire' ? 'A new employment period was created. No account access, grants, pay or work was restored. A future period appears in Active Employees only when its start date arrives.' : text); setRevision(v => v + 1); onChanged(editing.action) }} />}
    </>}
  </section></dialog>
}
