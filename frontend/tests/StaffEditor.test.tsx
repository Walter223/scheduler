import { afterEach,test,expect,vi } from 'vitest'
import { cleanup,render,screen,fireEvent } from '@testing-library/react'
import { useState } from 'react'
import StaffEditor from '../src/components/StaffEditor'
import type {StaffProposal} from '../src/components/StaffEditor'
afterEach(cleanup)
function Editor(){const [staff,setStaff]=useState<StaffProposal[]>([]);return <StaffEditor staff={staff} locations={[{key:'one',name:'First'},{key:'two',name:'Second'}]} disabled={false} onChange={setStaff}/>}
test('zero staff, independent classification and explicit shop-scoped access',()=>{
  render(<Editor/>);expect(screen.getByText(/Zero staff is valid/)).toBeTruthy()
  fireEvent.click(screen.getByRole('button',{name:'Add proposed employee'}))
  fireEvent.change(screen.getByLabelText('Full name'),{target:{value:'Fictional Manager'}})
  fireEvent.change(screen.getByLabelText('Employment classification'),{target:{value:'business_manager'}})
  expect((screen.getByLabelText('Request business manager access') as HTMLInputElement).checked).toBe(false)
  fireEvent.click(screen.getByLabelText('Request business manager access'))
  expect(screen.getByText(/no operational scheduling authority implied/)).toBeTruthy()
  fireEvent.click(screen.getByRole('button',{name:'Remove proposed employee Fictional Manager'}))
  expect(screen.getByText(/Zero staff is valid/)).toBeTruthy()
})
test('disabled editor cannot offer enabled mutation buttons',()=>{
  render(<StaffEditor staff={[]} locations={[]} disabled onChange={vi.fn()}/> )
  expect((screen.getByRole('button',{name:'Add proposed employee'}).closest('fieldset') as HTMLFieldSetElement).disabled).toBe(true)
})
