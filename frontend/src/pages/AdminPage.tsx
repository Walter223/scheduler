import SessionControls from '../components/SessionControls'

function AdminPage() {
  return (
    <main className="booking-page">
      <h1>Staff account</h1>
      <p>Signing in verifies your identity. It does not grant business or shop access.</p>
      <SessionControls />
    </main>
  )
}

export default AdminPage
