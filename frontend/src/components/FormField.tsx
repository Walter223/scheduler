import type { ReactNode } from 'react'

type FormFieldProps = {
  htmlFor: string
  label: string
  errorId: string
  error?: string
  children: ReactNode
}

function FormField({ htmlFor, label, errorId, error, children }: FormFieldProps) {
  return (
    <>
      <label htmlFor={htmlFor}>{label}</label>
      {children}
      {error && (
        <p id={errorId} className="form-error">
          {error}
        </p>
      )}
    </>
  )
}

export default FormField
