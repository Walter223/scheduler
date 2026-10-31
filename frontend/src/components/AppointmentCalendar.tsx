import { useEffect, useRef, useState } from 'react'
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
  const days = view === 'week' ? 7 : 1
  useEffect(() => {
    const controller = new AbortController()
    async function load() {
      setData(null); setError(''); setSelected(null)
      try {
        const params = new URLSearchParams({ date, days: String(days), status, limit: '50', ...(shopId ? { shop_id: String(shopId) } : {}), ...(cursor ? { cursor } : {}) })
        const response = await fetch(`/api/admin/businesses/${businessId}/calendar?${params}`, { signal: controller.signal, cache: 'no-store' })
        if (controller.signal.aborted) return
        if (!response.ok) { setError(response.status === 401 ? 'Your session has expired. Sign in again.' : response.status === 403 ? 'Appointment access is no longer available.' : response.status === 422 ? 'Choose a valid date and start from the first page.' : 'Appointments are temporarily unavailable.'); return }
        const body = await response.json() as { data: Data }
        const value = body.data
        if (!value || !Array.isArray(value.appointments) || !Array.isArray(value.shops) || !value.meta || typeof value.meta.has_more !== 'boolean' || !(value.meta.next_cursor === null || typeof value.meta.next_cursor === 'string')) throw new Error('invalid page')
        for (const a of value.appointments) {
          if (!a || !Number.isSafeInteger(a.id) || !Number.isSafeInteger(a.shop_id) || !Number.isFinite(Date.parse(a.starts_at)) || !Number.isFinite(Date.parse(a.ends_at)) || !Number.isSafeInteger(a.duration_minutes) || !Number.isSafeInteger(a.crew_size) || a.crew_size < 0 || !statuses.includes(a.status) || ![a.service_name,a.shop_name,a.vehicle_make,a.vehicle_model,a.vehicle_size,a.timezone].every(v => typeof v === 'string') || !(a.lead_detailer === null || typeof a.lead_detailer === 'string')) throw new Error('invalid appointment')
          time(a.starts_at, a.timezone)
        }
        if (!value.shops.every(s => s && Number.isSafeInteger(s.id) && typeof s.name === 'string' && typeof s.timezone === 'string')) throw new Error('invalid shops')
        if (!controller.signal.aborted) setData(value)
      } catch { if (!controller.signal.aborted) setError('Appointments are temporarily unavailable.') }
    }
    void load()
    return () => controller.abort()
  }, [businessId, shopId, date, days, status, cursor, revision])
  function reset() { setData(null); setSelected(null); setCursor('') }
  function changeDate(next: string) { reset(); setDate(next); setRevision(v => v + 1) }
  const entries = (items: Appointment[]) => items.map(a => <li key={a.id} className="calendar-entry">
    <button className="secondary-button" onClick={e => { trigger.current = e.currentTarget; setSelected(a) }}>View {a.service_name} · {time(a.starts_at, a.timezone)} · {a.shop_name}</button>
    <p><time dateTime={a.starts_at}>{localDate(new Date(a.starts_at), a.timezone)} {time(a.starts_at, a.timezone)}</time> – {time(a.ends_at, a.timezone)} ({a.timezone}; {offset(a.starts_at, a.timezone)} → {offset(a.ends_at, a.timezone)}) · {a.duration_minutes} min</p>
    <p>{a.status} · {a.crew_size} Detailer(s){a.lead_detailer ? ` · Lead: ${a.lead_detailer}` : ''}</p>
    {['pending', 'confirmed'].includes(a.status) && a.crew_size === 0 && <strong>Needs staffing</strong>}
  </li>)
  return <section aria-label="Appointment calendar" className="appointment-calendar">
    <div className="employee-filters">
      <label>Calendar view<select value={view} onChange={e => { reset(); setView(e.target.value); setRevision(v => v + 1) }}><option value="list">Chronological list</option><option value="day">Day calendar</option><option value="week">Week calendar</option></select></label>
      <label>Calendar date<input type="date" required value={date} onChange={e => changeDate(e.target.value)} /></label>
      <label>Appointment status<select value={status} onChange={e => { reset(); setStatus(e.target.value) }}><option value="all">All statuses</option>{statuses.map(s => <option key={s} value={s}>{s}</option>)}</select></label>
    </div>
    <nav aria-label="Calendar dates"><button className="secondary-button" disabled={!date} onClick={() => changeDate(advance(date, -days))}>Previous {days === 7 ? 'week' : 'day'}</button><button className="secondary-button" onClick={() => changeDate(localDate(new Date(), timezone))}>Today</button><button className="secondary-button" disabled={!date} onClick={() => changeDate(advance(date, days))}>Next {days === 7 ? 'week' : 'day'}</button><button className="secondary-button" onClick={() => { reset(); setRevision(v => v + 1) }}>Refresh appointments</button></nav>
    <p>Dates apply separately in each shop’s timezone. Today navigation uses {timezone}. Shops have separate calendar lanes; simultaneous appointments across shops are not conflicts.</p>
    {error ? <p role="alert">{error}</p> : !data ? <p role="status">Loading appointments…</p> : <>
      <p>{data.appointments.length} appointment(s) on this page.{data.meta.has_more && ' Partial view: more appointments are available on the next page.'}</p>
      {view === 'list' ? (!data.appointments.length ? <p>No appointments on this page.</p> : <ol className="calendar-list">{entries(data.appointments)}</ol>) : <div className="calendar-grid">{Array.from({ length: days }, (_, i) => advance(date, i)).map(day => <section key={day} aria-label={`${day} schedule`} className="calendar-day"><h3>{day}</h3>{data.shops.map(shop => {
        const items = data.appointments.filter(a => a.shop_id === shop.id && localDate(new Date(a.starts_at), a.timezone) === day)
        return <section key={shop.id} aria-label={`${shop.name} ${day}`}><h4>{shop.name} · {shop.timezone}</h4>{items.length ? <ol className="calendar-list">{entries(items)}</ol> : <p>No appointments on this page.</p>}</section>
      })}</section>)}</div>}
      <nav aria-label="Appointment pagination"><button className="secondary-button" disabled={!cursor} onClick={() => { reset(); setCursor('') }}>First page</button><button className="secondary-button" disabled={!data.meta.has_more || !data.meta.next_cursor} onClick={() => { setData(null); setSelected(null); setCursor(data.meta.next_cursor ?? '') }}>Next page</button></nav>
    </>}
    {selected && !error && <AppointmentDetail appointment={selected} close={() => { setSelected(null); trigger.current?.focus() }} />}
  </section>
}
function AppointmentDetail({ appointment: a, close }: { appointment: Appointment; close: () => void }) {
  const panel = useRef<HTMLElement | null>(null)
  useEffect(() => { panel.current?.focus() }, [])
  return <section ref={panel} tabIndex={-1} aria-label="Appointment details" className="employee-profile"><button className="secondary-button" onClick={close}>Close appointment</button><h3>{a.service_name}</h3><dl className="employee-contact"><dt>Shop</dt><dd>{a.shop_name} · {a.timezone} ({offset(a.starts_at, a.timezone)})</dd><dt>Time</dt><dd>{localDate(new Date(a.starts_at), a.timezone)} {time(a.starts_at, a.timezone)} – {localDate(new Date(a.ends_at), a.timezone)} {time(a.ends_at, a.timezone)}</dd><dt>Duration</dt><dd>{a.duration_minutes} minutes</dd><dt>Status</dt><dd>{a.status}</dd><dt>Vehicle</dt><dd>{a.vehicle_make} {a.vehicle_model} · {a.vehicle_size}</dd><dt>Detailers</dt><dd>{a.crew_size}</dd><dt>Lead Detailer</dt><dd>{a.lead_detailer || 'None designated'}</dd></dl></section>
}
