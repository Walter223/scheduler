import {useEffect,useRef,useState} from 'react'
type Guide = {revision:number;history:{action:string;topic:string;revision:number}[];pending?:{topic:string;proposal:Record<string,unknown>}}
const topics: Record<string,string[]>={locations:['locations','defaults'],staff:['employees'],services:['services','catalog'],branding:['branding']}
export default function SetupGuide({businessId,proposal,onRevision,onApproved}:{businessId:number;proposal:Record<string,unknown>;onRevision:(revision:number)=>void;onApproved:()=>void}) {
 const [guide,setGuide]=useState<Guide|null>(null),[topic,setTopic]=useState('locations'),[error,setError]=useState(''),[busy,setBusy]=useState(false)
 const [uncertain,setUncertain]=useState(false)
 const request=useRef<string|null>(null), pending=useRef(false)
 const path=`/api/admin/businesses/${businessId}/onboarding/guide`
 const lifetime=useRef<AbortController|null>(null)
 useEffect(()=>{const controller=new AbortController();lifetime.current=controller;request.current=null;void fetch(path,{cache:'no-store',signal:controller.signal}).then(async r=>{if(!r.ok)throw Error('Guided setup is unavailable. Refresh access.');const {data}=await r.json();if(!Array.isArray(data?.history) || !Number.isInteger(data?.revision))throw Error('Unsupported guide response');if(!controller.signal.aborted)setGuide(data)}).catch(()=>{if(!controller.signal.aborted)setError('Guided setup could not load. Reload to retry.')});return()=>controller.abort()},[path])
 async function send(action:string){
  if(pending.current || !guide)return
  pending.current=true;setBusy(true);setError('')
  const signal=lifetime.current!.signal
  request.current ||= JSON.stringify({action,topic:guide.pending?.topic || topic,proposal:action==='propose'?Object.fromEntries(topics[topic].filter(k=>k in proposal).map(k=>[k,proposal[k]])):null,revision:guide.revision,request_id:crypto.randomUUID()})
  try{
   const me=await (await fetch('/api/me',{cache:'no-store',signal})).json()
   if(!me.authenticated){setGuide(null);throw Error('Session expired. Sign in again.')}
   const response=await fetch(path,{method:'POST',signal,headers:{'Content-Type':'application/json','x-csrf-token':me.csrf_token},body:request.current})
   if(signal.aborted)return
   if(response.status===401 || response.status===403){setGuide(null);request.current=null;throw Error('Guided setup access was removed.')}
   if(!response.ok){request.current=null;if(response.status===409){setGuide(null);throw Error('Revision conflict. Reload setup and review again.')}throw Error('Proposal rejected. Correct the manual editor fields before proposing again.')}
   const {data}=await response.json();if(signal.aborted)return
   const approved=JSON.parse(request.current!).action==='approve';request.current=null;setUncertain(false);setGuide(data);onRevision(data.revision);if(approved)onApproved()
  }catch(e){if(!signal.aborted){setUncertain(!!request.current);setError((e as Error).message || 'Retry the identical request.')}}finally{pending.current=false;if(!signal.aborted)setBusy(false)}
 }
 return <section aria-label="Guided setup assistant"><h3>Guided setup assistant</h3><p>Deterministic guided workflow — no AI model. Edit structured fields below, then propose and explicitly approve changes. Do not enter passwords, tokens or sensitive personal identifiers.</p>{error && <p role="alert">{error}</p>}{guide && <><ol aria-label="Conversation history">{guide.history.map((h,i)=><li key={i}>You: {h.action} {h.topic} · revision {h.revision}</li>)}</ol><p>Guide: Which setup area would you like to review?</p><label>Setup topic<select disabled={busy || !!guide.pending || uncertain} value={guide.pending?.topic || topic} onChange={e=>setTopic(e.target.value)}>{Object.keys(topics).map(t=><option key={t}>{t}</option>)}</select></label>{guide.pending ? <><h4>Proposed {guide.pending.topic} changes — not saved to the onboarding proposal</h4><pre className="guide-proposal">{JSON.stringify(Object.fromEntries(topics[guide.pending.topic].map(k=>[k,guide.pending!.proposal[k]])),null,2)}</pre><button className="admin-button" disabled={busy || uncertain} onClick={()=>send('approve')}>Approve proposed changes</button><button className="admin-button" disabled={busy || uncertain} onClick={()=>send('discard')}>Discard proposal</button></> : <button className="admin-button" disabled={busy || uncertain} onClick={()=>send('propose')}>Propose current editor changes</button>}{uncertain && !busy && <button className="admin-button" onClick={()=>send('propose')}>Retry identical guide request</button>}</>}</section>
}
