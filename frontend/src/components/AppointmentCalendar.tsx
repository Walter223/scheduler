import { useCallback, useEffect, useRef, useState } from 'react'
import AppointmentCrew from './AppointmentCrew'
type Appointment = { id: number; shop_id: number; shop_name: string; timezone: string; starts_at: string; ends_at: string; duration_minutes: number; service_name: string; vehicle_make: string; vehicle_model: string; vehicle_size: string; status: string; crew_size: number; lead_detailer: string | null }
type Data = { appointments: Appointment[]; shops: { id: number; name: string; timezone: string }[]; meta: { has_more: boolean; next_cursor: string | null } }
const statuses = ['pending', 'confirmed', 'completed', 'cancelled']
function localDate(instant: Date, zone: string) {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: zone, year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(instant)
  return ['year', 'month', 'day'].map(k => parts.find(p => p.type === k)!.value).join('-')
}
function advance(date: string, count: number) {
  const value = new Date(`${date}T00:00:00Z`)
  if (!Number.isFinite(value.getTime())) return date
  value.setUTCDate(value.getUTCDate() + count)
  return value.toISOString().slice(0, 10)
}
const time = (value: string, zone: string) => new Intl.DateTimeFormat('en-US', { timeZone: zone, hour: 'numeric', minute: '2-digit' }).format(new Date(value))
const offset = (value: string, zone: string) => new Intl.DateTimeFormat('en-US', { timeZone: zone, timeZoneName: 'longOffset' }).formatToParts(new Date(value)).find(p => p.type === 'timeZoneName')!.value
function dateLabel(value: string) {
  const instant = new Date(`${value}T12:00:00Z`)
  return Number.isFinite(instant.getTime()) ? new Intl.DateTimeFormat('en-US', { timeZone: 'UTC', weekday: 'short', month: 'short', day: 'numeric' }).format(instant) : 'Choose a date'
}
export default function AppointmentCalendar({ businessId, shopId, timezone }: { businessId: number; shopId: number; timezone: string }) {
  const [date, setDate] = useState(() => localDate(new Date(), timezone))
  const [view, setView] = useState('list')
  const [status, setStatus] = useState('all')
  const [cursor, setCursor] = useState('')
  const [data, setData] = useState<Data | null>(null)
  const [error, setError] = useState('')
  const [selected, setSelected] = useState<Appointment | null>(null)
  const [revision, setRevision] = useState(0)
  const trigger = useRef<HTMLButtonElement | null>(null)
  const [crewRevision, setCrewRevision] = useState(0)
  const crewDenied = useCallback((message: string) => { setSelected(null); setData(null); setError(message) }, [])
  const crewChanged = useCallback(() => setCrewRevision(v => v + 1), [])
  const days = view === 'week' ? 7 : 1
  useEffect(() => {
    const controller = new AbortController()
    async function load() {
      setData(null); setError('')
      try {
        const params = new URLSearchParams({ date, days: String(days), status, limit: '50', ...(shopId ? { shop_id: String(shopId) } : {}), ...(cursor ? { cursor } : {}) })
        const response = await fetch(`/api/admin/businesses/${businessId}/calendar?${params}`, { signal: controller.signal, cache: 'no-store' })
        if (controller.signal.aborted) return
        if (!response.ok) { setSelected(null); setError(response.status === 401 ? 'Your session has expired. Sign in again.' : response.status === 403 ? 'Appointment access is no longer available.' : response.status === 422 ? 'Choose a valid date and start from the first page.' : 'Appointments are temporarily unavailable.'); return }
        const body = await response.json() as { data: Data }
        const value = body.data
        if (!value || !Array.isArray(value.appointments) || !Array.isArray(value.shops) || !value.meta || typeof value.meta.has_more !== 'boolean' || !(value.meta.next_cursor === null || typeof value.meta.next_cursor === 'string')) throw new Error('invalid page')
        for (const a of value.appointments) {
          if (!a || !Number.isSafeInteger(a.id) || !Number.isSafeInteger(a.shop_id) || !Number.isFinite(Date.parse(a.starts_at)) || !Number.isFinite(Date.parse(a.ends_at)) || !Number.isSafeInteger(a.duration_minutes) || !Number.isSafeInteger(a.crew_size) || a.crew_size < 0 || !statuses.includes(a.status) || ![a.service_name,a.shop_name,a.vehicle_make,a.vehicle_model,a.vehicle_size,a.timezone].every(v => typeof v === 'string') || !(a.lead_detailer === null || typeof a.lead_detailer === 'string')) throw new Error('invalid appointment')
          time(a.starts_at, a.timezone)
        }
        if (!value.shops.every(s => s && Number.isSafeInteger(s.id) && typeof s.name === 'string' && typeof s.timezone === 'string')) throw new Error('invalid shops')
        if (!controller.signal.aborted) setData(value)
      } catch { if (!controller.signal.aborted) { setSelected(null); setError('Appointments are temporarily unavailable.') } }
    }
    void load()
    return () => controller.abort()
  }, [businessId, shopId, date, days, status, cursor, revision, crewRevision])
  function reset() { setData(null); setSelected(null); setCursor('') }
  function changeDate(next: string) { reset(); setDate(next); setRevision(v => v + 1) }
  const entries = (items: Appointment[]) => items.map(a => <li key={a.id} className="calendar-entry" data-status={a.status}>
    <button className="calendar-open" aria-label={`View ${a.service_name} · ${time(a.starts_at, a.timezone)} · ${a.shop_name}`} onClick={e => { trigger.current = e.currentTarget; setSelected(a) }}>
      <span className="calendar-time"><time dateTime={a.starts_at}>{time(a.starts_at, a.timezone)}</time><small>{a.duration_minutes} min</small></span>
      <span className="calendar-summary"><strong>{a.service_name}</strong><span>{a.shop_name} · {a.timezone}</span><span>{a.crew_size} Detailer(s){a.lead_detailer ? ` · Lead: ${a.lead_detailer}` : ''}</span>{['pending', 'confirmed'].includes(a.status) && a.crew_size === 0 && <span className="calendar-needs-staffing">Needs staffing</span>}</span>
      <span className="calendar-status">{a.status}</span>
    </button>
  </li>)
  return <section aria-label="Appointment calendar" className="appointment-calendar">
    <div className="calendar-toolbar">
      <div className="calendar-filters">
        <label>Calendar view<select value={view} onChange={e => { reset(); setView(e.target.value); setRevision(v => v + 1) }}><option value="list">List</option><option value="day">Day</option><option value="week">Week</option></select></label>
        <label>Calendar date<input type="date" required value={date} onChange={e => changeDate(e.target.value)} /></label>
        <label>Appointment status<select value={status} onChange={e => { reset(); setStatus(e.target.value) }}><option value="all">All statuses</option>{statuses.map(s => <option key={s} value={s}>{s}</option>)}</select></label>
      </div>
      <nav aria-label="Calendar dates"><button className="secondary-button" aria-label={`Previous ${days === 7 ? 'week' : 'day'}`} disabled={!date} onClick={() => changeDate(advance(date, -days))}>Previous</button><button className="secondary-button" onClick={() => changeDate(localDate(new Date(), timezone))}>Today</button><button className="secondary-button" aria-label={`Next ${days === 7 ? 'week' : 'day'}`} disabled={!date} onClick={() => changeDate(advance(date, days))}>Next</button><button className="secondary-button" aria-label="Refresh appointments" onClick={() => { reset(); setRevision(v => v + 1) }}>Refresh</button></nav>
    </div>
    <div className="calendar-window-heading"><h3>{dateLabel(date)}{days === 7 && ` – ${dateLabel(advance(date, 6))}`}</h3><details className="calendar-date-help"><summary>Shop-local times</summary><p>Dates apply separately in each shop’s timezone. Today navigation uses {timezone}. Shops have separate calendar lanes; simultaneous appointments across shops are not conflicts.</p></details></div>
    {error ? <p role="alert">{error}</p> : !data ? <p role="status">Loading appointments…</p> : <>
      <p className="calendar-page-note">{data.appointments.length} appointment(s) on this page.{data.meta.has_more && ' Partial view: more appointments are available on the next page.'}</p>
      {view === 'list' ? (!data.appointments.length ? <p>No appointments on this page.</p> : <ol className="calendar-list">{entries(data.appointments)}</ol>) : <div className="calendar-grid" data-view={view}>{Array.from({ length: days }, (_, i) => advance(date, i)).map(day => <section key={day} aria-label={`${day} schedule`} className="calendar-day" data-empty={!data.appointments.some(a => localDate(new Date(a.starts_at), a.timezone) === day)}><h3><time dateTime={day}>{dateLabel(day)}</time></h3><div className="calendar-lanes">{data.shops.map(shop => {
        const items = data.appointments.filter(a => a.shop_id === shop.id && localDate(new Date(a.starts_at), a.timezone) === day)
        return <section key={shop.id} aria-label={`${shop.name} ${day}`} className="calendar-shop-lane"><h4>{shop.name}<small>{shop.timezone}</small></h4>{items.length ? <ol className="calendar-list">{entries(items)}</ol> : <p className="calendar-empty">No appointments on this page.</p>}</section>
      })}</div></section>)}</div>}

      <nav aria-label="Appointment pagination"><button className="secondary-button" disabled={!cursor} onClick={() => { reset(); setCursor('') }}>First page</button><button className="secondary-button" disabled={!data.meta.has_more || !data.meta.next_cursor} onClick={() => { setData(null); setSelected(null); setCursor(data.meta.next_cursor ?? '') }}>Next page</button></nav>
    </>}
    {selected && !error && <AppointmentDetail key={selected.id} businessId={businessId} onChanged={crewChanged} onDenied={crewDenied} appointment={data?.appointments.find(a => a.id === selected.id) ?? selected} close={() => { setSelected(null); trigger.current?.focus({ preventScroll: true }) }} />}
  </section>
}
function AppointmentDetail({ appointment: a, close, businessId, onChanged, onDenied }: { appointment: Appointment; close: () => void; businessId: number; onChanged: () => void; onDenied: (message: string) => void }) {
  const panel = useRef<HTMLElement | null>(null)
  useEffect(() => { panel.current?.focus() }, [])
  return <section ref={panel} tabIndex={-1} aria-label="Appointment details" className="appointment-detail">
    <header className="calendar-detail-header"><div><p>Appointment details</p><h3>{a.service_name}</h3></div><button className="secondary-button" onClick={close}>Close appointment</button></header>
    <div className="calendar-detail-grid">
      <section aria-label="Appointment schedule"><h4>Schedule</h4><p><time dateTime={a.starts_at}>{dateLabel(localDate(new Date(a.starts_at), a.timezone))} · {time(a.starts_at, a.timezone)}</time> – <time dateTime={a.ends_at}>{dateLabel(localDate(new Date(a.ends_at), a.timezone))} · {time(a.ends_at, a.timezone)}</time></p><p>{a.duration_minutes} minutes · {a.timezone}</p><span className="calendar-status" data-status={a.status}>{a.status}</span></section>
      <section aria-label="Appointment service and vehicle"><h4>Service &amp; vehicle</h4><p>{a.service_name}</p><p>{a.vehicle_make} {a.vehicle_model} · {a.vehicle_size}</p><p>{a.shop_name}</p></section>
      <section aria-label="Appointment staffing"><h4>Staffing</h4><dl className="calendar-detail-facts"><dt>Detailers</dt><dd>{a.crew_size}</dd><dt>Lead Detailer</dt><dd>{a.lead_detailer || 'None designated'}</dd></dl></section>
    </div>
    <details className="calendar-timezone-details"><summary>Timezone details</summary><dl className="calendar-detail-facts"><dt>Shop timezone</dt><dd>{a.timezone}</dd><dt>Start offset</dt><dd>{offset(a.starts_at, a.timezone)}</dd><dt>End offset</dt><dd>{offset(a.ends_at, a.timezone)}</dd></dl></details>
    <AppointmentCrew businessId={businessId} shopId={a.shop_id} appointmentId={a.id} editable={['pending', 'confirmed'].includes(a.status)} onChanged={onChanged} onDenied={onDenied} />
  </section>
}
