import { useState } from 'react'
import { api, ApiError } from '../lib/api'
import { useSession } from '../lib/session'
import { Alert, Button, Field, Input } from '../components/ui'

export default function Login() {
  const { login } = useSession()
  const [l, setL] = useState('')
  const [p, setP] = useState('')
  const [erreur, setErreur] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [oubli, setOubli] = useState(false)
  const [info, setInfo] = useState<string | null>(null)

  async function demanderLien() {
    setBusy(true)
    setErreur(null)
    try {
      const r = await api.post<{ message: string }>('/api/auth/mot-de-passe-oublie', { login: l.trim() })
      setInfo(r.message)
    } catch (e) {
      setErreur(e instanceof ApiError ? e.message : 'Demande impossible')
    } finally {
      setBusy(false)
    }
  }

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
      <form className="login-card stack" onSubmit={(e) => { e.preventDefault(); void (oubli ? demanderLien() : envoyer()) }}>
        <div>
          <h1>Plateforme SFD</h1>
          <p className="muted" style={{ margin: 0 }}>Connectez-vous pour accéder à votre agence.</p>
        </div>
        {erreur && <Alert>{erreur}</Alert>}
        {info && <Alert tone="info">{info}</Alert>}
        <Field label="Identifiant"><Input value={l} onChange={(e) => setL(e.target.value)} autoComplete="username" autoFocus required /></Field>
        {oubli ? (
          <>
            <p className="muted" style={{ margin: 0 }}>Un lien de réinitialisation sera envoyé à l'adresse enregistrée sur votre compte.</p>
            <Button variant="primary" type="submit" disabled={busy || !l}>{busy ? 'Envoi…' : 'Recevoir le lien'}</Button>
            <Button type="button" onClick={() => { setOubli(false); setInfo(null); setErreur(null) }}>Retour à la connexion</Button>
          </>
        ) : (
          <>
            <Field label="Mot de passe"><Input type="password" value={p} onChange={(e) => setP(e.target.value)} autoComplete="current-password" required /></Field>
            <Button variant="primary" type="submit" disabled={busy || !l || !p}>{busy ? 'Connexion…' : 'Se connecter'}</Button>
            <Button type="button" onClick={() => { setOubli(true); setInfo(null); setErreur(null) }}>Mot de passe oublié ?</Button>
          </>
        )}
      </form>
    </div>
  )
}
