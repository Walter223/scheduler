export const customer = {
  'First Name': 'Alex',
  'Last Name': 'Driver',
  Email: 'alex@example.com',
  Phone: '303-555-0100',
  Make: 'Toyota',
  Model: 'Camry',
  Notes: 'Please call on arrival.',
}

export function gate() {
  let release = () => {}
  const promise = new Promise<void>((resolve) => { release = resolve })
  return { promise, release }
}

export function followingWeek(date: string) {
  const next = new Date(`${date}T12:00:00Z`)
  next.setUTCDate(next.getUTCDate() + 7)
  return next.toISOString().slice(0, 10)
}
