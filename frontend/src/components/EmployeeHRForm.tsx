import { useEffect, useRef, useState } from 'react'
export type HRRecord = { employee_id: number; period_id: number; first_name: string; last_name: string; classification: string; ends_on?: string | null; phone?: string | null; email?: string | null; home_address?: string | null }
export type HRShop = { id: number; name: string }
export type HRAction = 'create' | 'contact' | 'classification' | 'assign' | 'end' | 'terminate' | 'rehire'
const classifications = ['detailer', 'shop_manager', 'business_manager', 'business_owner']
const names = { create: 'Create employee', contact: 'Edit employee contact', classification: 'Change classification', assign: 'Assign shops', end: 'End shop assignment', terminate: 'Terminate employee', rehire: 'Rehire employee' }
function nextDate(date?: string | null) {
  if (!date || !/^\d{4}-\d{2}-\d{2}$/.test(date)) return undefined
  const value = new Date(`${date}T00:00:00Z`)
  if (!Number.isFinite(value.getTime())) return undefined
  value.setUTCDate(value.getUTCDate() + 1)
  return value.toISOString().slice(0, 10)
}
function message(status: number, code: string) {
  if (status === 401) return 'Your session has expired. Sign in again.'
  if (status === 403) return 'This action is no longer authorized. Refresh access or sign in again.'
  if (status === 422) return 'Check the names, contact details and dates. The submitted information is invalid.'
  if (status === 409 && code === 'last_owner') return 'Ownership must be safely transferred before this employee can be terminated.'
  if (status === 409 && code === 'future_assignment_dates') return 'Future employment or shop-assignment dates prevent termination. An authorized administrator must review those relationships first.'
  if (status === 409 && ['offboarding_required', 'legacy_termination_requires_review'].includes(code)) return 'This employment record requires an authorized offboarding review before proceeding.'
  if (status === 409 && code === 'not_latest_ended_period') return 'This employment period is no longer the latest ended period. Refresh the employee record.'
  if (status === 409) return ['outstanding_work', 'work_in_progress'].includes(code) ? 'Outstanding shifts or assigned jobs prevent this change. Resolve that work first.' : 'The current employment or shop-assignment state prevents this change. Refresh the record before retrying.'
  return 'The save could not be confirmed. Refresh employee information before retrying.'
}
export default function EmployeeHRForm({ action, businessId, employee, shops, assignmentId, assignmentName, onClose, onSaved, onDenied }: {
  action: HRAction; businessId: number; employee?: HRRecord; shops: HRShop[]; assignmentId?: number; assignmentName?: string; onClose: () => void; onSaved: (message: string) => void; onDenied: (message: string) => void
}) {
  const dialog = useRef<HTMLDialogElement>(null)
  const locked = useRef(false)
  const controller = useRef(new AbortController())
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  useEffect(() => {
    const abort = new AbortController()
    controller.current = abort
    const node = dialog.current
    node?.showModal()
    return () => { abort.abort(); node?.close() }
  }, [])
  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (locked.current) return
    locked.current = true; setBusy(true); setError('')
    const form = new FormData(event.currentTarget)
    const value = (name: string) => String(form.get(name) ?? '').trim()
    const signal = controller.current.signal
    let completed = 0
    let alreadyTerminated = false
    try {
      if ((action === 'terminate' || action === 'rehire') && form.get('confirm_lifecycle') !== 'on') { setError('Confirm the lifecycle action before continuing.'); return }
      if (action === 'rehire' && (!nextDate(employee?.ends_on) || !/^\d{4}-\d{2}-\d{2}$/.test(value('starts_on')) || value('starts_on') < nextDate(employee?.ends_on)!)) { setError('Choose a rehire start date after the previous termination date. Same-day rehire is not supported.'); return }

      const me = await fetch('/api/me', { cache: 'no-store', signal })
      const session = await me.json() as { authenticated?: boolean; csrf_token?: string }
      if (!me.ok || !session.authenticated || typeof session.csrf_token !== 'string') { if (!signal.aborted) onDenied(message(401, '')); return }
      const base = `/api/admin/businesses/${businessId}/employees`
      const path = employee ? `${base}/${employee.employee_id}/periods/${employee.period_id}` : base
      const contacts = Object.fromEntries(['first_name', 'last_name', 'phone', 'email', 'home_address'].map(k => [k, value(k)]))
      let requests: { path: string; method: string; body: object }[]
      if (action === 'create') requests = [{ path: base, method: 'POST', body: { ...contacts, classification: value('classification'), starts_on: value('starts_on') } }]
      else if (action === 'contact') requests = [{ path: `${path}/contact`, method: 'PATCH', body: contacts }]
      else if (action === 'classification') requests = [{ path: `${path}/classification`, method: 'PATCH', body: { classification: value('classification') } }]
      else if (action === 'terminate') requests = [{ path: `${path}/terminate`, method: 'POST', body: {} }]
      else if (action === 'rehire') requests = [{ path: `${path}/rehire`, method: 'POST', body: { starts_on: value('starts_on') } }]
      else if (action === 'end') requests = [{ path: `${path}/shop-assignments/${assignmentId}/end`, method: 'POST', body: { ends_on: value('ends_on') } }]
      else {
        const selected = shops.filter(s => form.getAll('shops').includes(String(s.id)))
        if (!selected.length) { setError('Select at least one shop.'); return }
        requests = selected.map(s => ({ path: `${path}/shop-assignments`, method: 'POST', body: { shop_id: s.id, starts_on: value('starts_on') } }))
      }
      for (const request of requests) {
        if (signal.aborted) return
        const response = await fetch(request.path, { method: request.method, signal, headers: { 'content-type': 'application/json', 'x-csrf-token': session.csrf_token }, body: JSON.stringify(request.body) })
        if (signal.aborted) return
        if (!response.ok) {
          const result = await response.json().catch(() => ({})) as { error?: string }
          if (signal.aborted) return
          const text = message(response.status, result.error ?? '')
          if (response.status === 401 || response.status === 403) onDenied(text)
          else if (completed) onSaved(`${completed} shop assignment(s) saved. ${text}`)
          else setError(text)
          return
        }
        if (action === 'terminate') {
          const result = await response.json() as { data?: { employment?: { employee_id?: number; period_id?: number; status?: string }; already_terminated?: boolean } }
          if (signal.aborted) return
          if (result.data?.employment?.employee_id !== employee?.employee_id || result.data?.employment?.period_id !== employee?.period_id || result.data?.employment?.status !== 'ended' || typeof result.data?.already_terminated !== 'boolean') throw new Error('unconfirmed result')
          alreadyTerminated = result.data.already_terminated
        }
        completed++
      }
      if (!signal.aborted) onSaved(action === 'terminate' ? (alreadyTerminated ? 'This employment period was already terminated; no additional offboarding changes were made.' : 'The requested employment period was terminated. Historical records are retained.') : action === 'assign' ? `${completed} shop assignment(s) saved.` : `${names[action]} saved.`)
    } catch {
      if (!signal.aborted) {
        if (completed) onSaved(`${completed} shop assignment(s) saved. The remaining save could not be confirmed; refresh before retrying.`)
        else setError('The save could not be confirmed. Refresh employee information before retrying.')
      }
    } finally { locked.current = false; if (!signal.aborted) setBusy(false) }
  }
  return <dialog ref={dialog} aria-labelledby="hr-form-title" className="employee-hr-dialog" onCancel={e => { e.preventDefault(); if (!busy) onClose() }}>
    <h3 id="hr-form-title">{names[action]}</h3>
    {employee && <p>{employee.first_name} {employee.last_name} · Period #{employee.period_id}</p>}
    {action === 'create' && <p>This creates an employment record without a login account or role grants.</p>}
    {action === 'classification' && <p>Current classification: {employee?.classification.replaceAll('_', ' ')}. Classification does not grant application roles or permissions.</p>}
    {action === 'end' && <p>End assignment to {assignmentName}. Employment remains active; retained history is preserved.</p>}
    {action === 'assign' && <p>Each selected shop is saved separately. Any partial success will be reported.</p>}
    {action === 'terminate' && <><p>This ends employment in this business. The server will:</p><ul><li>Unassign future jobs and cancel future shifts for this employee, preserving other team members.</li><li>End active shop assignments.</li><li>Revoke linked access and role grants in this business only; unrelated businesses remain unchanged.</li><li>Retain complete employment, work, compensation and audit history.</li></ul><p>In-progress work, incompatible dates and Owner protections may block termination. No conflicts will be silently resolved.</p></>}
    {action === 'rehire' && <><p>Rehire creates a new period for this stable employee identity. Previous periods remain retained HR history.</p><p>It restores no business memberships, RBAC grants, account access, compensation rates, shop assignments, work shifts or job assignments. Historical private information is not copied into the new period.</p><p>Previous termination: {employee?.ends_on}. Dates are inclusive; same-day termination and rehire are not supported.</p></>}
    <form onSubmit={submit}>
      <fieldset disabled={busy}>
        {(action === 'create' || action === 'contact') && <>
          <label>First name<input name="first_name" required maxLength={100} defaultValue={employee?.first_name ?? ''} /></label>
          <label>Last name<input name="last_name" required maxLength={100} defaultValue={employee?.last_name ?? ''} /></label>
          <label>Phone<input name="phone" type="tel" maxLength={32} defaultValue={employee?.phone ?? ''} /></label>
          <label>Email<input name="email" type="email" maxLength={320} defaultValue={employee?.email ?? ''} /></label>
          <label>Home address<textarea name="home_address" maxLength={1000} defaultValue={employee?.home_address ?? ''} /></label>
        </>}
        {(action === 'create' || action === 'classification') && <label>Employment classification<select name="classification" defaultValue={employee?.classification ?? 'detailer'}>{classifications.map(c => <option key={c} value={c}>{c.replaceAll('_', ' ')}</option>)}</select></label>}
        {action === 'classification' && <label><input type="checkbox" required />I confirm this classification change; it does not change role grants.</label>}
        {(action === 'create' || action === 'assign') && <label>{action === 'create' ? 'Employment start date' : 'Shop assignment start date'}<input type="date" name="starts_on" required /></label>}
        {action === 'assign' && <fieldset><legend>Business shops</legend>{shops.map(s => <label key={s.id}><input type="checkbox" name="shops" value={s.id} />{s.name}</label>)}</fieldset>}
        {action === 'end' && <label>Shop assignment end date<input type="date" name="ends_on" required /></label>}
        {action === 'rehire' && <label>Rehire start date<input type="date" name="starts_on" required min={nextDate(employee?.ends_on)} /></label>}
        {(action === 'terminate' || action === 'rehire') && <label><input type="checkbox" name="confirm_lifecycle" required />{action === 'terminate' ? 'I confirm employment termination and business-specific offboarding.' : 'I confirm a new employment period with no automatic restoration.'}</label>}
        {error && <p role="alert">{error}</p>}
        <button className="secondary-button" type="submit">{busy ? 'Saving…' : 'Save changes'}</button>
        <button className="secondary-button" type="button" onClick={onClose}>Cancel</button>
      </fieldset>
    </form>
  </dialog>
}
