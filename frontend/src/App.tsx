import './App.css'

import { useEffect, useState } from 'react'
import { Routes, Route, Link } from 'react-router-dom'
import heroImage from './assets/v2-magnum-hero.png'
// import heroImage from './assets/v2-magnum-hero-busty-babe.png'

type ServicePrice = {
  price_cents: number
  vehicle_size: string
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
      <section className="hero"
      style={{ backgroundImage: `url(${heroImage})` }}>
        <div className="hero-glow" />

        <div className="hero-content">
          <p className="hero-kicker">Premium Auto Detailing</p>

          <h1 className="hero-title">
            MAGNUM
            <span>DETAILING</span>
          </h1>

          <div className="neon-line" />

          <h2>
            When regular detailing isn't enough,
            <br />
            you need Magnum Detailing.
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

  useEffect(() => {
    fetch('http://localhost:4000/api/services')
      .then((response) => response.json())
      .then((data) => setServices(data))
  }, [])

  return (
    <main>
      <h1>Magnum Detailing Services</h1>

      {services.map((service) => (
        <section key={service.id}>
          <h3>{service.name}</h3>
          <p>{service.description}</p>

          {service.prices.map((price) => (
            <p key={price.vehicle_size}>
              {price.vehicle_size}: ${(price.price_cents / 100).toFixed(2)}
            </p>
          ))}
        </section>
      ))}
    </main>
  )
}

function ContactPage() {
  return (
    <main>
      <h1>Contact & Availability</h1>
    </main>
  )
}

function App() {
  return (
    <>
      <nav>
        <Link to="/">Magnum Detailing</Link>
        <Link to="/services">Services</Link>
        <Link to="/contact">Contact</Link>
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