import DetailItem from './DetailItem'
import Button from './Button'

type BookingConfirmationProps = {
  appointmentId: number
  customerName: string
  serviceName: string
  vehicleSize: string
  vehicleMake: string
  vehicleModel: string
  date: string
  time: string
  priceCents: number
  durationMinutes: number
  status: string
  onBookAnother: () => void
}

function formatConfirmationDate(date: string) {
  const [year, month, day] = date.split('-').map(Number)

  return new Intl.DateTimeFormat('en-US', {
    month: 'long',
    day: 'numeric',
    year: 'numeric',
    timeZone: 'UTC',
  }).format(
    new Date(Date.UTC(year, month - 1, day))
  )
}

function BookingConfirmation({
  appointmentId,
  customerName,
  serviceName,
  vehicleSize,
  vehicleMake,
  vehicleModel,
  date,
  time,
  priceCents,
  durationMinutes,
  status,
  onBookAnother,
}: BookingConfirmationProps) {
  return (
    <section className="booking-confirmation">
      <div className="confirmation-icon">
        ✓
      </div>

      <p className="confirmation-kicker">
        Appointment Requested
      </p>

      <h1>You're On The Schedule</h1>

      <p className="confirmation-message">
        Thanks, {customerName}! Your Magnum Detailing
        appointment has been submitted!
      </p>

      <div className="confirmation-grid">
        <DetailItem variant="confirmation" label="Service">
          {serviceName}
        </DetailItem>

        <DetailItem variant="confirmation" label="Vehicle Size">
          {vehicleSize}
        </DetailItem>

        <DetailItem variant="confirmation" label="Date">
          {formatConfirmationDate(date)}
        </DetailItem>

        <DetailItem variant="confirmation" label="Time">
          {time}
        </DetailItem>

        <DetailItem variant="confirmation" label="Vehicle">
          {vehicleMake} {vehicleModel}
        </DetailItem>

        <DetailItem variant="confirmation" label="Estimated Time">
          {durationMinutes} min
        </DetailItem>

        <DetailItem variant="confirmation" label="Price">
          ${(priceCents / 100).toFixed(2)}
        </DetailItem>

        <DetailItem variant="confirmation" label="Status" valueClassName="confirmation-status">
          {status}
        </DetailItem>
      </div>

      <p className="confirmation-number">
        Confirmation #{appointmentId}
      </p>

      <Button
        type="button"
        variant="confirmation"
        onClick={onBookAnother}
      >
        Book Another Detail
      </Button>
    </section>
  )
}

export default BookingConfirmation