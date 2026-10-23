import { useState } from 'react'
import { api, ApiError } from '../lib/api'
import { useSession } from '../lib/session'
import { Alert, Button, Field, Input } from '../components/ui'

interface Preparation { secret: string; uri: string }

/** Écran affiché tant qu'un rôle sensible n'a pas activé son second facteur (application d'authentification, code TOTP). */
export function EnrolementTotp() {
  const { user, rafraichir, logout } = useSession()
  const [prep, setPrep] = useState<Preparation | null>(null)
  const [code, setCode] = useState('')
  const [codesSecours, setCodesSecours] = useState<string[] | null>(null)
  const [recopies, setRecopies] = useState(false)
  const [erreur, setErreur] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function preparer() {
    setBusy(true)
    setErreur(null)
    try {
      setPrep(await api.post<Preparation>('/api/auth/totp/preparer'))
    } catch (e) {
      setErreur(e instanceof ApiError ? e.message : 'Préparation impossible')
    } finally {
      setBusy(false)
    }
  }

  async function activer() {
    setBusy(true)
    setErreur(null)
    try {
      const r = await api.post<{ codes_secours: string[] }>('/api/auth/totp/activer', { code: code.trim() })
      setCodesSecours(r.codes_secours)
    } catch (e) {
      setErreur(e instanceof ApiError ? e.message : 'Activation impossible')
    } finally {
      setBusy(false)
    }
  }

  // les codes de secours ne s'affichent qu'une fois : on ne quitte l'écran qu'après confirmation
  if (codesSecours) {
    return (
      <div className="login-wrap">
        <div className="login-card stack">
          <div>
            <h1>Second facteur activé</h1>
            <p className="muted" style={{ margin: 0 }}>
              Notez ces codes de secours et gardez-les à l'abri (pas sur le téléphone qui porte l'application). Chacun ne sert qu'une fois ;
              ils ne seront plus affichés.
            </p>
          </div>
          <pre className="num" style={{ margin: 0, columns: 2, fontSize: '1.05rem' }}>{codesSecours.join('\n')}</pre>
          <label><input type="checkbox" checked={recopies} onChange={(e) => setRecopies(e.target.checked)} /> J'ai noté ces codes</label>
          <Button variant="primary" disabled={!recopies} onClick={() => void rafraichir()}>Continuer</Button>
        </div>
      </div>
    )
  }

  return (
    <div className="login-wrap">
      <form className="login-card stack" onSubmit={(e) => { e.preventDefault(); void (prep ? activer() : preparer()) }}>
        <div>
          <h1>Second facteur obligatoire</h1>
          <p className="muted" style={{ margin: 0 }}>
            {user?.nom}, votre rôle exige une application d'authentification (Google Authenticator, Microsoft Authenticator, FreeOTP…).
          </p>
        </div>
        {erreur && <Alert>{erreur}</Alert>}
        {!prep ? (
          <Button variant="primary" type="submit" disabled={busy}>{busy ? 'Préparation…' : 'Commencer'}</Button>
        ) : (
          <>
            <p style={{ margin: 0 }}>1. Dans l'application, ajoutez un compte par saisie manuelle avec cette clé (type : basé sur l'heure) :</p>
            <pre className="num" style={{ margin: 0, userSelect: 'all', wordBreak: 'break-all', whiteSpace: 'pre-wrap' }}>{prep.secret}</pre>
            <p className="muted" style={{ margin: 0 }}>Sur téléphone, vous pouvez aussi ouvrir <a href={prep.uri}>ce lien</a> avec l'application.</p>
            <Field label="2. Code à 6 chiffres affiché par l'application">
              <Input value={code} onChange={(e) => setCode(e.target.value)} inputMode="numeric" autoComplete="one-time-code" maxLength={6} autoFocus required />
            </Field>
            <Button variant="primary" type="submit" disabled={busy || code.trim().length !== 6}>{busy ? 'Vérification…' : 'Activer'}</Button>
          </>
        )}
        <Button type="button" onClick={logout}>Se déconnecter</Button>
      </form>
    </div>
  )
}
