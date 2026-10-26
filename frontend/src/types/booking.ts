export type ServicePrice = {
  service_price_id: number
  price_cents: number
  duration_minutes: number
  vehicle_size: string
  vehicle_size_id: number
}

export type Appointment = {
  id: number
  status: string
  duration_minutes: number
  price_cents: number
  starts_at: string
  customer_name: string
  customer_email: string
  customer_phone: string
  vehicle_make: string
  vehicle_model: string
  notes: string | null
  service_price_id: number
}

export type Service = {
  id: number
  name: string
  description: string
  prices: ServicePrice[]
}

export type BookingForm = {
  firstName: string
  lastName: string
  customerEmail: string
  customerPhone: string
  vehicleMake: string
  vehicleModel: string
  notes: string
}

export type AvailabilityResponse = {
  date: string
  service_price_id: number
  duration_minutes: number
  available_times: string[]
}
