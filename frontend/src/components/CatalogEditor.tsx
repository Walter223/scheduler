import { useState } from 'react'

export type CatalogDraft = {version: number; currency: string; vehicle_categories: {key: string; name: string}[]}
type Price = {category_key: string; price_cents: number | string}
type Override = {location_key: string; prices: Price[]; duration_minutes?: number; delivery_mode?: string; status?: string}
export type ServiceDraft = {
  version: number; key: string; name: string; description: string; duration_minutes: number
  status: string; delivery_mode: string; location_keys: string[]; prices: Price[]; overrides: Override[]
}
type Location = {key: string; name: string}

function MoneyField({label, cents, onChange}: {label: string; cents: number | string | undefined; onChange: (cents: number | string)=>void}) {
  const [text, setText] = useState(typeof cents === 'number' ? `${Math.floor(cents / 100)}.${String(cents % 100).padStart(2, '0')}` : cents || '')
  return <label>{label}<input inputMode="decimal" placeholder="0.00" value={text} onChange={event => {
    const value = event.target.value
    setText(value)
    // Parse decimal text into exact integer cents; never round floating point money.
    if (/^\d{1,7}(\.\d{0,2})?$/.test(value)) {
      const [whole, fraction = ''] = value.split('.')
      onChange(Number(whole) * 100 + Number(fraction.padEnd(2, '0')))
    } else onChange(value)
  }} /></label>
}

export default function CatalogEditor({catalog, services, locations, disabled, onChange}: {
  catalog: CatalogDraft; services: ServiceDraft[]; locations: Location[]; disabled: boolean
  onChange: (catalog: CatalogDraft, services: ServiceDraft[])=>void
}) {
  function change(index: number, service: ServiceDraft) { onChange(catalog, services.map((s, i)=>i === index ? service : s)) }
  function add(suggestion = false) {
    onChange(catalog, [...services, {version: 2, key: `service-${crypto.randomUUID()}`, name: suggestion ? 'Exterior care' : '', description: suggestion ? 'Exterior wash and finish' : '', duration_minutes: 60, status: 'planned', delivery_mode: 'in_shop', location_keys: [], prices: [], overrides: []}])
  }
  function prices(label: string, value: Price[], update: (prices: Price[])=>void, override = false) {
    return <fieldset><legend>{label}</legend>{catalog.vehicle_categories.map(category => {
      const current = value.find(p=>p.category_key === category.key)
      return <div key={category.key} className="setup-price-row">
        {override && <label><input type="checkbox" checked={!!current} onChange={e=>update(e.target.checked ? [...value, {category_key: category.key, price_cents: ''}] : value.filter(p=>p.category_key !== category.key))} />Override {category.name || 'unnamed category'} price</label>}
        {(!override || current) && <MoneyField label={`${category.name || 'Unnamed category'} price (USD)`} cents={current?.price_cents} onChange={price_cents=>update([...value.filter(p=>p.category_key !== category.key), {category_key: category.key, price_cents}])} />}
      </div>
    })}{value.some(p=>!catalog.vehicle_categories.some(c=>c.key === p.category_key)) && <p role="alert">Prices reference a removed category. <button className="admin-button" onClick={()=>update(value.filter(p=>catalog.vehicle_categories.some(c=>c.key === p.category_key)))}>Clear unavailable category prices</button></p>}</fieldset>
  }
  return <fieldset className="setup-catalog" disabled={disabled}><legend>Services &amp; Pricing proposals</legend>
    <p>Draft only. Offering status expresses intent; nothing is published or changes customer prices. Mobile services remain unbookable until travel-aware scheduling is implemented and explicitly enabled.</p>
    <fieldset><legend>Vehicle categories</legend><p>Name your own categories. Every proposed service needs a positive shared USD price for each category.</p>
      {catalog.vehicle_categories.map((c, i)=><div className="setup-category" key={c.key}><label>Category {i + 1} name<input maxLength={255} value={c.name} onChange={e=>onChange({...catalog, vehicle_categories: catalog.vehicle_categories.map(v=>v.key === c.key ? {...v, name: e.target.value} : v)}, services)} /></label><button className="admin-button" onClick={()=>onChange({...catalog, vehicle_categories: catalog.vehicle_categories.filter(v=>v.key !== c.key)}, services)}>Remove category {c.name || i + 1}</button></div>)}
      <button className="admin-button" onClick={()=>onChange({...catalog, vehicle_categories: [...catalog.vehicle_categories, {key: `category-${crypto.randomUUID()}`, name: ''}]}, services)}>Add vehicle category</button>
    </fieldset>
    {services.length === 0 && <p>No services proposed. Configuration is deferred and is not complete. You can save and return later.</p>}
    {services.map((s, i)=><fieldset key={s.key} aria-label={`Service proposal ${i + 1}`}><legend>{s.name || `Service ${i + 1}`}</legend><div className="setup-grid">
      <label>Service name<input maxLength={255} value={s.name} onChange={e=>change(i, {...s, name: e.target.value})} /></label>
      <label>Description<textarea maxLength={2000} value={s.description} onChange={e=>change(i, {...s, description: e.target.value})} /></label>
      <label>Estimated duration (minutes)<input type="number" min={1} max={1440} value={s.duration_minutes || ''} onChange={e=>change(i, {...s, duration_minutes: Number(e.target.value)})} /></label>
      <label>Offering status<select value={s.status} onChange={e=>change(i, {...s, status: e.target.value})}><option value="planned">Planned offering</option><option value="active">Intended active offering (draft only)</option></select></label>
      <label>Delivery mode<select value={s.delivery_mode} onChange={e=>change(i, {...s, delivery_mode: e.target.value})}><option value="in_shop">In-shop</option><option value="mobile">Mobile</option><option value="both">Both</option></select></label>
    </div>
      <fieldset><legend>Proposed shop availability</legend>{locations.map(l=><label key={l.key}><input type="checkbox" checked={s.location_keys.includes(l.key)} onChange={e=>change(i, {...s, location_keys: e.target.checked ? [...s.location_keys, l.key] : s.location_keys.filter(k=>k !== l.key)})} />{l.name || l.key}</label>)}{s.location_keys.filter(k=>!locations.some(l=>l.key === k)).map(k=><p key={k} role="alert">Unavailable location: {k}. <button className="admin-button" onClick={()=>change(i, {...s, location_keys: s.location_keys.filter(v=>v !== k)})}>Clear unavailable service location</button></p>)}</fieldset>
      {prices('Shared category prices', s.prices, value=>change(i, {...s, prices: value}))}
      <fieldset><legend>Shop overrides</legend><p>Unchanged fields inherit the shared duration, offering status, delivery mode and category prices.</p>{locations.filter(l=>s.location_keys.includes(l.key)).map(l=>{
        const local = s.overrides.find(o=>o.location_key === l.key)
        function update(next: Override) { change(i, {...s, overrides: s.overrides.map(o=>o.location_key === l.key ? next : o)}) }
        return <fieldset key={l.key}><legend>{l.name || l.key}</legend><label><input type="checkbox" checked={!!local} onChange={e=>change(i, {...s, overrides: e.target.checked ? [...s.overrides, {location_key: l.key, prices: []}] : s.overrides.filter(o=>o.location_key !== l.key)})} />Customize {l.name || l.key}</label>{local && <><div className="setup-grid"><label>Duration override (minutes)<input type="number" min={1} max={1440} placeholder="Inherit shared duration" value={local.duration_minutes ?? ''} onChange={e=>{const next = {...local}; if (e.target.value) next.duration_minutes = Number(e.target.value); else delete next.duration_minutes; update(next)}} /></label><label>Delivery override<select value={local.delivery_mode || ''} onChange={e=>{const next = {...local}; if (e.target.value) next.delivery_mode = e.target.value; else delete next.delivery_mode; update(next)}}><option value="">Inherit shared mode</option><option value="in_shop">In-shop</option><option value="mobile">Mobile</option><option value="both">Both</option></select></label><label>Offering override<select value={local.status || ''} onChange={e=>{const next = {...local}; if (e.target.value) next.status = e.target.value; else delete next.status; update(next)}}><option value="">Inherit shared status</option><option value="planned">Planned</option><option value="active">Intended active (draft only)</option></select></label></div>{prices('Override category prices', local.prices, value=>update({...local, prices: value}), true)}</>}</fieldset>
      })}{s.overrides.filter(o=>!s.location_keys.includes(o.location_key) || !locations.some(l=>l.key === o.location_key)).map(o=><p key={o.location_key} role="alert">Override references an unavailable shop. <button className="admin-button" onClick={()=>change(i, {...s, overrides: s.overrides.filter(v=>v.location_key !== o.location_key)})}>Clear unavailable shop override</button></p>)}</fieldset>
      <button className="admin-button" onClick={()=>onChange(catalog, services.filter((_, n)=>n !== i))}>Remove proposed service {s.name || i + 1}</button>
    </fieldset>)}
    <div className="setup-actions"><button className="admin-button" onClick={()=>add()}>Add proposed service</button><button className="admin-button" onClick={()=>add(true)}>Use exterior-care suggestion</button></div><p>Suggestions are generic draft text, never a copied tenant catalog. Set your own categories, shops and prices before saving.</p>
  </fieldset>
}

export function CatalogReview({catalog, services, locations}: {catalog: CatalogDraft; services: ServiceDraft[]; locations: Location[]}) {
  const money = (cents: number | string) => typeof cents === 'number' ? new Intl.NumberFormat('en-US', {style: 'currency', currency: 'USD'}).format(cents / 100) : 'Price missing or invalid'
  const shop = (key: string) => locations.find(l=>l.key === key)?.name || `Missing ${key}`
  const category = (key: string) => catalog.vehicle_categories.find(c=>c.key === key)?.name || `Missing ${key}`
  return <section aria-label="Catalog review"><h4>Proposed catalog · USD</h4>{services.length === 0 ? <p>Services deferred — not complete.</p> : <ul>{services.map(s=><li key={s.key}><strong>{s.name || 'Service name missing'}</strong> · {s.status} (draft only) · {s.duration_minutes} minutes · {s.delivery_mode.replaceAll('_', ' ')}<p>{s.description || 'Description missing'}</p><p>Shops: {s.location_keys.map(shop).join(', ') || 'None selected'}</p><p>Shared prices: {s.prices.map(p=>`${category(p.category_key)}: ${money(p.price_cents)}`).join('; ') || 'Missing'}</p>{s.overrides.map(o=><p key={o.location_key}>{shop(o.location_key)} overrides: {o.duration_minutes ? `${o.duration_minutes} minutes; ` : ''}{o.delivery_mode || 'shared mode'}; {o.status || 'shared status'}; {o.prices.map(p=>`${category(p.category_key)}: ${money(p.price_cents)}`).join('; ') || 'shared prices'}</p>)}</li>)}</ul>}<p>Unapplied proposals. Mobile booking and catalog publication are unavailable.</p></section>
}
