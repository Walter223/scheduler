
import ButtonLink from '../components/ButtonLink'

import heroImage from '../assets/v3-magnum-hero.png'
import magnumLogo from '../assets/magnum-logo.png'

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

          {/* <h2>
            When regular detailing isn't enough,
            <br />
            you need{' '}
            <span className="tagline-accent">
              Magnum Detailing.
            </span>
          </h2> */}

          <h2>
            The most beautiful name in auto detailing
            <br />
            is{' '}
            <span className="tagline-accent">
              Magnum Detailing.
            </span>
          </h2>

          <div className="hero-actions">
            <ButtonLink variant="primary" to="/services">
              View Services
            </ButtonLink>

            <ButtonLink variant="secondary" to="/contact">
              Check Availability
            </ButtonLink>
          </div>
        </div>
      </section>
    </main>
  )
}

export default HomePage