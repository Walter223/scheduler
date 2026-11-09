import { afterEach, test, expect, vi } from 'vitest'
import { cleanup, render, screen, fireEvent, waitFor } from '@testing-library/react'
import SetupWorkspace from '../src/components/SetupWorkspace'
const draft = {schema_version:1,revision:0,state:'provisioning_complete',proposal:{locations:[],defaults:{},employees:[],services:[],branding:{}},applied:{shops:[{id:1,name:'Main',timezone:'America/Denver'}]}}
afterEach(()=>{cleanup();vi.unstubAllGlobals()})
test('loads existing shop without duplicating it and leaves planned areas honest',async()=>{
  vi.stubGlobal('fetch',vi.fn(async()=>Response.json({data:draft})))
  render(<SetupWorkspace businessId={1}/>);await screen.findByText('Saved setup loaded.')
  fireEvent.click(screen.getByRole('button',{name:'Configure Main'}))
  expect((screen.getByRole('button',{name:'Configure Main'}) as HTMLButtonElement).disabled).toBe(true)
  fireEvent.click(screen.getByRole('button',{name:'Locations'}))
  expect(screen.getByLabelText('Shop name')).toBeTruthy()
  fireEvent.click(screen.getByRole('button',{name:'Staff · Planned'}))
  expect(screen.getByText(/Staff editing is not implemented/)).toBeTruthy()
})
for (const status of [401,403]) test(`denied ${status} clears private draft`,async()=>{
  vi.stubGlobal('fetch',vi.fn(async()=>new Response(null,{status})))
  render(<SetupWorkspace businessId={1}/>);await screen.findByText(/Setup access is unavailable/)
  expect(screen.queryByText('Main')).toBeNull()
})
test('revision conflict requires explicit reload',async()=>{
  vi.stubGlobal('fetch',vi.fn(async(url:string,opts?:RequestInit)=>url==='/api/me'?Response.json({authenticated:true,csrf_token:'masked'}):opts?.method?new Response(null,{status:409}):Response.json({data:draft})))
  render(<SetupWorkspace businessId={1}/>);await screen.findByText('Saved setup loaded.')
  fireEvent.click(screen.getByRole('button',{name:'Save draft'}))
  await screen.findByText(/Another save changed/)
  expect((screen.getByRole('button',{name:'Save draft'}) as HTMLButtonElement).disabled).toBe(true)
})
test('uncertain save retries exact request without editing',async()=>{
  const bodies:string[]=[]
  vi.stubGlobal('fetch',vi.fn(async(url:string,opts?:RequestInit)=>{
    if(url==='/api/me')return Response.json({authenticated:true,csrf_token:'masked'})
    if(opts?.method){bodies.push(String(opts.body));throw Error('network')}
    return Response.json({data:draft})
  }))
  render(<SetupWorkspace businessId={1}/>);await screen.findByText('Saved setup loaded.')
  fireEvent.click(screen.getByRole('button',{name:'Save draft'}))
  fireEvent.click(await screen.findByRole('button',{name:'Retry identical save'}))
  await waitFor(()=>expect(bodies.length).toBe(2));expect(bodies[0]).toBe(bodies[1])
})
test('business switch rejects late response',async()=>{
  let resolve!:(r:Response)=>void
  vi.stubGlobal('fetch',vi.fn((url:string)=>url.includes('/1/')?new Promise<Response>(r=>{resolve=r}):Promise.resolve(Response.json({data:{...draft,applied:{shops:[]}}}))))
  const view=render(<SetupWorkspace businessId={1}/>);view.rerender(<SetupWorkspace businessId={2}/> )
  await screen.findByText('Saved setup loaded.');resolve(Response.json({data:draft}))
  await waitFor(()=>expect(screen.queryByRole('button',{name:'Configure Main'})).toBeNull())
})
