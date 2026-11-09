import { useEffect, useRef, useState } from 'react'
import './setup.css'
type Mobile = { service_areas?: string[]; dispatch_source?: string; dispatch_location_key?: string; travel_buffer_minutes?: number }
type Location = { key: string; existing_shop_id?: number; name: string; address?: string; timezone?: string; operating_model?: string; mobile?: Mobile }
type Defaults = { timezone?: string; operating_model?: string; mobile?: Mobile }
type Proposal = { locations: Location[]; defaults: Defaults; employees: unknown[]; services: unknown[]; branding: Record<string, unknown> }
type Draft = { revision: number; schema_version: number; state: string; proposal: Proposal; applied: {shops: {id: number; name: string; timezone: string}[]} }
const states = ['provisioning_complete', 'locations', 'employees', 'services_pricing', 'branding', 'review', 'ready_to_publish', 'completed']
export default function SetupWorkspace({ businessId }: { businessId: number }) {
  const [draft, setDraft] = useState<Draft | null>(null)
  const [proposal, setProposal] = useState<Proposal | null>(null)
  const [tab, setTab] = useState('Business')
  const [message, setMessage] = useState('Loading setup…')
  const [dirty, setDirty] = useState(false)
  const [busy, setBusy] = useState(false)
  const [reload, setReload] = useState(0)
  const [conflict, setConflict] = useState(false)
  const [uncertain, setUncertain] = useState(false)
  const pending = useRef(false)
  const request = useRef<string | null>(null)
  const lifetime = useRef<AbortController | null>(null)
  const path = `/api/admin/businesses/${businessId}/onboarding`
  useEffect(() => {
    const controller = new AbortController()
    lifetime.current = controller
    request.current = null
    async function load() {
      setDraft(null); setProposal(null); setMessage('Loading setup…'); setDirty(false); setConflict(false); setUncertain(false)
      try {
        const response = await fetch(path, {cache: 'no-store', signal: controller.signal})
        if (controller.signal.aborted) return
        if (response.status === 404) { setMessage('Begin setup to save private proposals for this business.'); return }
        if (!response.ok) throw new Error(response.status === 401 || response.status === 403 ? 'Setup access is unavailable. Sign in again or refresh access.' : 'Setup could not be loaded. Retry when connected.')
        const {data} = await response.json()
        if (controller.signal.aborted) return
        if (data.schema_version !== 1 || !states.includes(data.state) || !Array.isArray(data.proposal?.locations) || !Array.isArray(data.applied?.shops)) throw Error('Unsupported setup response.')
        setDraft(data); setProposal(data.proposal); setMessage('Saved setup loaded.')
      } catch (error) { if (!controller.signal.aborted) setMessage((error as Error).message) }
    }
    void load()
    return () => controller.abort()
  }, [path, reload])
  function edit(next: Proposal) { setProposal(next); setDirty(true); setMessage('Unsaved changes') }
  async function save(begin = false, state = draft?.state) {
    if (pending.current) return
    const signal = lifetime.current!.signal
    pending.current = true; setBusy(true); setMessage('Saving…')
    if (!request.current) request.current = begin ? '{}' : JSON.stringify({revision: draft!.revision, request_id: crypto.randomUUID(), state, proposal})
    try {
      const status = await fetch('/api/me', {cache: 'no-store', signal})
      const session = await status.json()
      if (signal.aborted) return
      if (!status.ok || !session.authenticated || !session.csrf_token) { setDraft(null); setProposal(null); setMessage('Your session expired. Sign in again.'); return }
      const response = await fetch(path, {method: begin ? 'POST' : 'PUT', signal, headers: {'Content-Type': 'application/json', 'x-csrf-token': session.csrf_token}, body: request.current})
      if (signal.aborted) return
      if (response.status === 401 || response.status === 403) { setDraft(null); setProposal(null); setMessage('Setup access is no longer available. Refresh access.'); return }
      if (response.status === 409) { setConflict(true); setMessage('Another save changed this draft. Reload the current revision before editing.'); return }
      if (!response.ok) { request.current = null; setMessage('Setup was not saved. Check names, addresses, IANA timezones, dispatch references and travel buffers (0–240 minutes).'); return }
      const {data} = await response.json()
      if (signal.aborted) return
      setDraft(data); setProposal(data.proposal); setDirty(false); setUncertain(false); request.current = null; setMessage('Saved to this business.')
    } catch { if (!signal.aborted) { setUncertain(true); setMessage('Save result is uncertain. Retry the identical request before making further edits.') } }
    finally { pending.current = false; if (!signal.aborted) setBusy(false) }
  }
  function location(index: number, next: Location) { edit({...proposal!, locations: proposal!.locations.map((l,i) => i === index ? next : l)}) }
  const locked = busy || conflict || uncertain || draft?.state === 'completed'
  function mobile(value: Mobile, change: (v: Mobile) => void) {
    return <div className="setup-grid"><label>Coverage areas (one per line)<textarea value={(value.service_areas || []).join('\n')} onChange={e => change({...value, service_areas: e.target.value.split('\n')})} /></label><label>Dispatch source<select value={value.dispatch_source || ''} onChange={e => { const next: Mobile = {...value, dispatch_source: e.target.value}; if (!e.target.value) delete next.dispatch_source; if (e.target.value !== 'location_key') delete next.dispatch_location_key; change(next) }}><option value="">Inherit / not specified</option><option value="this_location">This location</option><option value="location_key">Another draft location</option></select></label>{value.dispatch_source === 'location_key' && <label>Dispatch location<select value={value.dispatch_location_key || ''} onChange={e => change({...value, dispatch_location_key: e.target.value})}><option value="">Choose location</option>{proposal!.locations.map(l => <option key={l.key} value={l.key}>{l.name || l.key}</option>)}</select></label>}<label>Travel buffer (minutes)<input type="number" min={0} max={240} value={value.travel_buffer_minutes ?? ''} onChange={e => { const next = {...value}; if (e.target.value === '') delete next.travel_buffer_minutes; else next.travel_buffer_minutes = Number(e.target.value); change(next) }} /></label></div>
  }
  return <section className="setup-workspace" aria-label="Business setup">
    <p role="status">{message}</p><p><strong>Unpublished.</strong> Setup contains proposals only. Mobile booking, invitations and publishing are not enabled.</p>
    {!draft ? <><button className="admin-button" disabled={busy} onClick={() => save(true)}>Begin setup</button><button className="admin-button" onClick={() => setReload(v => v+1)}>Retry loading</button></> : <>
      <p>Saved workflow: {draft.state.replaceAll('_',' ')} · Revision {draft.revision}{dirty ? ' · Unsaved edits' : ''}</p>
      <nav aria-label="Setup steps">{['Business','Locations','Staff','Services','Branding','Review'].map(step => <button className="admin-button" key={step} aria-current={tab === step ? 'step' : undefined} onClick={() => setTab(step)}>{step}{['Staff','Services','Branding'].includes(step) ? ' · Planned' : ''}</button>)}</nav>
      {tab === 'Business' && <><h3>Provisioning complete</h3><p>Your business and initial shop already exist. Begin with Locations; no setup save creates or duplicates a shop.</p><ul>{draft.applied.shops.map(s => <li key={s.id}>{s.name} · {s.timezone} <button className="admin-button" disabled={locked || proposal!.locations.some(l => l.existing_shop_id === s.id)} onClick={() => edit({...proposal!, locations: [...proposal!.locations,{key: `shop-${s.id}`,existing_shop_id:s.id,name:s.name,timezone:s.timezone,operating_model:'in_shop'}]})}>Configure {s.name}</button></li>)}</ul></>}
      {tab === 'Locations' && <fieldset disabled={locked}><legend>Location proposals</legend><h3>Shared defaults</h3><div className="setup-grid"><label>Default timezone<input value={proposal!.defaults.timezone || ''} onChange={e => {const defaults = {...proposal!.defaults}; if(e.target.value) defaults.timezone=e.target.value; else delete defaults.timezone; edit({...proposal!,defaults})}} /></label><label>Default operating model<select value={proposal!.defaults.operating_model || ''} onChange={e => {const defaults={...proposal!.defaults}; if(e.target.value) defaults.operating_model=e.target.value; else delete defaults.operating_model; edit({...proposal!,defaults})}}><option value="">Not specified</option><option value="in_shop">In-shop</option><option value="mobile">Mobile dispatch</option><option value="both">Both</option></select></label></div>{mobile(proposal!.defaults.mobile || {}, v => edit({...proposal!,defaults:{...proposal!.defaults,mobile:v}}))}
      {proposal!.locations.map((l,i) => <fieldset key={l.key}><legend>{l.name || `Location ${i+1}`} {l.existing_shop_id ? '· Existing shop' : '· Proposed new shop'}</legend><div className="setup-grid"><label>Shop name<input maxLength={255} value={l.name} onChange={e => location(i,{...l,name:e.target.value})} /></label><label>Address<input maxLength={1000} value={l.address || ''} onChange={e => {const next={...l}; if(e.target.value)next.address=e.target.value;else delete next.address;location(i,next)}} /></label><label>IANA timezone<input placeholder="Inherit default timezone" value={l.timezone || ''} onChange={e => {const next={...l};if(e.target.value)next.timezone=e.target.value;else delete next.timezone;location(i,next)}} /></label><label>Operating model<select value={l.operating_model || ''} onChange={e => {const next={...l};if(e.target.value)next.operating_model=e.target.value;else delete next.operating_model;location(i,next)}}><option value="">Inherit default</option><option value="in_shop">In-shop</option><option value="mobile">Mobile dispatch</option><option value="both">Both</option></select></label></div>{mobile(l.mobile || {}, v => location(i,{...l,mobile:v}))}<button className="admin-button" onClick={() => edit({...proposal!,locations:proposal!.locations.filter((_,n)=>n!==i)})}>Remove proposal for {l.name || 'location'}</button></fieldset>)}<button className="admin-button" onClick={() => edit({...proposal!,locations:[...proposal!.locations,{key:`new-${crypto.randomUUID()}`,name:'',...(proposal!.defaults.timezone ? {} : {timezone:'America/Denver'}),...(proposal!.defaults.operating_model ? {} : {operating_model:'in_shop'})}]})}>Add location proposal</button></fieldset>}
      {['Staff','Services','Branding'].includes(tab) && <p>{tab} editing is not implemented. Existing saved proposals are preserved. No invitations, catalog or branding changes will be applied.</p>}
      {tab === 'Review' && <><h3>Review proposed setup</h3><p>{proposal!.locations.length} location proposals · {proposal!.employees.length} staff proposals · {proposal!.services.length} service proposals</p><ul>{proposal!.locations.map(l => <li key={l.key}>{l.name} · {l.address || 'Address missing'} · {l.timezone || proposal!.defaults.timezone || 'Timezone missing'} · {l.operating_model || proposal!.defaults.operating_model || 'Model missing'} · Areas: {(l.mobile?.service_areas || proposal!.defaults.mobile?.service_areas || []).join(', ') || 'Not specified'} · Dispatch: {l.mobile?.dispatch_source || proposal!.defaults.mobile?.dispatch_source || 'Not specified'} · Proposed travel buffer: {l.mobile?.travel_buffer_minutes ?? proposal!.defaults.mobile?.travel_buffer_minutes ?? 'Not specified'} minutes</li>)}</ul><p>Staff, services and branding editors remain planned. Drafts have not been applied. Publication controls and travel-aware capacity are still required.</p></>}
      <div className="setup-actions"><button className="admin-button" disabled={busy || conflict || draft.state === 'completed'} onClick={() => save()}>{busy ? 'Saving…' : uncertain ? 'Retry identical save' : 'Save draft'}</button>{draft.state === 'provisioning_complete' && <button className="admin-button" disabled={locked} onClick={() => save(false,'locations')}>Save and start Locations</button>}{draft.state === 'locations' && <button className="admin-button" disabled={locked} onClick={() => save(false,'employees')}>Validate Locations and continue</button>}{conflict && <button className="admin-button" onClick={() => setReload(v=>v+1)}>Discard local edits and reload</button>}</div>
    </>}
  </section>
}
