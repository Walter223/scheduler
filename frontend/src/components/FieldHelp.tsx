import {useRef} from 'react'
import type {ReactNode} from 'react'
/** Inline disclosure: no hover dependency, portal or clipped tooltip. */
export default function FieldHelp({label,children}:{label:string;children:ReactNode}) {
 const ref=useRef<HTMLDetailsElement>(null)
 function close(){if(ref.current){ref.current.open=false;ref.current.querySelector('summary')?.focus()}}
 return <details className="field-help" ref={ref} onKeyDown={e=>{if(e.key==='Escape'){e.preventDefault();e.stopPropagation();close()}}}><summary aria-label={`Help: ${label}`}>?</summary><div role="note">{children}<button type="button" onClick={close}>Close help</button></div></details>
}
