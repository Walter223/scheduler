export function isValidName(value: string) {
  const trimmed = value.trim()

  if (!trimmed) {
    return false
  }

  return /^[A-Za-zÀ-ÖØ-öø-ÿ' -]+$/.test(trimmed)
}

export function isValidEmail(value: string) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value.trim())
}
