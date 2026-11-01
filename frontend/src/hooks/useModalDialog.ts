import { useEffect, useRef } from 'react'
let openModals = 0
let previousOverflow = ''
/** Native modality, nested scroll locking and return focus; no session/data storage. */
export default function useModalDialog() {
  const dialog = useRef<HTMLDialogElement>(null)
  useEffect(() => {
    const node = dialog.current
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null
    if (openModals++ === 0) { previousOverflow = document.body.style.overflow; document.body.style.overflow = 'hidden' }
    node?.showModal()
    const trap = (event: KeyboardEvent) => {
      if (!node || event.key !== 'Tab' || !(event.target instanceof Element) || event.target.closest('dialog') !== node) return
      const controls = Array.from(node.querySelectorAll<HTMLElement>('a[href], button, input:not([type=hidden]), select, textarea, [tabindex]'))
        .filter(control => control.tabIndex >= 0 && !control.matches(':disabled') && control.getClientRects().length > 0 && getComputedStyle(control).visibility !== 'hidden' && control.closest('dialog') === node)
      const active = document.activeElement
      if (!controls.length) { event.preventDefault(); node.focus(); return }
      if (event.shiftKey && (active === controls[0] || !controls.includes(active as HTMLElement))) {
        event.preventDefault(); controls[controls.length - 1].focus()
      } else if (!event.shiftKey && (active === controls[controls.length - 1] || !controls.includes(active as HTMLElement))) {
        event.preventDefault(); controls[0].focus()
      }
    }
    node?.addEventListener('keydown', trap)
    return () => {
      node?.removeEventListener('keydown', trap)
      node?.close()
      if (--openModals === 0) document.body.style.overflow = previousOverflow
      const destination = opener?.isConnected ? opener : document.getElementById('admin-workspace')
      destination?.focus({ preventScroll: true })
    }
  }, [])
  return dialog
}
