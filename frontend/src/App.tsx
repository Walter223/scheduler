import './App.css'

import { useEffect, useLayoutEffect, useState } from 'react'
import {
  Routes,
  Route,
  Link,
  NavLink,
  useSearchParams,
  useLocation,
} from 'react-router-dom'

import heroImage from './assets/v3-magnum-hero.png'
import magnumLogo from './assets/magnum-logo.png'
import magnumIcon from './assets/magnum-icon.png'

type ServicePrice = {
  service_price_id: number
  price_cents: number
  duration_minutes: number
  vehicle_size: string
  vehicle_size_id: number
}

function formatTime(time: string) {
  const [hourString, minute] = time.split(':')
  const hour = Number(hourString)

  const period = hour >= 12 ? 'PM' : 'AM'
  const displayHour = hour % 12 || 12

  return `${displayHour}:${minute} ${period}`
}

function formatPhoneNumber(value: string) {
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

function isValidPhoneNumber(value: string) {
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

function isValidName(value: string) {
  const trimmed = value.trim()

  if (!trimmed) {
    return false
  }

  return /^[A-Za-zÀ-ÖØ-öø-ÿ' -]+$/.test(trimmed)
}

function isValidEmail(value: string) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value.trim())
}

type Service = {
  id: number
  name: string
  description: string
  prices: ServicePrice[]
}

type BookingForm = {
  firstName: string
  lastName: string
  customerEmail: string
  customerPhone: string
  vehicleMake: string
  vehicleModel: string
  notes: string
}

type AvailabilityResponse = {
  date: string
  service_price_id: number
  duration_minutes: number
  available_times: string[]
}

function HomePage() {
  return (
    <main className="home-page">
      <section
        className="hero"
        style={{ backgroundImage: `url(${heroImage})` }}
      >
        <div className="hero-glow" />

        <div className="hero-content">
          <p className="hero-kicker">Premium Auto Detailing</p>

          <img
            className="hero-logo"
            src={magnumLogo}
            alt="Magnum Detailing"
          />

          <h2>
            When regular detailing isn't enough,
            <br />
            you need{' '}
            <span className="tagline-accent">
              Magnum Detailing.
            </span>
          </h2>

          <div className="hero-actions">
            <Link className="primary-button" to="/services">
              View Services
            </Link>

            <Link className="secondary-button" to="/contact">
              Check Availability
            </Link>
          </div>
        </div>
      </section>
    </main>
  )
}

function ServicesPage() {
  const [services, setServices] = useState<Service[]>([])

  const [selectedOption, setSelectedOption] = useState<{
    serviceId: number
    vehicleSizeId: number
  } | null>(null)

  useEffect(() => {
    fetch('http://localhost:4000/api/services')
      .then((response) => response.json())
      .then((data) => setServices(data))
  }, [])

  return (
    <main className="services-page">
      <h1>Magnum Detailing Services</h1>

      <div className="services-grid">
        {services.map((service) => (
          <section className="service-card" key={service.id}>
            <h2>{service.name}</h2>

            <p className="service-description">
              {service.description}
            </p>

            <div className="service-prices">
              {service.prices.map((price) => {
                const isSelected =
                  selectedOption?.serviceId === service.id &&
                  selectedOption?.vehicleSizeId ===
                    price.vehicle_size_id

                return (
                  <button
                    type="button"
                    aria-pressed={isSelected}
                    className={`price-option ${
                      isSelected ? 'selected' : ''
                    }`}
                    key={price.vehicle_size_id}
                    onClick={() => {
                      if (isSelected) {
                        setSelectedOption(null)
                      } else {
                        setSelectedOption({
                          serviceId: service.id,
                          vehicleSizeId: price.vehicle_size_id,
                        })
                      }
                    }}
                  >
                    <strong>{price.vehicle_size}</strong>

                    <p>
                      ${(price.price_cents / 100).toFixed(2)}
                    </p>

                    <p>{price.duration_minutes} min</p>
                  </button>
                )
              })}
            </div>

            <Link
              aria-disabled={
                selectedOption?.serviceId !== service.id
              }
              tabIndex={
                selectedOption?.serviceId !== service.id ? -1 : 0
              }
              className={`book-button ${
                selectedOption?.serviceId !== service.id
                  ? 'disabled'
                  : ''
              }`}
              to={
                selectedOption?.serviceId === service.id
                  ? `/contact?service=${service.id}&size=${selectedOption.vehicleSizeId}`
                  : '#'
              }
              onClick={(event) => {
                if (selectedOption?.serviceId !== service.id) {
                  event.preventDefault()
                }
              }}
            >
              Book This Detail
            </Link>
          </section>
        ))}
      </div>
    </main>
  )
}

function ContactPage() {
  const [searchParams] = useSearchParams()

  const [services, setServices] = useState<Service[]>([])
  const [selectedDate, setSelectedDate] = useState('')
  const [availableTimes, setAvailableTimes] = useState<string[]>([])
  const [availabilityError, setAvailabilityError] = useState('')
  const [selectedTime, setSelectedTime] = useState('')

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

  useEffect(() => {
    if (!selectedDate || !servicePriceId) {
      setAvailableTimes([])
      setAvailabilityError('')
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
                }}
              />
            </div>
          </div>

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
                    <button
                      key={time}
                      type="button"
                      aria-pressed={isSelected}
                      className={`availability-time ${
                        isSelected ? 'selected' : ''
                      }`}
                      onClick={() =>
                        setSelectedTime(isSelected ? '' : time)
                      }
                    >
                      {formatTime(time)}
                    </button>
                  )
                })}
            </div>
          )}

          {selectedTime && (
            <div className="booking-form">
              <div className="booking-form-section">
                <h3>Customer Information</h3>

                <label htmlFor="first-name">First Name</label>

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

                {firstNameInvalid && (
                  <p
                    id="first-name-error"
                    className="form-error"
                  >
                    Please enter a valid first name
                  </p>
                )}

                <label htmlFor="last-name">Last Name</label>

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

                {lastNameInvalid && (
                  <p
                    id="last-name-error"
                    className="form-error"
                  >
                    Please enter a valid last name
                  </p>
                )}

                <label htmlFor="customer-email">Email</label>

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

                {emailInvalid && (
                  <p
                    id="customer-email-error"
                    className="form-error"
                  >
                    Please enter a valid email address
                  </p>
                )}

                <label htmlFor="customer-phone">Phone</label>

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

                {phoneInvalid && (
                  <p
                    id="customer-phone-error"
                    className="form-error"
                  >
                    A valid phone number is required in this field
                  </p>
                )}
              </div>

              <div className="booking-form-section">
                <h3>Vehicle Information</h3>

                <label htmlFor="vehicle-make">Make</label>

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

                {makeInvalid && (
                  <p
                    id="vehicle-make-error"
                    className="form-error"
                  >
                    Please enter the Make of your vehicle
                  </p>
                )}

                <label htmlFor="vehicle-model">Model</label>

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

                {modelInvalid && (
                  <p
                    id="vehicle-model-error"
                    className="form-error"
                  >
                    Please enter the model of your vehicle
                  </p>
                )}

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

          <Link className="book-button" to="/services">
            View Services
          </Link>
        </section>
      )}
    </main>
  )
}

const App = () => {
  const location = useLocation()

  useLayoutEffect(() => {
    window.scrollTo({
      top: 0,
      left: 0,
      behavior: 'instant',
    })
  }, [location.key])

  return (
    <>
      <nav className="main-nav">
        <Link className="nav-brand" to="/">
          <img
            className="nav-logo"
            src={magnumIcon}
            alt="Magnum Detailing"
          />
        </Link>

        <div className="nav-links">
          <NavLink to="/">Home</NavLink>
          <NavLink to="/services">Services</NavLink>
          <NavLink to="/contact">Contact</NavLink>
        </div>

        <div className="nav-neon-line" />
      </nav>

      <Routes>
        <Route path="/" element={<HomePage />} />
        <Route path="/services" element={<ServicesPage />} />
        <Route path="/contact" element={<ContactPage />} />
      </Routes>
    </>
  )
}

export default App
