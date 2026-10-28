import { useEffect, useState } from 'react'
import Button from '../components/Button'
import ButtonLink from '../components/ButtonLink'

type ServicePrice = {
  service_price_id: number
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

function ServicesPage() {
  const [services, setServices] = useState<Service[]>([])

  const [selectedOption, setSelectedOption] = useState<{
    serviceId: number
    vehicleSizeId: number
  } | null>(null)

  useEffect(() => {
    fetch('/api/services')
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
                  <Button
                    type="button"
                    variant="service-option"
                    selected={isSelected}
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
                  </Button>
                )
              })}
            </div>

            <ButtonLink
              variant="booking"
              disabled={
                selectedOption?.serviceId !== service.id
              }
              tabIndex={
                selectedOption?.serviceId !== service.id ? -1 : 0
              }
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
            </ButtonLink>
          </section>
        ))}
      </div>
    </main>
  )
}

export default ServicesPage
