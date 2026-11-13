import {afterEach,test,expect,vi} from 'vitest'
import {render,screen,cleanup,fireEvent} from '@testing-library/react'
import {useState} from 'react'
import LocationEditor from '../src/components/LocationEditor'
import {locationErrors} from '../src/components/locationDraft'
import type {Location} from '../src/components/LocationEditor'
afterEach(()=>{cleanup();vi.unstubAllGlobals()})
const first={key:'shop-1',existing_shop_id:1,name:'Original shop',timezone:'America/Denver',operating_model:'in_shop'}
function Show(){const [locations,setLocations]=useState<Location[]>([first]);return <LocationEditor locations={locations} defaults={{}} shops={[{id:1,name:'Original shop',timezone:'America/Denver'}]} disabled={false} errors={{}} onChange={setLocations} onDefaults={()=>{}} onZones={()=>{}}/>}
test('first shop stays linked; modes reveal supported mobile planning and preserve inputs',async()=>{
 vi.stubGlobal('fetch',vi.fn(async()=>Response.json({timezones:['America/Denver']})))
 render(<Show/>);expect(screen.getByLabelText('Location name')).toHaveProperty('value','Original shop')
 expect(screen.queryByLabelText('Cities or service areas (one per line)')).toBeNull()
 fireEvent.click(screen.getByRole('radio',{name:/We travel/}))
 fireEvent.change(screen.getByLabelText('Cities or service areas (one per line)'),{target:{value:'Denver'}})
 expect(screen.getByLabelText('Dispatch / base address')).toBeTruthy()
 fireEvent.click(screen.getByRole('radio',{name:/At our shop/}));fireEvent.click(screen.getByRole('radio',{name:/We travel/}))
 expect(screen.getByLabelText('Cities or service areas (one per line)')).toHaveProperty('value','Denver')
 expect(screen.queryByRole('button',{name:/Remove planned location Original/})).toBeNull()
})
test('partial saves differ from required forward validation; zones come from the server catalog',()=>{
 expect(locationErrors([first],{},['America/Denver'],false)).toEqual({})
 expect(locationErrors([first],{},['America/Denver'],true)['shop-1-address']).toBeTruthy()
 const errors=locationErrors([{...first,operating_model:'mobile',timezone:'Invalid/Zone',mobile:{travel_buffer_minutes:241}}],{},['America/Denver'],true)
 for(const field of ['timezone','address','areas','dispatch','buffer'])expect(errors['shop-1-'+field]).toBeTruthy()
})
