import DetailItem from '../components/DetailItem'
import FormField from '../components/FormField'
import { useEffect, useRef, useState } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router-dom'

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

function businessDateParts(value: Date) {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/Denver',
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(value)
  const part = (type: string) => parts.find((entry) => entry.type === type)?.value
  return {
    date: `${part('year')}-${part('month')}-${part('day')}`,
    time: `${part('hour')}:${part('minute')}`,
  }
}

function isServiceCatalog(value: unknown): value is Service[] {
  const record = (item: unknown): item is Record<string, unknown> =>
    typeof item === 'object' && item !== null
  const number = (item: unknown) => typeof item === 'number' && Number.isFinite(item)

  return Array.isArray(value) && value.every((service: unknown) =>
    record(service) && number(service.id) && typeof service.name === 'string' &&
    typeof service.description === 'string' && Array.isArray(service.prices) &&
    service.prices.every((price: unknown) => record(price) &&
      number(price.service_price_id) && number(price.vehicle_size_id) &&
      number(price.price_cents) && number(price.duration_minutes) &&
      typeof price.vehicle_size === 'string')
  )
}

function bookingErrorMessage(errors: unknown) {
  if (!errors || typeof errors !== 'object') return 'Could not book appointment'

  const labels: Record<string, string> = {
    customer_first_name: 'First name', customer_last_name: 'Last name', customer_email: 'Email', customer_phone: 'Phone',
    vehicle_make: 'Vehicle make', vehicle_model: 'Vehicle model', notes: 'Notes',
    starts_at: 'Appointment time', service_price_id: 'Selected service',
  }
  const messages = Object.entries(errors).flatMap(([field, values]) =>
    Array.isArray(values) ? values.filter((value) => typeof value === 'string')
      .map((value) => `${labels[field] ?? field.replaceAll('_', ' ')}: ${value}`) : []
  )
  return messages.join('. ') || 'Could not book appointment'
}

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
  const navigate = useNavigate()
  const [searchParams] = useSearchParams()

  const [services, setServices] = useState<Service[]>([])
  const [servicesLoading, setServicesLoading] = useState(true)
  const [servicesError, setServicesError] = useState('')
  const availabilityScope = useRef<AbortController | null>(null)
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

  const today = businessDateParts(new Date()).date

  const serviceParam = searchParams.get('service')
  const sizeParam = searchParams.get('size')

  const serviceId = serviceParam ? Number(serviceParam) : null
  const sizeId = sizeParam ? Number(sizeParam) : null

  useEffect(() => {
    const controller = new AbortController()
    fetch('/api/services', { signal: controller.signal })
      .then(async (response) => {
        if (!response.ok) throw new Error('Could not load detailing services. Please reload the page to try again.')
        const data: unknown = await response.json().catch(() => {
          throw new Error('The service catalog could not be read. Please reload the page to try again.')
        })
        if (!isServiceCatalog(data)) throw new Error('The service catalog could not be read. Please reload the page to try again.')
        return data
      })
      .then((data) => {
        if (!controller.signal.aborted) setServices(data)
      })
      .catch((error: unknown) => {
        if (!controller.signal.aborted) {
          setServicesError(error instanceof Error && !(error instanceof TypeError)
            ? error.message
            : 'Could not load detailing services. Please reload the page to try again.')
        }
      })
      .finally(() => {
        if (!controller.signal.aborted) setServicesLoading(false)
      })
    return () => controller.abort()
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
    const controller = new AbortController()
    availabilityScope.current = controller
    if (selectedDate && servicePriceId) {
      fetch(
        `/api/availability?date=${selectedDate}&service_price_id=${servicePriceId}`,
        { signal: controller.signal }
      )
        .then(async (response) => {
          const data = await response.json()
          if (!response.ok) throw new Error(data.error?.message ?? 'Could not load availability')
          return data as AvailabilityResponse
        })
        .then((data) => {
          if (controller.signal.aborted) return
          setAvailableTimes(data.available_times)
          setAvailabilityError('')
        })
        .catch((error: unknown) => {
          if (controller.signal.aborted) return
          setAvailableTimes([])
          setAvailabilityError(error instanceof Error ? error.message : 'Could not load availability')
        })
    }
    // Initial availability and conflict refreshes share this selection's lifetime.
    return () => controller.abort()
  }, [selectedDate, servicePriceId])

async function handleBookAppointment() {
  if (!isBookingFormValid || !servicePriceId || isSubmitting) {
    return
  }

  const scope = availabilityScope.current
  if (!scope) return
  const selectionIsCurrent = () =>
    !scope.signal.aborted && availabilityScope.current === scope

  setIsSubmitting(true)
  setSubmitError('')
  setSlotClaimed(false)

  try {
    const startsAt = businessDateTimeToUtc(
      selectedDate,
      selectedTime
    )

    const response = await fetch(
      '/api/appointments',
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          service_price_id: servicePriceId,
          starts_at: startsAt,
          customer_first_name: bookingForm.firstName.trim(),
          customer_last_name: bookingForm.lastName.trim(),
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
      if (!selectionIsCurrent()) return
      const slotUnavailable = data.errors?.starts_at?.some(
        (message: string) =>
          message === 'is not an available start time' ||
          message === 'is no longer available'
      )

      if (slotUnavailable) {
        setSelectedTime('')
        setAvailableTimes([])

        const availabilityResponse = await fetch(
          `/api/availability?date=${selectedDate}&service_price_id=${servicePriceId}`,
          { signal: scope.signal }
        )
        const availability = await availabilityResponse.json()
        if (!selectionIsCurrent()) return

        if (!availabilityResponse.ok) {
          setAvailabilityError('Could not refresh available times. Please choose the date again.')
          throw new Error('That slot is no longer available. Please choose the date again to refresh available times.')
        }

        setAvailableTimes(availability.available_times)
        setAvailabilityError('')
        setSlotClaimed(true)
        return
      }

      throw new Error(bookingErrorMessage(data.errors))
    }

    setCreatedAppointment(data.appointment)
    
  } catch (error) {
    if (!selectionIsCurrent()) return
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

  const savedDateTime = createdAppointment
    ? businessDateParts(new Date(createdAppointment.starts_at))
    : null

  if (
    createdAppointment && savedDateTime &&
    selectedService &&
    selectedPrice
  ) {
    return (
      <main className="booking-page">
        <BookingConfirmation
          appointmentId={createdAppointment.id}
          customerName={`${createdAppointment.customer_first_name} ${createdAppointment.customer_last_name}`}
          serviceName={selectedService.name}
          vehicleSize={selectedPrice.vehicle_size}
          vehicleMake={createdAppointment.vehicle_make}
          vehicleModel={createdAppointment.vehicle_model}
          date={savedDateTime.date}
          time={formatTime(savedDateTime.time)}
          priceCents={createdAppointment.price_cents}
          durationMinutes={createdAppointment.duration_minutes}
          status={createdAppointment.status}
          onBookAnother={() => navigate('/services')}
        />
      </main>
    )
  }

  return (
    <main className="booking-page">
      <h1>Contact & Availability</h1>

      {servicesLoading ? (
        <section className="booking-summary" aria-busy="true">
          <p role="status">Loading detailing services...</p>
        </section>
      ) : servicesError ? (
        <section className="booking-summary">
          <p className="form-error" role="alert">{servicesError}</p>
        </section>
      ) : selectedService && selectedPrice ? (
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

                  availabilityScope.current?.abort()
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
