import './App.css'

import { useLayoutEffect } from 'react'
import {
  Routes,
  Route,
  useLocation,
  useParams,
  useSearchParams,
} from 'react-router-dom'

import PlatformPage from './pages/PlatformPage'
import HomePage from './pages/HomePage'
import ServicesPage from './pages/ServicesPage'
import NavBar from './components/NavBar'
import BookingPage from './pages/BookingPage'
import SignupPage from './pages/SignupPage'
import AdminPage from './pages/AdminPage'

function SetupRoute() {
  const { businessId } = useParams()
  const id = businessId && /^[1-9][0-9]*$/.test(businessId) && Number.isSafeInteger(Number(businessId)) ? Number(businessId) : -1
  return <AdminPage key={`setup-route:${id}`} setupBusinessId={id} />
}
function AdminRoute() {
  const [params] = useSearchParams()
  const value = params.get('business')
  const id = value && /^[1-9][0-9]*$/.test(value) && Number.isSafeInteger(Number(value)) ? Number(value) : 0
  return <AdminPage initialBusinessId={id} />
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
      {['/', '/services', '/contact'].includes(location.pathname) && <NavBar />}

      <Routes>
        <Route path="/" element={<HomePage />} />
        <Route path="/services" element={<ServicesPage />} />
        <Route path="/contact" element={<BookingPage />} />
        <Route path="/signup" element={<SignupPage />} />
        <Route path="/platform" element={<PlatformPage />} />
        <Route path="/setup/:businessId" element={<SetupRoute />} />
        <Route path="/admin" element={<AdminRoute />} />
      </Routes>
    </>
  )
}

export default App
