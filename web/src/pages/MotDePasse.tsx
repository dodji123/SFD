import { useState } from 'react'
import { api, ApiError } from '../lib/api'
import { useSession } from '../lib/session'
import { Alert, Button, Field, Input } from '../components/ui'

const REGLES = '10 caractères au moins, avec majuscule, minuscule, chiffre et caractère spécial ; différent des 5 derniers mots de passe.'

/** Écran affiché tant que le mot de passe est temporaire (première connexion, réinitialisation, expiration). */
export function ChangementObligatoire() {
  const { user, rafraichir, logout } = useSession()
  const [ancien, setAncien] = useState('')
  const [nouveau, setNouveau] = useState('')
  const [confirm, setConfirm] = useState('')
  const [erreur, setErreur] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function envoyer() {
    if (nouveau !== confirm) { setErreur('Les deux saisies du nouveau mot de passe diffèrent'); return }
    setBusy(true)
    setErreur(null)
    try {
      await api.post('/api/auth/mot-de-passe', { ancien, nouveau })
      await rafraichir()
    } catch (e) {
      setErreur(e instanceof ApiError ? e.message : 'Changement impossible')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="login-wrap">
      <form className="login-card stack" onSubmit={(e) => { e.preventDefault(); void envoyer() }}>
        <div>
          <h1>Nouveau mot de passe</h1>
          <p className="muted" style={{ margin: 0 }}>{user?.nom}, votre mot de passe est temporaire : choisissez-en un nouveau avant de continuer.</p>
        </div>
        {erreur && <Alert>{erreur}</Alert>}
        <Field label="Mot de passe actuel"><Input type="password" value={ancien} onChange={(e) => setAncien(e.target.value)} autoComplete="current-password" autoFocus required /></Field>
        <Field label="Nouveau mot de passe" hint={REGLES}><Input type="password" value={nouveau} onChange={(e) => setNouveau(e.target.value)} autoComplete="new-password" minLength={10} required /></Field>
        <Field label="Confirmer le nouveau mot de passe"><Input type="password" value={confirm} onChange={(e) => setConfirm(e.target.value)} autoComplete="new-password" required /></Field>
        <Button variant="primary" type="submit" disabled={busy || !ancien || !nouveau || !confirm}>{busy ? 'Enregistrement…' : 'Enregistrer'}</Button>
        <Button type="button" onClick={logout}>Se déconnecter</Button>
      </form>
    </div>
  )
}

/** Page ouverte depuis le lien reçu : /reinitialiser?jeton=… */
export function Reinitialiser() {
  const jeton = new URLSearchParams(window.location.search).get('jeton') ?? ''
  const [nouveau, setNouveau] = useState('')
  const [confirm, setConfirm] = useState('')
  const [erreur, setErreur] = useState<string | null>(null)
  const [fait, setFait] = useState(false)
  const [busy, setBusy] = useState(false)

  async function envoyer() {
    if (nouveau !== confirm) { setErreur('Les deux saisies diffèrent'); return }
    setBusy(true)
    setErreur(null)
    try {
      await api.post('/api/auth/reinitialiser-mot-de-passe', { jeton, nouveau })
      setFait(true)
    } catch (e) {
      setErreur(e instanceof ApiError ? e.message : 'Réinitialisation impossible')
    } finally {
      setBusy(false)
    }
  }

  return (
    <div className="login-wrap">
      <form className="login-card stack" onSubmit={(e) => { e.preventDefault(); void envoyer() }}>
        <div>
          <h1>Réinitialiser le mot de passe</h1>
          <p className="muted" style={{ margin: 0 }}>Choisissez un nouveau mot de passe. Le lien reçu ne sert qu'une fois.</p>
        </div>
        {fait ? (
          <>
            <Alert tone="info">Mot de passe modifié. Vous pouvez maintenant vous connecter.</Alert>
            <a className="btn btn-primary" href="/">Aller à la connexion</a>
          </>
        ) : (
          <>
            {!jeton && <Alert>Lien incomplet : ouvrez le lien reçu par message.</Alert>}
            {erreur && <Alert>{erreur}</Alert>}
            <Field label="Nouveau mot de passe" hint={REGLES}><Input type="password" value={nouveau} onChange={(e) => setNouveau(e.target.value)} autoComplete="new-password" minLength={10} autoFocus required /></Field>
            <Field label="Confirmer"><Input type="password" value={confirm} onChange={(e) => setConfirm(e.target.value)} autoComplete="new-password" required /></Field>
            <Button variant="primary" type="submit" disabled={busy || !jeton || !nouveau || !confirm}>{busy ? 'Enregistrement…' : 'Enregistrer'}</Button>
          </>
        )}
      </form>
    </div>
  )
}
