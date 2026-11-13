import {afterEach,test,expect} from 'vitest'
import {render,screen,cleanup,fireEvent} from '@testing-library/react'
import OnboardingNavigation from '../src/components/OnboardingNavigation'
import {onboardingProgress,onboardingStates} from '../src/components/onboardingProgress'
afterEach(cleanup)
for(const [index,state] of onboardingStates.entries())test(`persisted ${state} maps to one checkpoint`,()=>{
 const d={state,proposal:{employees:[]}}
 const p=onboardingProgress(d)
 expect(p.percent).toBe(Math.round((index===7?6:Math.max(1,Math.min(index,5)))/6*100))
 expect(p.finished).toBe(state==='completed')
 render(<OnboardingNavigation draft={d} selected="Branding" onSelect={()=>{}} />)
 expect(screen.getByRole('progressbar').getAttribute('aria-valuenow')).toBe(String(p.percent))
 expect(screen.getByRole('button',{name:'Branding'}).getAttribute('aria-current')).toBe('step')
 if(index>=3)expect(screen.getByText('Skipped · no team planned')).toBeTruthy()
})
test('visiting and keyboard navigation never save or complete a stage',()=>{
 const d={state:'locations',proposal:{employees:[]}}
 let selected=''
 render(<OnboardingNavigation draft={d} selected="Locations" onSelect={s=>{selected=s}} />)
 fireEvent.click(screen.getByRole('button',{name:'Review'}))
 expect(selected).toBe('Review');expect(screen.getByRole('progressbar').getAttribute('aria-valuenow')).toBe('17')
 expect(screen.getByText('Next: Locations')).toBeTruthy()
})
test('persisted readiness rejects a stale catalog completion',()=>{
 const p=onboardingProgress({state:'review',proposal:{employees:[{}]},readiness:{services_configured:false,branding_configured:false}})
 expect(p.steps.find(s=>s.name==='Services')?.status).toBe('current')
 expect(p.active).toBe('Services');expect(p.nextState).toBe('review')
 expect(p.steps.find(s=>s.name==='Staff')?.status).toBe('complete')
})
