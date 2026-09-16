import './App.css'

import { useEffect, useState } from 'react'
import {
  Routes,
  Route,
  Link,
  useSearchParams,
} from 'react-router-dom'
import heroImage from './assets/v3-magnum-hero.png'
// import heroImage from './assets/v3-magnum-hero-busty-babe-2.png'
// import heroImage from './assets/v6-magnum-hero-busty-7.png'
import magnumLogo from './assets/magnum-logo.png'
import magnumIcon from './assets/magnum-icon.png'

type ServicePrice = {
  price_cents: number
  duration_minutes: number
  vehicle_size: string
  vehicle_size_id: number
}

type Service = {
  id: number
  name: string
  description: string
  prices: ServicePrice[]
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
            you need <span className="tagline-accent">Magnum Detailing.</span>
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
                  selectedOption?.vehicleSizeId === price.vehicle_size_id

                return (
                  <button
                    type="button"
                    className={`price-option ${isSelected ? 'selected' : ''}`}
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

                    <p>
                      {price.duration_minutes} min
                    </p>
                  </button>
                )
              })}
            </div>

            <Link
              className={`book-button ${
                selectedOption?.serviceId !== service.id ? 'disabled' : ''
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
          </div>

          <Link className="change-selection" to="/services">
            ← Change Selection
          </Link>
        </section>
      ) : (
        <section className="booking-summary">
          <p className="booking-label">No Detail Selected</p>

          <h2>Choose Your Detail</h2>

          <p className="booking-vehicle">
            Select a detailing package and vehicle size before checking
            availability.
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
          <Link to="/">Home</Link>
          <Link to="/services">Services</Link>
          <Link to="/contact">Contact</Link>
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