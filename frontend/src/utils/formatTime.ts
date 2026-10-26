export function formatTime(time: string) {
  const [hourString, minute] = time.split(':')
  const hour = Number(hourString)

  const period = hour >= 12 ? 'PM' : 'AM'
  const displayHour = hour % 12 || 12

  return `${displayHour}:${minute} ${period}`
}
