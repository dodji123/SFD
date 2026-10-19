import { useState } from 'react'
import { ApiError } from '../lib/api'
import { useSession } from '../lib/session'
import { Alert, Button, Field, Input } from '../components/ui'

export default function Login() {
  const { login } = useSession()
  const [l, setL] = useState('')
  const [p, setP] = useState('')
  const [erreur, setErreur] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function envoyer() {
    setBusy(true)
    setErreur(null)
    try {
      await login(l.trim(), p)
    } catch (e) {
      setErreur(e instanceof ApiError ? e.message : 'Connexion impossible')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="login-wrap">
      <form className="login-card stack" onSubmit={(e) => { e.preventDefault(); void envoyer() }}>
        <div>
          <h1>Plateforme SFD</h1>
          <p className="muted" style={{ margin: 0 }}>Connectez-vous pour accéder à votre agence.</p>
        </div>
        {erreur && <Alert>{erreur}</Alert>}
        <Field label="Identifiant"><Input value={l} onChange={(e) => setL(e.target.value)} autoComplete="username" autoFocus required /></Field>
        <Field label="Mot de passe"><Input type="password" value={p} onChange={(e) => setP(e.target.value)} autoComplete="current-password" required /></Field>
        <Button variant="primary" type="submit" disabled={busy || !l || !p}>{busy ? 'Connexion…' : 'Se connecter'}</Button>
      </form>
    </div>
  )
}
