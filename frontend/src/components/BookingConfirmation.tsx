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
        <div className="confirmation-item">
          <span>Service</span>
          <strong>{serviceName}</strong>
        </div>

        <div className="confirmation-item">
          <span>Vehicle Size</span>
          <strong>{vehicleSize}</strong>
        </div>

        <div className="confirmation-item">
          <span>Date</span>
          <strong>{formatConfirmationDate(date)}</strong>
        </div>

        <div className="confirmation-item">
          <span>Time</span>
          <strong>{time}</strong>
        </div>

        <div className="confirmation-item">
          <span>Vehicle</span>
          <strong>
            {vehicleMake} {vehicleModel}
          </strong>
        </div>

        <div className="confirmation-item">
          <span>Estimated Time</span>
          <strong>{durationMinutes} min</strong>
        </div>

        <div className="confirmation-item">
          <span>Price</span>
          <strong>
            ${(priceCents / 100).toFixed(2)}
          </strong>
        </div>

        <div className="confirmation-item">
          <span>Status</span>
          <strong className="confirmation-status">
            {status}
          </strong>
        </div>
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