import {useState} from 'react'
import {test,expect,afterEach} from 'vitest'
import {render,screen,fireEvent,cleanup} from '@testing-library/react'
import BrandingEditor from '../src/components/BrandingEditor'
afterEach(cleanup)
test('branding text is escaped, presets and viewport controls remain draft-only',()=>{
 function Editor(){const [value,setValue]=useState<Record<string,string>>({});return <BrandingEditor value={value} disabled={false} onChange={setValue}/>}
 render(<Editor/>);fireEvent.change(screen.getByLabelText('Business display name'),{target:{value:'<script>fictional</script>'}})
 fireEvent.change(screen.getByRole('combobox',{name:'Website style preset'}),{target:{value:'premium'}})
 expect(screen.getByRole('heading',{name:'<script>fictional</script>'})).toBeTruthy()
 fireEvent.click(screen.getByRole('button',{name:'Preview mobile'}));expect(screen.getByRole('button',{name:'Preview desktop'})).toBeTruthy()
 expect(screen.getAllByText(/No real prices or availability/)).toHaveLength(2)
})
