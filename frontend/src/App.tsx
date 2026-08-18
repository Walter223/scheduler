import './App.css'

import { useEffect, useState } from 'react'

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

function App() {
  const [services, setServices] = useState<Service[]>([])

  useEffect(() => {
    fetch('http://localhost:4000/api/services')
      .then((response) => response.json())
      .then((data) => setServices(data))
  }, [])

  return (
    <main>
      <h1>Magnum Detailing Services</h1>
      <h2>Magnum Services for Magnum People</h2>

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

export default App