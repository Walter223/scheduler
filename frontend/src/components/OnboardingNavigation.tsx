import {onboardingProgress} from './onboardingProgress'
import type {ProgressDraft,SetupStep} from './onboardingProgress'
import './onboarding-navigation.css'
export default function OnboardingNavigation({draft,selected,onSelect}:{draft:ProgressDraft;selected:SetupStep;onSelect:(step:SetupStep)=>void}){
 const progress=onboardingProgress(draft)
 const names={Business:'Your business',Locations:'Locations',Staff:'Your team',Services:'Services & pricing',Branding:'Branding',Review:'Review & finish'}
 const status={complete:'Completed',skipped:'Skipped · no team planned',current:'Next required',incomplete:'Incomplete'}
 return <div className="onboarding-navigation">
  <div className="onboarding-progress-heading"><div><p className="onboarding-eyebrow">YOUR BUSINESS SETUP</p><h2>{progress.finished?'Draft review complete':draft.state==='ready_to_publish'?'Next: Finish setup review':`Next: ${names[progress.active]}`}</h2></div><span>{progress.percent}%</span></div>
  <div role="progressbar" aria-label="Saved setup progress" aria-valuemin={0} aria-valuemax={100} aria-valuenow={progress.percent} aria-valuetext={`${progress.resolved} of 6 stages resolved; unpublished draft`} className="onboarding-track"><span style={{width:`${progress.percent}%`}} /></div>
  <p className="onboarding-announcement" aria-live="polite" aria-atomic="true">{progress.finished?'Setup review is saved. Your website is not published.':`${progress.resolved} of 6 stages resolved. Progress changes only after an authorized save.`}</p>
  <nav aria-label="Setup steps"><ol>{progress.steps.map((step,index)=><li key={step.name} data-status={step.status}><button type="button" aria-label={step.name} aria-current={selected===step.name?'step':undefined} onClick={()=>onSelect(step.name)} aria-describedby={`setup-step-${step.name}`}><span className="onboarding-step-icon" aria-hidden="true">{step.status==='complete'?'✓':step.status==='skipped'?'−':index+1}</span><span>{names[step.name]}<small id={`setup-step-${step.name}`}>{status[step.status]}</small></span></button></li>)}</ol></nav>
  <p className="onboarding-context">Viewing {names[selected]}. {selected!==progress.active&&!progress.finished?`Next required: ${names[progress.active]}. `:''}Saved proposals remain separate from live business configuration.</p>
 </div>
}
