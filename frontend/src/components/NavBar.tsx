import { Link, NavLink } from 'react-router-dom'

import magnumIcon from '../assets/magnum-icon.png'

function NavBar() {
  return (
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
  )
}

export default NavBar
