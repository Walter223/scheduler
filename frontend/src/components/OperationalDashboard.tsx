import { useEffect, useState } from 'react'
type Appointment = { id: number; shop_name: string; timezone: string; starts_at: string; duration_minutes: number; status: string; service_name: string; crew_size: number; lead_detailer: string | null }
type Data = { metrics: { appointments: number; unassigned: number; detailers: number; shifts: number }; appointments: Appointment[]; shops: { id: number; name: string; timezone: string; date: string }[] }
export default function OperationalDashboard({ businessId, shopId }: { businessId: number; shopId: number }) {
  const [data, setData] = useState<Data | null>(null)
  const [error, setError] = useState('')
  const [revision, setRevision] = useState(0)
  useEffect(() => {
    const controller = new AbortController()
    async function load() {
      setData(null)
      setError('')
      try {
        const response = await fetch(`/api/admin/businesses/${businessId}/dashboard${shopId ? `?shop_id=${shopId}` : ''}`, { signal: controller.signal, cache: 'no-store' })
        if (controller.signal.aborted) return
        if (!response.ok) {
          setError(response.status === 401 ? 'Your session has expired. Sign in again.' : response.status === 403 ? 'Operational access is no longer available.' : 'The dashboard is temporarily unavailable.')
          return
        }
        const body = await response.json() as { data: Data }
        const value = body.data
        if (!value || !value.metrics || !Array.isArray(value.appointments) || !Array.isArray(value.shops)
          || !['appointments', 'unassigned', 'detailers', 'shifts'].every(k => Number.isSafeInteger(value.metrics[k as keyof Data['metrics']]) && value.metrics[k as keyof Data['metrics']] >= 0)
          || !value.shops.every(s => s && typeof s.name === 'string' && typeof s.timezone === 'string' && typeof s.date === 'string')
          || !value.appointments.every(a => a && Number.isSafeInteger(a.id) && typeof a.service_name === 'string' && typeof a.shop_name === 'string' && typeof a.timezone === 'string' && Number.isFinite(Date.parse(a.starts_at)) && Number.isSafeInteger(a.duration_minutes) && Number.isSafeInteger(a.crew_size) && a.crew_size >= 0 && ['pending', 'confirmed', 'completed', 'cancelled'].includes(a.status) && (a.lead_detailer === null || typeof a.lead_detailer === 'string'))) throw new Error('invalid dashboard')
        for (const appointment of value.appointments) new Intl.DateTimeFormat('en-US', { timeZone: appointment.timezone }).format(new Date(appointment.starts_at))

        if (!controller.signal.aborted) setData(body.data)
      } catch { if (!controller.signal.aborted) setError('The dashboard is temporarily unavailable.') }
    }
    void load()
    return () => controller.abort()
  }, [businessId, shopId, revision])
  return <section aria-label="Operational dashboard" className="operational-dashboard">
    <div className="dashboard-title"><div><h3>Today at Magnum</h3><p>Staffing and appointments · shop-local dates</p></div><button className="secondary-button" onClick={() => setRevision(v => v + 1)}>Refresh dashboard</button></div>
    {error ? <p role="alert">{error}</p> : !data ? <p role="status">Loading today’s operations…</p> : <>
      <div className="dashboard-metrics">{([['Appointments today', data.metrics.appointments], ['Awaiting staffing', data.metrics.unassigned], ['Detailers scheduled', data.metrics.detailers], ['Active shifts today', data.metrics.shifts]] as const).map(([label, count]) => <div key={label} role="group" aria-label={label}><span>{label}</span><strong>{count}</strong></div>)}</div>
      <p className="dashboard-dates">{data.shops.map(s => `${s.name}: ${s.date} (${s.timezone})`).join(' · ')}</p>
      <h3>Today’s appointments</h3>
      {!data.appointments.length ? <p>No appointments scheduled today.</p> : <ol className="dashboard-appointments">{data.appointments.map(a => <li key={a.id}>
        <div><time dateTime={a.starts_at}>{new Intl.DateTimeFormat('en-US', { timeZone: a.timezone, hour: 'numeric', minute: '2-digit' }).format(new Date(a.starts_at))}</time><span>{a.shop_name}</span></div>
        <div><h4>{a.service_name}</h4><p>{a.duration_minutes} min · <span className="dashboard-status">{a.status}</span></p></div>
        <div><strong>{a.crew_size} {a.crew_size === 1 ? 'Detailer' : 'Detailers'}</strong><p>{a.lead_detailer ? `Lead: ${a.lead_detailer}` : 'No lead designated'}</p></div>
      </li>)}</ol>}
    </>}
  </section>
}
