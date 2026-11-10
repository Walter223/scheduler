import {test,expect,vi,afterEach} from 'vitest'
import {render,screen,fireEvent,cleanup} from '@testing-library/react'
import SetupGuide from '../src/components/SetupGuide'
afterEach(()=>{cleanup();vi.unstubAllGlobals()})
test('structured edits require separate proposal and approval; no free-text chat',async()=>{
 const actions:string[]=[]
 vi.stubGlobal('fetch',vi.fn(async(url:string,opts?:RequestInit)=>{
 if(url==='/api/me')return Response.json({authenticated:true,csrf_token:'masked'})
 if(opts?.method){const body=JSON.parse(String(opts.body));actions.push(body.action);return Response.json({data:{revision:1,history:[],pending:body.action==='propose'?{topic:'branding',proposal:{branding:{display_name:'Fictional'}}}:undefined}})}
 return Response.json({data:{revision:0,history:[]}})
 }))
 const approved=vi.fn()
 render(<SetupGuide businessId={1} proposal={{branding:{display_name:'Fictional'}}} onRevision={()=>{}} onApproved={approved}/>)
 fireEvent.change(await screen.findByLabelText('Setup topic'),{target:{value:'branding'}})
 fireEvent.click(screen.getByRole('button',{name:'Propose current editor changes'}))
 fireEvent.click(await screen.findByRole('button',{name:'Approve proposed changes'}))
 await screen.findByRole('button',{name:'Propose current editor changes'})
 expect(actions).toEqual(['propose','approve']);expect(approved).toHaveBeenCalledOnce()
 expect(screen.queryByRole('textbox')).toBeNull()
})
