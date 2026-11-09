import { afterEach, test, expect, vi } from 'vitest'
import { cleanup, render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'
import App from '../src/App'
afterEach(()=>{cleanup();vi.unstubAllGlobals()})
function mount(path:string){vi.stubGlobal('scrollTo',vi.fn());render(<MemoryRouter initialEntries={[path]}><App/></MemoryRouter>)}
test('platform landing separates business signup and customer booking without session fetch',()=>{
  const fetcher=vi.fn();vi.stubGlobal('fetch',fetcher);mount('/platform')
  expect(screen.getByRole('link',{name:'Create a Business'}).getAttribute('href')).toBe('/signup')
  expect(screen.getByRole('link',{name:'Sign In'}).getAttribute('href')).toBe('/admin')
  expect(screen.queryByRole('navigation')).toBeNull()
  expect(fetcher).not.toHaveBeenCalled()
})
test('signed-out Setup deep link has no privileged context or draft request',async()=>{
  const fetcher=vi.fn(async()=>Response.json({authenticated:false,user:null,csrf_token:null}));vi.stubGlobal('fetch',fetcher);mount('/setup/10')
  await screen.findByRole('link',{name:'Staff sign in'})
  expect(fetcher).toHaveBeenCalledTimes(1)
  expect(screen.queryByRole('navigation',{name:'Admin areas'})).toBeNull()
})
test('unauthorized business selector never falls back to another business draft',async()=>{
  const fetcher=vi.fn(async(url:string)=>url==='/api/me'?Response.json({authenticated:true,user:{id:1,email:'owner@example.invalid'},csrf_token:'masked'}):Response.json({businesses:[{id:1,name:'Permitted',capabilities:['setup'],all_shops:[],shops:[]}]}))
  vi.stubGlobal('fetch',fetcher);mount('/setup/999')
  await screen.findByText(/No management workspaces/)
  expect(fetcher).toHaveBeenCalledTimes(2)
  expect(screen.queryByRole('region',{name:'Business setup'})).toBeNull()
})
