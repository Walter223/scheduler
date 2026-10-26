import DetailItem from '../components/DetailItem'
import FormField from '../components/FormField'
import { useEffect, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'

import BookingConfirmation from '../components/BookingConfirmation'
import Button from '../components/Button'
import ButtonLink from '../components/ButtonLink'
import type {
  Appointment,
  Service,
  BookingForm,
  AvailabilityResponse,
} from '../types/booking'
import { formatTime } from '../utils/formatTime'
import { formatPhoneNumber, isValidPhoneNumber } from '../utils/phone'
import { isValidName, isValidEmail } from '../utils/validation'

function businessDateTimeToUtc(
  date: string,
  time: string
) {
  const [year, month, day] = date.split('-').map(Number)
  const [hour, minute] = time.split(':').map(Number)

  const utcGuess = new Date(
    Date.UTC(year, month - 1, day, hour, minute)
  )

  const formatter = new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/Denver',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hourCycle: 'h23',
  })

  const parts = formatter.formatToParts(utcGuess)

  const getPart = (type: string) =>
    Number(
      parts.find((part) => part.type === type)?.value
    )

  const businessTimeAsUtc = Date.UTC(
    getPart('year'),
    getPart('month') - 1,
    getPart('day'),
    getPart('hour'),
    getPart('minute'),
    getPart('second')
  )

  const offset =
    businessTimeAsUtc - utcGuess.getTime()

  return new Date(
    utcGuess.getTime() - offset
  ).toISOString()
}



function BookingPage() {
  const [searchParams] = useSearchParams()

  const [services, setServices] = useState<Service[]>([])
  const [selectedDate, setSelectedDate] = useState('')
  const [availableTimes, setAvailableTimes] = useState<string[]>([])
  const [availabilityError, setAvailabilityError] = useState('')
  const [selectedTime, setSelectedTime] = useState('')

  const [isSubmitting, setIsSubmitting] = useState(false)
  const [submitError, setSubmitError] = useState('')
  const [slotClaimed, setSlotClaimed] = useState(false)

  const [bookingForm, setBookingForm] = useState<BookingForm>({
    firstName: '',
    lastName: '',
    customerEmail: '',
    customerPhone: '',
    vehicleMake: '',
    vehicleModel: '',
    notes: '',
  })

  const [touchedFields, setTouchedFields] = useState<
    Partial<Record<keyof BookingForm, boolean>>
  >({})

  const markFieldTouched = (field: keyof BookingForm) => {
    setTouchedFields((current) => ({
      ...current,
      [field]: true,
    }))
  }

  const updateBookingForm = (
    field: keyof BookingForm,
    value: string
  ) => {
    setBookingForm((current) => ({
      ...current,
      [field]: value,
    }))
  }

  const now = new Date()

  const today = [
    now.getFullYear(),
    String(now.getMonth() + 1).padStart(2, '0'),
    String(now.getDate()).padStart(2, '0'),
  ].join('-')

  const serviceParam = searchParams.get('service')
  const sizeParam = searchParams.get('size')

  const serviceId = serviceParam ? Number(serviceParam) : null
  const sizeId = sizeParam ? Number(sizeParam) : null

  useEffect(() => {
    fetch('http://localhost:4000/api/services')
      .then((response) => response.json())
      .then((data) => setServices(data))
  }, [])

  const selectedService = services.find(
    (service) => service.id === serviceId
  )

  const selectedPrice = selectedService?.prices.find(
    (price) => price.vehicle_size_id === sizeId
  )

  const servicePriceId = selectedPrice?.service_price_id

  const isBookingFormValid =
    isValidName(bookingForm.firstName) &&
    isValidName(bookingForm.lastName) &&
    isValidEmail(bookingForm.customerEmail) &&
    isValidPhoneNumber(bookingForm.customerPhone) &&
    bookingForm.vehicleMake.trim().length > 0 &&
    bookingForm.vehicleModel.trim().length > 0 &&
    Boolean(selectedDate) &&
    Boolean(selectedTime) &&
    Boolean(servicePriceId)

  const [createdAppointment, setCreatedAppointment] =
    useState<Appointment | null>(null)

  useEffect(() => {
  if (!selectedDate || !servicePriceId) {
    return
  }

  fetch(
    `http://localhost:4000/api/availability?date=${selectedDate}&service_price_id=${servicePriceId}`
  )
    .then(async (response) => {
      const data = await response.json()

      if (!response.ok) {
        throw new Error(
          data.error?.message ?? 'Could not load availability'
        )
      }

      return data as AvailabilityResponse
    })
    .then((data) => {
      setAvailableTimes(data.available_times)
      setAvailabilityError('')
    })
    .catch((error) => {
      setAvailableTimes([])
      setAvailabilityError(error.message)
    })
}, [selectedDate, servicePriceId])

async function handleBookAppointment() {
  if (!isBookingFormValid || !servicePriceId) {
    return
  }

  setIsSubmitting(true)
  setSubmitError('')
  setSlotClaimed(false)

  try {
    const startsAt = businessDateTimeToUtc(
      selectedDate,
      selectedTime
    )

    const response = await fetch(
      'http://localhost:4000/api/appointments',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          service_price_id: servicePriceId,
          starts_at: startsAt,
          customer_name:
            `${bookingForm.firstName.trim()} ${bookingForm.lastName.trim()}`,
          customer_email:
            bookingForm.customerEmail.trim(),
          customer_phone:
            bookingForm.customerPhone.trim(),
          vehicle_make:
            bookingForm.vehicleMake.trim(),
          vehicle_model:
            bookingForm.vehicleModel.trim(),
          notes: bookingForm.notes.trim(),
        }),
      }
    )

    const data = await response.json()

    if (!response.ok) {
      const slotUnavailable = data.errors?.starts_at?.some(
        (message: string) =>
          message === 'is not an available start time' ||
          message === 'is no longer available'
      )

      if (slotUnavailable) {
        setSelectedTime('')
        setAvailableTimes([])

        const availabilityResponse = await fetch(
          `http://localhost:4000/api/availability?date=${selectedDate}&service_price_id=${servicePriceId}`
        )
        const availability = await availabilityResponse.json()

        if (!availabilityResponse.ok) {
          setAvailabilityError('Could not refresh available times. Please choose the date again.')
          throw new Error('That slot is no longer available. Please choose the date again to refresh available times.')
        }

        setAvailableTimes(availability.available_times)
        setAvailabilityError('')
        setSlotClaimed(true)
        return
      }

      const message =
        data.errors?.starts_at?.[0] ??
        'Could not book appointment'

      throw new Error(message)
    }

    setCreatedAppointment(data.appointment)
    
  } catch (error) {
    setSubmitError(
      error instanceof Error
        ? error.message
        : 'Could not book appointment'
    )
  } finally {
    setIsSubmitting(false)
  }
}

  const firstNameInvalid =
    touchedFields.firstName && !isValidName(bookingForm.firstName)

  const lastNameInvalid =
    touchedFields.lastName && !isValidName(bookingForm.lastName)

  const emailInvalid =
    touchedFields.customerEmail &&
    !isValidEmail(bookingForm.customerEmail)

  const phoneInvalid =
    touchedFields.customerPhone &&
    !isValidPhoneNumber(bookingForm.customerPhone)

  const makeInvalid =
    touchedFields.vehicleMake && !bookingForm.vehicleMake.trim()

  const modelInvalid =
    touchedFields.vehicleModel && !bookingForm.vehicleModel.trim()

  if (
    createdAppointment &&
    selectedService &&
    selectedPrice
  ) {
    return (
      <main className="booking-page">
        <BookingConfirmation
          appointmentId={createdAppointment.id}
          customerName={createdAppointment.customer_name}
          serviceName={selectedService.name}
          vehicleSize={selectedPrice.vehicle_size}
          vehicleMake={createdAppointment.vehicle_make}
          vehicleModel={createdAppointment.vehicle_model}
          date={selectedDate}
          time={formatTime(selectedTime)}
          priceCents={createdAppointment.price_cents}
          durationMinutes={createdAppointment.duration_minutes}
          status={createdAppointment.status}
          onBookAnother={() => {
            setCreatedAppointment(null)
            setSelectedDate('')
            setSelectedTime('')
            setAvailableTimes([])
            setAvailabilityError('')
            setSlotClaimed(false)
            setSubmitError('')
            setBookingForm({
              firstName: '',
              lastName: '',
              customerEmail: '',
              customerPhone: '',
              vehicleMake: '',
              vehicleModel: '',
              notes: '',
            })
            setTouchedFields({})
          }}
        />
      </main>
    )
  }

  return (
    <main className="booking-page">
      <h1>Contact & Availability</h1>

      {selectedService && selectedPrice ? (
        <section className="booking-summary">
          <p className="booking-label">Your Selection</p>

          <h2>{selectedService.name}</h2>

          <p className="booking-vehicle">
            {selectedPrice.vehicle_size} Vehicle
          </p>

          <div className="booking-details">
            <div>
              <span>Price</span>

              <strong>
                ${(selectedPrice.price_cents / 100).toFixed(2)}
              </strong>
            </div>

            <div>
              <span>Estimated Time</span>

              <strong>
                {selectedPrice.duration_minutes} min
              </strong>
            </div>

            <div className="booking-date">
              <label htmlFor="booking-date">Choose a Date</label>

              <input
                id="booking-date"
                type="date"
                min={today}
                value={selectedDate}
                onChange={(event) => {
                  const value = event.target.value

                  setSelectedDate(value >= today ? value : '')
                  setSelectedTime('')
                  setAvailableTimes([])
                  setAvailabilityError('')
                  setSlotClaimed(false)
                  setSubmitError('')
                }}
              />
            </div>
          </div>

          {slotClaimed && (
            <p className="form-error" role="alert">
              We apologize, but that slot was just claimed.
              <br />
              Another customer booked this time while you were completing your appointment. We've refreshed the available times below.
            </p>
          )}

          {selectedDate && (
            <div className="availability-times">
              <h3>Available Times</h3>

              {availabilityError && (
                <p className="availability-error">
                  {availabilityError}
                </p>
              )}

              {!availabilityError &&
                availableTimes.map((time) => {
                  const isSelected = selectedTime === time

                  return (
                    <Button
                      key={time}
                      type="button"
                      variant="time-slot"
                      selected={isSelected}
                      onClick={() =>
                        setSelectedTime(isSelected ? '' : time)
                      }
                    >
                      {formatTime(time)}
                    </Button>
                  )
                })}
            </div>
          )}

          {selectedTime && (
            <div className="booking-form">
              <div className="booking-form-section">
                <h3>Customer Information</h3>

                <FormField
                  htmlFor="first-name"
                  label="First Name"
                  errorId="first-name-error"
                  error={
                    firstNameInvalid ? 'Please enter a valid first name' : undefined
                  }
                >
                  <input
                    id="first-name"
                    type="text"
                    value={bookingForm.firstName}
                    aria-invalid={Boolean(firstNameInvalid)}
                    aria-describedby={
                      firstNameInvalid ? 'first-name-error' : undefined
                    }
                    onChange={(event) =>
                      updateBookingForm(
                        'firstName',
                        event.target.value
                      )
                    }
                    onBlur={() => {
                      updateBookingForm(
                        'firstName',
                        bookingForm.firstName.trim()
                      )
                      markFieldTouched('firstName')
                    }}
                  />
                </FormField>

                <FormField
                  htmlFor="last-name"
                  label="Last Name"
                  errorId="last-name-error"
                  error={
                    lastNameInvalid ? 'Please enter a valid last name' : undefined
                  }
                >
                  <input
                    id="last-name"
                    type="text"
                    value={bookingForm.lastName}
                    aria-invalid={Boolean(lastNameInvalid)}
                    aria-describedby={
                      lastNameInvalid ? 'last-name-error' : undefined
                    }
                    onChange={(event) =>
                      updateBookingForm(
                        'lastName',
                        event.target.value
                      )
                    }
                    onBlur={() => {
                      updateBookingForm(
                        'lastName',
                        bookingForm.lastName.trim()
                      )
                      markFieldTouched('lastName')
                    }}
                  />
                </FormField>

                <FormField
                  htmlFor="customer-email"
                  label="Email"
                  errorId="customer-email-error"
                  error={
                    emailInvalid ? 'Please enter a valid email address' : undefined
                  }
                >
                  <input
                    id="customer-email"
                    type="email"
                    value={bookingForm.customerEmail}
                    aria-invalid={Boolean(emailInvalid)}
                    aria-describedby={
                      emailInvalid ? 'customer-email-error' : undefined
                    }
                    onChange={(event) =>
                      updateBookingForm(
                        'customerEmail',
                        event.target.value
                      )
                    }
                    onBlur={() => {
                      updateBookingForm(
                        'customerEmail',
                        bookingForm.customerEmail.trim()
                      )
                      markFieldTouched('customerEmail')
                    }}
                  />
                </FormField>

                <FormField
                  htmlFor="customer-phone"
                  label="Phone"
                  errorId="customer-phone-error"
                  error={
                    phoneInvalid ? 'A valid phone number is required in this field' : undefined
                  }
                >
                  <input
                    id="customer-phone"
                    type="tel"
                    value={bookingForm.customerPhone}
                    aria-invalid={Boolean(phoneInvalid)}
                    aria-describedby={
                      phoneInvalid ? 'customer-phone-error' : undefined
                    }
                    onChange={(event) =>
                      updateBookingForm(
                        'customerPhone',
                        formatPhoneNumber(event.target.value)
                      )
                    }
                    onBlur={() => markFieldTouched('customerPhone')}
                    placeholder="801-555-1234 or +44..."
                  />
                </FormField>
              </div>

              <div className="booking-form-section">
                <h3>Vehicle Information</h3>

                <FormField
                  htmlFor="vehicle-make"
                  label="Make"
                  errorId="vehicle-make-error"
                  error={
                    makeInvalid ? 'Please enter the Make of your vehicle' : undefined
                  }
                >
                  <input
                    id="vehicle-make"
                    type="text"
                    value={bookingForm.vehicleMake}
                    aria-invalid={Boolean(makeInvalid)}
                    aria-describedby={
                      makeInvalid ? 'vehicle-make-error' : undefined
                    }
                    onChange={(event) =>
                      updateBookingForm(
                        'vehicleMake',
                        event.target.value
                      )
                    }
                    onBlur={() => {
                      updateBookingForm(
                        'vehicleMake',
                        bookingForm.vehicleMake.trim()
                      )
                      markFieldTouched('vehicleMake')
                    }}
                  />
                </FormField>

                <FormField
                  htmlFor="vehicle-model"
                  label="Model"
                  errorId="vehicle-model-error"
                  error={
                    modelInvalid ? 'Please enter the model of your vehicle' : undefined
                  }
                >
                  <input
                    id="vehicle-model"
                    type="text"
                    value={bookingForm.vehicleModel}
                    aria-invalid={Boolean(modelInvalid)}
                    aria-describedby={
                      modelInvalid ? 'vehicle-model-error' : undefined
                    }
                    onChange={(event) =>
                      updateBookingForm(
                        'vehicleModel',
                        event.target.value
                      )
                    }
                    onBlur={() => {
                      updateBookingForm(
                        'vehicleModel',
                        bookingForm.vehicleModel.trim()
                      )
                      markFieldTouched('vehicleModel')
                    }}
                  />
                </FormField>

                <label htmlFor="booking-notes">Notes</label>

                <textarea
                  id="booking-notes"
                  value={bookingForm.notes}
                  onChange={(event) =>
                    updateBookingForm('notes', event.target.value)
                  }
                  placeholder="Anything we should know about the vehicle?"
                />
              </div>
            </div>
          )}

          {selectedService && selectedPrice && selectedDate && selectedTime && (
            <section className="selected-appointment-card">
              <p className="selected-appointment-kicker">
                Appointment Selected
              </p>

              <h3 className="selected-appointment-title">
                {selectedService.name}
              </h3>

              <div className="selected-appointment-grid">
                <DetailItem variant="selected" label="Vehicle">
                  {selectedPrice.vehicle_size}
                </DetailItem>

                <DetailItem variant="selected" label="Date">
                  {selectedDate}
                </DetailItem>

                <DetailItem variant="selected" label="Time">
                  {formatTime(selectedTime)}
                </DetailItem>

                <DetailItem variant="selected" label="Price">
                  ${(selectedPrice.price_cents / 100).toFixed(2)}
                </DetailItem>

                <DetailItem variant="selected" label="Estimated Time">
                  {selectedPrice.duration_minutes} min
                </DetailItem>
              </div>
            </section>
          )}
          
          {selectedTime && (
            <>
              <Button
                type="button"
                variant="booking-submit"
                disabled={!isBookingFormValid || isSubmitting}
                onClick={handleBookAppointment}
              >
                {isSubmitting
                  ? 'Booking...'
                  : 'Book Appointment'}
              </Button>

            </>
          )}

          {submitError && (
            <p className="form-error" role="alert">
              {submitError}
            </p>
          )}

          <Link className="change-selection" to="/services">
            ← Change Selection
          </Link>
        </section>
      ) : (
        <section className="booking-summary">
          <p className="booking-label">No Detail Selected</p>

          <h2>Choose Your Detail</h2>

          <p className="booking-vehicle">
            Select a detailing package and vehicle size before
            checking availability.
          </p>

          <ButtonLink variant="booking" to="/services">
            View Services
          </ButtonLink>
        </section>
      )}
    </main>
  )
}

export default BookingPage
