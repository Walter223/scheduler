import { useEffect, useRef, useState } from 'react'
import './setup.css'
import OnboardingNavigation from './OnboardingNavigation'
import {onboardingStates, onboardingProgress, setupSteps} from './onboardingProgress'
import type {SetupStep} from './onboardingProgress'
import SetupGuide from './SetupGuide'
import BrandingEditor, {BrandingPreview} from './BrandingEditor'
import StaffEditor from './StaffEditor'
import CatalogEditor, { CatalogReview } from './CatalogEditor'
import type { CatalogDraft, ServiceDraft } from './CatalogEditor'
import type { StaffProposal } from './StaffEditor'
import LocationEditor from './LocationEditor'
import {locationErrors,cleanLocationInputs} from './locationDraft'
import type {Location,Defaults,LocationErrors} from './LocationEditor'
type Proposal = { locations: Location[]; defaults: Defaults; employees: StaffProposal[]; services: ServiceDraft[]; catalog: CatalogDraft; branding: Record<string, unknown> }
type Draft = { revision: number; schema_version: number; state: string; proposal: Proposal; applied: {shops: {id: number; name: string; timezone: string}[]} }
const states:readonly string[] = onboardingStates
// Legacy proposals are only adapted in memory. Missing description/shop scope must
// be explicitly completed; no catalog/domain record or stored receipt is rewritten.
function normalizeCatalog(proposal: Proposal, shops:Draft['applied']['shops']=[]): Proposal {
  if(proposal.locations.length===0&&shops[0])proposal={...proposal,locations:[{key:`shop-${shops[0].id}`,existing_shop_id:shops[0].id,name:shops[0].name,timezone:shops[0].timezone,operating_model:'in_shop'}]}
  if (proposal.catalog) return proposal
  const legacy = proposal.services as unknown as {name: string; duration_minutes: number; price_cents: number}[]
  return {...proposal, catalog: {version: 1, currency: 'USD', vehicle_categories: legacy.length ? [{key: 'legacy-standard', name: 'Standard'}] : []}, services: legacy.map((s, i)=>({version: 2, key: `legacy-service-${i}`, name: s.name, description: '', duration_minutes: s.duration_minutes, status: 'planned', delivery_mode: 'in_shop', location_keys: [], prices: [{category_key: 'legacy-standard', price_cents: s.price_cents}], overrides: []}))}
}
export default function SetupWorkspace({ businessId }: { businessId: number }) {
  const [draft, setDraft] = useState<Draft | null>(null)
  const [proposal, setProposal] = useState<Proposal | null>(null)
  const [tab, setTab] = useState<SetupStep>('Business')
  const [message, setMessage] = useState('Loading setup…')
  const [errors,setErrors]=useState<LocationErrors>({})
  const [zones,setZones]=useState<string[]>([])
  const [dirty, setDirty] = useState(false)
  const [busy, setBusy] = useState(false)
  const [reload, setReload] = useState(0)
  const [conflict, setConflict] = useState(false)
  const [uncertain, setUncertain] = useState(false)
  const pending = useRef(false)
  const request = useRef<string | null>(null)
  const lifetime = useRef<AbortController | null>(null)
  const resumedBusiness = useRef<number|null>(null)
  const path = `/api/admin/businesses/${businessId}/onboarding`
  useEffect(() => {
    const controller = new AbortController()
    lifetime.current = controller
    request.current = null
    async function load() {
      setErrors({});setDraft(null); setProposal(null); setMessage('Loading setup…'); setDirty(false); setConflict(false); setUncertain(false)
      try {
        const response = await fetch(path, {cache: 'no-store', signal: controller.signal})
        if (controller.signal.aborted) return
        if (response.status === 404) { setMessage('Begin setup to save private proposals for this business.'); return }
        if (!response.ok) throw new Error(response.status === 401 || response.status === 403 ? 'Setup access is unavailable. Sign in again or refresh access.' : 'Setup could not be loaded. Retry when connected.')
        const {data} = await response.json()
        if (controller.signal.aborted) return
        if (data.schema_version !== 1 || !states.includes(data.state) || !Array.isArray(data.proposal?.locations) || !Array.isArray(data.applied?.shops)) throw Error('Unsupported setup response.')
        if(resumedBusiness.current!==businessId){setTab(onboardingProgress(data).active);resumedBusiness.current=businessId}
        setDraft(data); setProposal(normalizeCatalog({...data.proposal, employees: data.proposal.employees.map((p: Partial<StaffProposal> & {intended_role?: string}, i: number) => ({version:2,key:p.key || `legacy-${i}`,name:p.name || '',email:p.email || '',classification:p.classification || '',location_keys:p.location_keys || [],responsibilities:p.responsibilities || {business_management:false,shop_management_keys:[]},access_roles:p.access_roles || (p.intended_role ? [{role:p.intended_role,location_keys:p.intended_role==='business_manager'?[]:p.location_keys || []}] : [])}))},data.applied.shops)); setDirty(data.proposal.locations.length===0&&data.applied.shops.length>0);setMessage('Saved setup loaded.')
      } catch (error) { if (!controller.signal.aborted) setMessage((error as Error).message) }
    }
    void load()
    return () => controller.abort()
  }, [path, reload, businessId])
  function edit(next: Proposal) { setProposal(next); setDirty(true); setMessage('Unsaved changes') }
  async function save(begin = false, state = draft?.state, confirm = false, advance = false) {
    if (pending.current) return
    const submitted = !begin && tab==='Locations' ? cleanLocationInputs(proposal!) : proposal
    if(!begin && tab==='Locations' && !uncertain){
      const issues=locationErrors(submitted!.locations,submitted!.defaults,zones,advance)
      setErrors(issues)
      if(Object.keys(issues).length){setMessage('Location details were not saved. Check the highlighted fields.');return}
    }
    const signal = lifetime.current!.signal
    pending.current = true; setBusy(true); setMessage('Saving…')
    if (!request.current) request.current = begin ? '{}' : JSON.stringify({revision: draft!.revision, request_id: crypto.randomUUID(), state, proposal:submitted,...(confirm?{confirm_review:true}:{})})
    try {
      const status = await fetch('/api/me', {cache: 'no-store', signal})
      const session = await status.json()
      if (signal.aborted) return
      if (!status.ok || !session.authenticated || !session.csrf_token) { setDraft(null); setProposal(null); setMessage('Your session expired. Sign in again.'); return }
      const response = await fetch(path, {method: begin ? 'POST' : 'PUT', signal, headers: {'Content-Type': 'application/json', 'x-csrf-token': session.csrf_token}, body: request.current})
      if (signal.aborted) return
      if (response.status === 401 || response.status === 403) { setDraft(null); setProposal(null); setMessage('Setup access is no longer available. Refresh access.'); return }
      if (response.status === 409) { setConflict(true); setMessage('Another save changed this draft. Reload the current revision before editing.'); return }
      if (!response.ok && tab==='Locations') { request.current=null;setErrors({server:'The server could not accept these location details. Review the name, timezone and service settings. Other saved stages may also need attention.'});setMessage('Location details were not saved. Review the location form and try again.');return }
      if (!response.ok) { request.current = null; setMessage('Setup was not saved. Check required staff names, valid unique work emails, classification, assignments and role scopes; check branding email, phone, hex colors and preset; check service/category names, positive USD prices, durations and shop delivery modes; also check location details and travel buffers (0–240 minutes).'); return }
      const {data} = await response.json()
      if (signal.aborted) return
      resumedBusiness.current=businessId
      if(advance || state!==draft?.state)setTab(onboardingProgress(data).active)
      setDraft(data); setProposal(normalizeCatalog(data.proposal,data.applied.shops)); setDirty(data.proposal.locations.length===0&&data.applied.shops.length>0); setUncertain(false); request.current = null; setMessage('Saved to this business.')
    } catch { if (!signal.aborted) { setUncertain(true); setMessage('Save result is uncertain. Retry the identical request before making further edits.') } }
    finally { pending.current = false; if (!signal.aborted) setBusy(false) }
  }
  const locked = busy || conflict || uncertain || draft?.state === 'completed'
  return <section className="setup-workspace" aria-label="Business setup">
    <p role="status">{message}</p><p><strong>Unpublished.</strong> Setup contains proposals only. Mobile booking, invitations and publishing are not enabled.</p>
    {!draft ? <><button className="admin-button" disabled={busy} onClick={() => save(true)}>Begin setup</button><button className="admin-button" onClick={() => setReload(v => v+1)}>Retry loading</button></> : <>
      <p>{dirty?'Unsaved edits':'Saved draft'} · Revision {draft.revision}</p>
      <OnboardingNavigation draft={draft} selected={tab} onSelect={setTab} />
      {tab === 'Business' && <><h3>Provisioning complete</h3><p>Your business and initial shop already exist. Begin with Locations; no setup save creates or duplicates a shop.</p><ul>{draft.applied.shops.map(s => <li key={s.id}>{s.name} · {s.timezone} <button className="admin-button" disabled={locked || proposal!.locations.some(l => l.existing_shop_id === s.id)} onClick={() => edit({...proposal!, locations: [...proposal!.locations,{key: `shop-${s.id}`,existing_shop_id:s.id,name:s.name,timezone:s.timezone,operating_model:'in_shop'}]})}>Configure {s.name}</button></li>)}</ul></>}
      {tab === 'Locations' && <LocationEditor locations={proposal!.locations} defaults={proposal!.defaults} shops={draft.applied.shops} disabled={locked} errors={errors} onZones={setZones} onChange={locations=>{setErrors({});edit({...proposal!,locations})}} onDefaults={defaults=>{setErrors({});edit({...proposal!,defaults})}} />}
      {tab === 'Staff' && <StaffEditor staff={proposal!.employees} locations={proposal!.locations} disabled={locked} onChange={employees => edit({...proposal!,employees})} />}
      {tab === 'Services' && <CatalogEditor catalog={proposal!.catalog} services={proposal!.services} locations={proposal!.locations} disabled={locked} onChange={(catalog, services)=>edit({...proposal!,catalog,services})} />}
      {tab === 'Branding' && <BrandingEditor value={proposal!.branding as Record<string,string>} disabled={locked} onChange={branding=>edit({...proposal!,branding})} />}
      {tab === 'Review' && <><h3>Review proposed setup</h3><p>{proposal!.locations.length} location proposals · {proposal!.employees.length} staff proposals · {proposal!.services.length} service proposals</p><ul>{proposal!.locations.map(l => <li key={l.key}>{l.name} · {l.address || 'Address missing'} · {l.timezone || proposal!.defaults.timezone || 'Timezone missing'} · {l.operating_model || proposal!.defaults.operating_model || 'Model missing'} · Areas: {(l.mobile?.service_areas || proposal!.defaults.mobile?.service_areas || []).join(', ') || 'Not specified'} · Dispatch: {l.mobile?.dispatch_source || proposal!.defaults.mobile?.dispatch_source || 'Not specified'} · Proposed travel buffer: {l.mobile?.travel_buffer_minutes ?? proposal!.defaults.mobile?.travel_buffer_minutes ?? 'Not specified'} minutes</li>)}</ul><ul>{proposal!.employees.map(p => <li key={p.key}>{p.name || 'Name missing'} · {p.email || 'Email missing'} · Classification: {p.classification.replaceAll('_',' ') || 'Missing'} · Shops: {p.location_keys.map(k=>proposal!.locations.find(l=>l.key===k)?.name || `Missing ${k}`).join(', ') || 'Unassigned'} · Management: {p.responsibilities.business_management ? 'Business HR/finance' : 'None'} {p.responsibilities.shop_management_keys.map(k=>proposal!.locations.find(l=>l.key===k)?.name || k).join(', ')} · Access requests: {p.access_roles.map(r=>`${r.role.replaceAll('_',' ')} (${r.role==='business_manager'?'business-wide':r.location_keys.map(k=>proposal!.locations.find(l=>l.key===k)?.name || k).join(', ')})`).join('; ') || 'None'}</li>)}</ul><CatalogReview catalog={proposal!.catalog} services={proposal!.services} locations={proposal!.locations} /><BrandingPreview value={proposal!.branding as Record<string,string>}/><p>Branding remains unpublished. Staff proposals require future authorized review and application. Drafts have not been applied. Publication controls and travel-aware capacity are still required.</p></>}
      <div className="setup-actions"><button className="admin-button" disabled={busy || conflict || draft.state === 'completed'} onClick={() => save()}>{busy ? 'Saving…' : uncertain ? 'Retry identical save' : 'Save draft'}</button>{draft.state !== 'completed' && (tab === onboardingProgress(draft).active ? <button className="admin-button" disabled={locked} onClick={()=>save(false,onboardingProgress(draft).nextState,(draft.state==='review'||draft.state==='ready_to_publish')&&tab==='Review',true)}>{draft.state==='review'?'Confirm draft review':draft.state==='ready_to_publish'?'Finish setup review':tab==='Staff'&&proposal!.employees.length===0?'Continue without a team':'Save and continue'}</button> : <button className="admin-button" disabled={locked} onClick={()=>setTab(onboardingProgress(draft).active)}>Continue setup: {onboardingProgress(draft).active}</button>)}<button className="admin-button" disabled={busy || setupSteps.indexOf(tab)===0} onClick={()=>setTab(setupSteps[setupSteps.indexOf(tab)-1])}>Back</button>{conflict && <button className="admin-button" onClick={() => setReload(v=>v+1)}>Discard local edits and reload</button>}</div>
      <SetupGuide businessId={businessId} proposal={proposal! as unknown as Record<string,unknown>} onRevision={revision=>setDraft(d=>d?{...d,revision}:d)} onApproved={()=>setReload(v=>v+1)} />
    </>}
  </section>
}
