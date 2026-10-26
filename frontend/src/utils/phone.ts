export function formatPhoneNumber(value: string) {
  const trimmed = value.trimStart()

  // International number: keep the + and up to 15 digits.
  if (trimmed.startsWith('+')) {
    const digits = trimmed
      .slice(1)
      .replace(/\D/g, '')
      .slice(0, 15)

    return `+${digits}`
  }

  // US number: format as 801-555-1234 or 1-801-555-1234.
  let digits = trimmed.replace(/\D/g, '').slice(0, 11)

  if (digits.length === 11 && digits.startsWith('1')) {
    return `${digits.slice(0, 1)}-${digits.slice(1, 4)}-${digits.slice(4, 7)}-${digits.slice(7)}`
  }

  if (digits.length > 10) {
    digits = digits.slice(0, 10)
  }

  if (digits.length > 6) {
    return `${digits.slice(0, 3)}-${digits.slice(3, 6)}-${digits.slice(6)}`
  }

  if (digits.length > 3) {
    return `${digits.slice(0, 3)}-${digits.slice(3)}`
  }

  return digits
}

export function isValidPhoneNumber(value: string) {
  const trimmed = value.trim()

  if (trimmed.startsWith('+')) {
    const digits = trimmed.replace(/\D/g, '')

    return digits.length >= 7 && digits.length <= 15
  }

  const digits = trimmed.replace(/\D/g, '')

  return (
    digits.length === 10 ||
    (digits.length === 11 && digits.startsWith('1'))
  )
}
