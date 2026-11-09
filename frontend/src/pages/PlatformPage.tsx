import { Link } from 'react-router-dom'
import './platform.css'
export default function PlatformPage() {
  return <main className="platform-page">
    <header><Link to="/platform" className="platform-wordmark">MAGNUM <span>FOR DETAILING BUSINESSES</span></Link><Link to="/admin">Sign In</Link></header>
    <section aria-labelledby="platform-title"><p className="platform-kicker">YOUR COMPANY. YOUR WORKSPACE.</p><h1 id="platform-title">Build your detailing business with Magnum.</h1><p>Bring your locations, people and daily operations together in an independent business workspace.</p><div className="platform-actions"><Link to="/signup">Create a Business</Link><Link to="/admin">Sign In to your workspace</Link></div></section>
    <section className="platform-stages" aria-label="Getting started"><article><span>01</span><h2>Verify your identity</h2><p>Use secure Keycloak authentication. Registration never grants access to another company.</p></article><article><span>02</span><h2>Configure your business</h2><p>Save and resume private location and mobile-service proposals. Your first shop is preserved.</p></article><article><span>03</span><h2>Manage your operations</h2><p>Open your authorized management workspace. Draft setup does not publish a booking site or activate proposed services.</p></article></section>
    <footer><p>Magnum is the business platform. Magnum Detailing is an individual detailing business.</p><Link to="/">Visit Magnum Detailing’s customer website</Link><p>Public tenant-specific booking and publishing are separate upcoming capabilities.</p></footer>
  </main>
}
