import type { ComponentPropsWithRef, ReactNode } from 'react'

type DetailItemProps = ComponentPropsWithRef<'div'> & {
  variant: 'selected' | 'confirmation'
  label: ReactNode
  children: ReactNode
  valueClassName?: string
}

const variantClasses = {
  selected: 'selected-appointment-item',
  confirmation: 'confirmation-item',
}

function DetailItem({
  variant,
  label,
  children,
  valueClassName,
  className,
  ...props
}: DetailItemProps) {
  return (
    <div
      {...props}
      className={[variantClasses[variant], className].filter(Boolean).join(' ')}
    >
      <span>{label}</span>
      <strong className={valueClassName}>{children}</strong>
    </div>
  )
}

export default DetailItem
