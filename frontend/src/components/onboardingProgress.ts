export const onboardingStates = ['provisioning_complete','locations','employees','services_pricing','branding','review','ready_to_publish','completed'] as const
export const setupSteps = ['Business','Locations','Staff','Services','Branding','Review'] as const
export type SetupStep = typeof setupSteps[number]
export type ProgressDraft = {state:string;proposal:{employees:unknown[]};readiness?:{services_configured:boolean;branding_configured:boolean}}
export function onboardingProgress(draft:ProgressDraft){
 const checkpoint=onboardingStates.indexOf(draft.state as typeof onboardingStates[number])
 const checkpointStep=setupSteps[Math.min(Math.max(checkpoint,0),5)]
 const steps=setupSteps.map((name,index)=>{
  let resolved=index===0 || (index<5 ? checkpoint>index : checkpoint===7)
  if(index===3 && draft.readiness?.services_configured===false)resolved=false
  if(index===4 && draft.readiness?.branding_configured===false)resolved=false
  const status=resolved ? name==='Staff' && draft.proposal.employees.length===0 ? 'skipped' : 'complete' : name===checkpointStep ? 'current' : 'incomplete'
  return {name,status} as const
 })
 const repair=steps.find(s=>s.status==='incomplete' && setupSteps.indexOf(s.name)<checkpoint)
 const active=repair?.name || checkpointStep
 if(repair)steps[setupSteps.indexOf(repair.name)]={...repair,status:'current'}
 const resolved=steps.filter(s=>s.status==='complete'||s.status==='skipped').length
 return {steps,active,percent:Math.round(resolved/steps.length*100),resolved,finished:draft.state==='completed',nextState:repair ? draft.state : onboardingStates[checkpoint+1]}
}
