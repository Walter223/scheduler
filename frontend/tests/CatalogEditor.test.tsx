import { useState } from 'react'
import { afterEach, test, expect } from 'vitest'
import { cleanup, render, screen, fireEvent, within } from '@testing-library/react'
import CatalogEditor, { CatalogReview } from '../src/components/CatalogEditor'
import type { CatalogDraft, ServiceDraft } from '../src/components/CatalogEditor'
afterEach(cleanup)
const catalog: CatalogDraft = {version:1,currency:'USD',vehicle_categories:[{key:'car',name:'City car'},{key:'van',name:'Adventure van'}]}
const service: ServiceDraft = {version:2,key:'wash',name:'Custom wash',description:'Draft exterior care',duration_minutes:60,status:'planned',delivery_mode:'in_shop',location_keys:['first','second'],prices:[{category_key:'car',price_cents:12345},{category_key:'van',price_cents:23456}],overrides:[]}
const locations = [{key:'first',name:'First'},{key:'second',name:'Second'}]
function Editor({initial = [], disabled = false}: {initial?: ServiceDraft[]; disabled?: boolean}) {
  const [c, setCatalog] = useState(catalog)
  const [services, setServices] = useState(initial)
  return <><CatalogEditor catalog={c} services={services} locations={locations} disabled={disabled} onChange={(next, rows)=>{setCatalog(next);setServices(rows)}} /><output aria-label="Draft JSON">{JSON.stringify({catalog:c,services})}</output></>
}
const saved = () => JSON.parse(screen.getByLabelText('Draft JSON').textContent!)
test('empty catalog is honestly deferred; optional generic suggestion creates only editable draft intent',()=>{
  render(<Editor />)
  expect(screen.getByText(/Configuration is deferred/)).toBeTruthy()
  fireEvent.click(screen.getByRole('button',{name:'Use exterior-care suggestion'}))
  expect(screen.getByLabelText('Service name')).toHaveProperty('value','Exterior care')
  expect(saved().services[0]).toMatchObject({status:'planned',location_keys:[],prices:[]})
})
test('exact decimal parsing and explicit shop overrides preserve shared prices',()=>{
  render(<Editor initial={[service]} />)
  fireEvent.change(screen.getByLabelText('City car price (USD)'),{target:{value:'19.99'}})
  expect(saved().services[0].prices.find((p:{category_key:string})=>p.category_key==='car').price_cents).toBe(1999)
  fireEvent.change(screen.getByLabelText('City car price (USD)'),{target:{value:'19.999'}})
  expect(saved().services[0].prices.find((p:{category_key:string})=>p.category_key==='car').price_cents).toBe('19.999')
  fireEvent.click(screen.getByLabelText('Customize Second'))
  fireEvent.change(screen.getByLabelText('Duration override (minutes)'),{target:{value:'90'}})
  fireEvent.click(screen.getByLabelText('Override Adventure van price'))
  const overrides = screen.getByRole('group',{name:'Override category prices'})
  fireEvent.change(within(overrides).getByLabelText('Adventure van price (USD)'),{target:{value:'300.05'}})
  expect(saved().services[0].overrides[0]).toMatchObject({location_key:'second',duration_minutes:90,prices:[{category_key:'van',price_cents:30005}]})
  expect(saved().services[0].prices.find((p:{category_key:string})=>p.category_key==='van').price_cents).toBe(23456)
})
test('renames retain category keys; removed category and shop scopes require explicit cleanup',()=>{
  render(<Editor initial={[{...service,overrides:[{location_key:'second',prices:[]}]}]} />)
  fireEvent.change(screen.getByLabelText('Category 1 name'),{target:{value:'Renamed car'}})
  expect(saved().services[0].prices[0].category_key).toBe('car')
  fireEvent.click(screen.getByRole('button',{name:'Remove category Renamed car'}))
  expect(screen.getByText(/Prices reference a removed category/)).toBeTruthy()
  fireEvent.click(screen.getByRole('button',{name:'Clear unavailable category prices'}))
  expect(saved().services[0].prices).toEqual([{category_key:'van',price_cents:23456}])
  fireEvent.click(within(screen.getByRole('group',{name:'Proposed shop availability'})).getByLabelText('Second'))
  expect(screen.getByText(/Override references an unavailable shop/)).toBeTruthy()
  fireEvent.click(screen.getByRole('button',{name:'Clear unavailable shop override'}))
  expect(saved().services[0].overrides).toEqual([])
})
test('editor respects native pending/conflict lock and Review separates intent from publication',()=>{
  render(<Editor initial={[service]} disabled />)
  expect(screen.getByRole('group',{name:'Services & Pricing proposals'})).toHaveProperty('disabled',true)
  cleanup()
  render(<CatalogReview catalog={catalog} services={[service]} locations={locations} />)
  expect(screen.getByText(/City car: \$123.45/)).toBeTruthy()
  expect(screen.getByText(/Mobile booking and catalog publication are unavailable/)).toBeTruthy()
})
