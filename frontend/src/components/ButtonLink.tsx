import type { ComponentPropsWithRef } from 'react'
import { Link } from 'react-router-dom'

type ButtonLinkProps = ComponentPropsWithRef<typeof Link> & (
  | { variant: 'primary' | 'secondary'; disabled?: never }
  | { variant: 'booking'; disabled?: boolean }
)

const variantClasses = {
  primary: 'primary-button',
  secondary: 'secondary-button',
  booking: 'book-button',
}

function ButtonLink({
  variant,
  disabled,
  className,
  onClick,
  ...props
}: ButtonLinkProps) {
  return (
    <Link
      {...props}
      className={[
        variantClasses[variant],
        disabled ? 'disabled' : '',
        className,
      ].filter(Boolean).join(' ')}
      aria-disabled={disabled ?? props['aria-disabled']}
      tabIndex={disabled ? -1 : props.tabIndex}
      onClick={(event) => {
        onClick?.(event)
        if (disabled) {
          event.preventDefault()
        }
      }}
    />
  )
}

export default ButtonLink
