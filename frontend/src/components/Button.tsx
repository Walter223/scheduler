import type { ComponentPropsWithRef } from 'react'

type ButtonProps = ComponentPropsWithRef<'button'> & (
  | { variant: 'booking-submit' | 'confirmation'; selected?: never }
  | { variant: 'service-option' | 'time-slot'; selected: boolean }
)

const variantClasses = {
  'booking-submit': 'book-appointment-button',
  confirmation: 'confirmation-button',
  'service-option': 'price-option',
  'time-slot': 'availability-time',
}

function Button({ variant, selected, className, ...props }: ButtonProps) {
  return (
    <button
      {...props}
      className={[
        variantClasses[variant],
        selected ? 'selected' : '',
        className,
      ].filter(Boolean).join(' ')}
      aria-pressed={selected ?? props['aria-pressed']}
    />
  )
}

export default Button
