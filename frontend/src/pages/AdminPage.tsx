import { useCallback, useEffect, useState } from 'react'
import EmployeeDirectory from '../components/EmployeeDirectory'
import OperationalDashboard from '../components/OperationalDashboard'
import SessionControls from '../components/SessionControls'

type Shop = { id: number; name: string; capabilities: string[] }
type Business = { hr_shops?: { id: number; name: string }[]; id: number; name: string; capabilities: string[]; all_shops: string[]; shops: Shop[] }
const areas = [['dashboard', 'Dashboard'], ['appointments', 'Appointments and calendar'], ['employees', 'Employees and HR'], ['schedules', 'Staff schedules'], ['compensation', 'Compensation'], ['access', 'Access management'], ['settings', 'Business settings']]

function validBusiness(value: unknown): value is Business {
  if (!value || typeof value !== 'object') return false
  const b = value as Business
  const strings = (v: unknown): v is string[] => Array.isArray(v) && v.every(x => typeof x === 'string')
  return Number.isSafeInteger(b.id) && b.id > 0 && typeof b.name === 'string'
    && (b.hr_shops === undefined || (Array.isArray(b.hr_shops) && b.hr_shops.every(s => s && Number.isSafeInteger(s.id) && typeof s.name === 'string'))) && strings(b.capabilities) && strings(b.all_shops) && Array.isArray(b.shops)
    && b.shops.every(s => s && Number.isSafeInteger(s.id) && s.id > 0 && typeof s.name === 'string' && strings(s.capabilities))
}

export default function AdminPage() {
  const [authenticated, setAuthenticated] = useState(false)
  const [businesses, setBusinesses] = useState<Business[]>([])
  const [businessId, setBusinessId] = useState(0)
  const [shopId, setShopId] = useState(0)
  const [area, setArea] = useState('dashboard')
  const [open, setOpen] = useState(false)
  const [state, setState] = useState('')
  const [revision, setRevision] = useState(0)

  const accountChanged = useCallback((value: boolean) => {
    setAuthenticated(value)
    if (!value) { setBusinesses([]); setBusinessId(0); setShopId(0); setArea('dashboard'); setState('') }
  }, [])

  useEffect(() => {
    const controller = new AbortController()
    if (!authenticated) return
    async function load() {
      setBusinesses([])
      setBusinessId(0)
      setShopId(0)
      setArea('dashboard')
      setState('Loading authorized workspaces…')
      try {
        const response = await fetch('/api/admin/context', { signal: controller.signal, cache: 'no-store' })
        if (controller.signal.aborted) return
        if (response.status === 401 || response.status === 403) {
          setState('Access is unavailable. Please sign in again or contact your administrator.')
          return
        }
        if (!response.ok) throw new Error('unavailable')
        const data = await response.json() as { businesses: Business[] }
        if (!Array.isArray(data.businesses) || !data.businesses.every(validBusiness)) throw new Error('invalid context')
        if (controller.signal.aborted) return
        setBusinesses(data.businesses)
        setBusinessId(data.businesses[0]?.id ?? 0)
        setShopId(data.businesses[0]?.shops[0]?.id ?? 0)
        setState(data.businesses.length ? '' : 'No management workspaces are available. Contact your business administrator.')
      } catch {
        if (!controller.signal.aborted) setState('Workspaces are temporarily unavailable. Please retry.')
      }
    }
    void load()
    const refresh = () => setRevision(v => v + 1)
    window.addEventListener('focus', refresh)
    return () => { controller.abort(); window.removeEventListener('focus', refresh) }
  }, [authenticated, revision])

  const business = authenticated ? businesses.find(b => b.id === businessId) : undefined
  const shop = business?.shops.find(s => s.id === shopId)
  const available = business ? Array.from(new Set([...business.capabilities, ...(shop?.capabilities ?? [])])) : []
  return (
    <main className="admin-shell">
      <header className="admin-header"><h1>Magnum Command Center</h1><SessionControls onAuthenticationChange={accountChanged} /></header>
      {!authenticated ? <p>Sign in to view your authorized workspaces. Authentication alone grants no business access.</p> : <>
        <button className="secondary-button admin-menu-toggle" aria-expanded={open} aria-controls="admin-navigation" onClick={() => setOpen(!open)}>Menu</button>
        <div className="admin-layout">
          <aside id="admin-navigation" className={open ? 'admin-sidebar is-open' : 'admin-sidebar'}>
            <label htmlFor="admin-business">Business</label>
            <select id="admin-business" value={businessId} onChange={e => {
              const selected = businesses.find(b => b.id === Number(e.target.value))
              setBusinessId(selected?.id ?? 0); setShopId(selected?.shops[0]?.id ?? 0); setArea('dashboard'); setOpen(false)
            }}><option value={0} disabled>Select a business</option>{businesses.map(b => <option key={b.id} value={b.id}>{b.name}</option>)}</select>
            {business && business.shops.length > 0 && <><label htmlFor="admin-shop">Shop</label><select id="admin-shop" value={shopId} onChange={e => { setShopId(Number(e.target.value)); setArea('dashboard') }}>
              {business.all_shops.length > 0 && <option value={0}>All Shops</option>}
              {business.shops.map(s => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select></>}
            <nav aria-label="Admin areas">{areas.filter(([key]) => (available.includes(key) || (key === 'employees' && available.includes('roster')))).map(([key, name]) => <button key={key} aria-current={area === key ? 'page' : undefined} onClick={() => { setArea(key); setOpen(false) }}>{name}</button>)}</nav>
          </aside>
          <section className="admin-content" aria-label="Workspace">
            {state && <p role="status">{state}</p>}
            {state.startsWith('Access is unavailable') && <a href="/auth/login">Sign in again</a>}
            <button className="secondary-button" onClick={() => setRevision(v => v + 1)}>Refresh access</button>
            {business && <><p>Business: <strong>{business.name}</strong>{shop && <> · Shop: <strong>{shop.name}</strong></>}</p><h2>{areas.find(([key]) => key === area)?.[1]}</h2>{area === 'dashboard' ? (available.includes('appointments') && available.includes('schedules') ? <OperationalDashboard key={`${business.id}:${shopId}`} businessId={business.id} shopId={shopId} /> : <p>Your workspace has no operational scheduling access. Choose a permitted management area.</p>) : area === 'employees' ? <EmployeeDirectory key={`${business.id}:${shopId}`} businessId={business.id} shopId={shopId} hr={business.capabilities.includes('employees')} canManage={business.capabilities.includes('hr_manage')} shops={business.hr_shops ?? []} /> : <p>This area is planned. Management screens are not available yet.</p>}</>}
          </section>
        </div>
      </>}
    </main>
  )
}
