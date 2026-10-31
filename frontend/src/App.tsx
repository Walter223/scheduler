import './App.css'

import { useLayoutEffect } from 'react'
import {
  Routes,
  Route,
  useLocation,
} from 'react-router-dom'

import HomePage from './pages/HomePage'
import ServicesPage from './pages/ServicesPage'
import NavBar from './components/NavBar'
import BookingPage from './pages/BookingPage'
import AdminPage from './pages/AdminPage'

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
      {location.pathname !== '/admin' && <NavBar />}

      <Routes>
        <Route path="/" element={<HomePage />} />
        <Route path="/services" element={<ServicesPage />} />
        <Route path="/contact" element={<BookingPage />} />
        <Route path="/admin" element={<AdminPage />} />
      </Routes>
    </>
  )
}

export default App
