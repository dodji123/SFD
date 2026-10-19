import { useCallback, useEffect, useRef, useState } from 'react'
import { date as fdate, xof } from '../lib/format'

// Espace client : autonome, jamais mêlé à la session du personnel (autre jeton, autre stockage, aucun en-tête d'agence).
const CLE = 'sfd_client_token'
const INACTIVITE_MS = 5 * 60 * 1000

function lire(): string | null { try { return sessionStorage.getItem(CLE) } catch { return null } }
function ecrire(v: string | null) { try { if (v) sessionStorage.setItem(CLE, v); else sessionStorage.removeItem(CLE) } catch { /* stockage indisponible */ } }

class ErreurClient extends Error { status: number; constructor(m: string, s: number) { super(m); this.status = s } }

async function appel<T = unknown>(methode: string, chemin: string, corps?: unknown): Promise<T> {
  const jeton = lire()
  const r = await fetch(chemin, {
    method: methode,
    headers: { ...(corps !== undefined ? { 'Content-Type': 'application/json' } : {}), ...(jeton ? { Authorization: `Bearer ${jeton}` } : {}) },
    body: corps !== undefined ? JSON.stringify(corps) : undefined,
  })
  if (r.status === 204) return undefined as T
  const j = await r.json().catch(() => ({}))
  if (!r.ok) throw new ErreurClient(typeof j.detail === 'string' ? j.detail : 'Une erreur est survenue', r.status)
  return j as T
}

interface Moi { nom: string; numero: string; telephone: string; pin_provisoire: boolean; derniere_connexion: string | null }
interface Compte { id: number; numero: string; produit: string; solde: number; disponible: number; statut: string }
interface Mouvement { date_operation: string; type: string; montant: number; libelle: string | null }
interface Cycle { id: number; numero: string; statut: string; type_cycle: number; montant_collecte: number }
interface Ligne { page: number; no_ligne: number; date_collecte: string; montant_collecte: number }
interface Credit { id: number; numero: string; montant_accorde: number; capital_restant: number; prochaine_echeance: string | null; montant_prochaine_echeance: number | null; statut: string }
interface Echeance { no_echeance: number; date_prevue: string; capital: number; interet: number; statut: string; reste_a_payer: number }
interface Acces { cree_le: string; evenement: string; ip: string | null }

const LIB_EVT: Record<string, string> = { connexion_ok: 'Connexion', pin_change: 'Changement de PIN', echec_pin: 'PIN incorrect', echec_otp: 'Code incorrect', deconnexion: 'Déconnexion',
  verrouillage: 'Verrouillage', otp_envoye: 'Code envoyé', acces_active: 'Accès activé', acces_bloque: 'Accès bloqué', echec_changement_pin: 'Changement de PIN refusé' }
const LIB_MVT: Record<string, string> = { depot: 'Dépôt', retrait: 'Retrait', virement_entrant: 'Virement reçu', virement_sortant: 'Virement émis', interet: 'Intérêts' }

export default function EspaceClient() {
  const [etape, setEtape] = useState<'connexion' | 'code' | 'pin' | 'accueil'>(lire() ? 'accueil' : 'connexion')
  const [numero, setNumero] = useState('')
  const [info, setInfo] = useState<string | null>(null)
  const quitter = useCallback((message?: string) => { ecrire(null); setEtape('connexion'); setInfo(message ?? null) }, [])

  // déconnexion automatique après 5 minutes d'inactivité
  const minuteur = useRef<number | null>(null)
  useEffect(() => {
    if (etape !== 'accueil' && etape !== 'pin') return
    const armer = () => { if (minuteur.current) window.clearTimeout(minuteur.current); minuteur.current = window.setTimeout(() => { void appel('POST', '/api/espace/deconnexion').catch(() => {}); quitter('Session fermée après 5 minutes d\'inactivité.') }, INACTIVITE_MS) }
    armer()
    const evts = ['click', 'keydown', 'touchstart']
    evts.forEach((e) => window.addEventListener(e, armer))
    return () => { evts.forEach((e) => window.removeEventListener(e, armer)); if (minuteur.current) window.clearTimeout(minuteur.current) }
  }, [etape, quitter])

  return (
    <div style={{ maxWidth: 760, margin: '0 auto', padding: '16px' }}>
      <h1 style={{ marginBottom: 4 }}>Mon espace client</h1>
      <p className="muted" style={{ marginTop: 0 }}>Consultez vos comptes, votre carnet et vos échéances en toute sécurité.</p>
      {info && <div className="alert info" role="status" style={{ marginBottom: 12 }}>{info}</div>}
      {etape === 'connexion' && <Connexion numero={numero} setNumero={setNumero} onSuite={() => { setInfo(null); setEtape('code') }} />}
      {etape === 'code' && <Code numero={numero} onRetour={() => setEtape('connexion')} onOk={(prov) => setEtape(prov ? 'pin' : 'accueil')} />}
      {etape === 'pin' && <ChangerPin onOk={() => { setInfo('PIN modifié. Reconnectez-vous avec votre nouveau PIN.'); void appel('POST', '/api/espace/deconnexion').catch(() => {}); quitter('PIN modifié. Reconnectez-vous avec votre nouveau PIN.') }} />}
      {etape === 'accueil' && <Accueil onQuitter={() => { void appel('POST', '/api/espace/deconnexion').catch(() => {}); quitter('Vous êtes déconnecté.') }} onExpire={() => quitter('Votre session a expiré. Reconnectez-vous.')} />}
    </div>
  )
}

function Formulaire({ titre, children, onSubmit, erreur, occupe, bouton }: { titre: string; children: React.ReactNode; onSubmit: () => void; erreur: string | null; occupe: boolean; bouton: string }) {
  return (
    <form className="card" onSubmit={(e) => { e.preventDefault(); onSubmit() }} style={{ padding: 16, display: 'grid', gap: 12 }}>
      <h2 style={{ margin: 0, fontSize: '1.1rem' }}>{titre}</h2>
      {children}
      {erreur && <div className="alert bad" role="alert">{erreur}</div>}
      <button className="btn primary" type="submit" disabled={occupe}>{occupe ? 'Patientez…' : bouton}</button>
    </form>
  )
}

function useEnvoi() {
  const [erreur, setErreur] = useState<string | null>(null)
  const [occupe, setOccupe] = useState(false)
  const lancer = async (f: () => Promise<void>) => { setErreur(null); setOccupe(true); try { await f() } catch (e) { setErreur(e instanceof Error ? e.message : 'Erreur') } finally { setOccupe(false) } }
  return { erreur, occupe, lancer }
}

function Connexion({ numero, setNumero, onSuite }: { numero: string; setNumero: (v: string) => void; onSuite: () => void }) {
  const [pin, setPin] = useState('')
  const [dev, setDev] = useState<string | null>(null)
  const { erreur, occupe, lancer } = useEnvoi()
  return (
    <>
      <Formulaire titre="Connexion" bouton="Recevoir mon code par SMS" erreur={erreur} occupe={occupe}
        onSubmit={() => void lancer(async () => {
          const r = await appel<{ otp_dev?: string }>('POST', '/api/espace/connexion', { numero: numero.trim(), pin })
          setPin('')
          if (r.otp_dev) sessionStorage.setItem('sfd_otp_dev', r.otp_dev)
          setDev(r.otp_dev ?? null)
          onSuite()
        })}>
        <label>Numéro client<input className="input" value={numero} onChange={(e) => setNumero(e.target.value)} autoComplete="username" required /></label>
        <label>PIN<input className="input" type="password" inputMode="numeric" value={pin} onChange={(e) => setPin(e.target.value)} autoComplete="current-password" maxLength={8} required /></label>
      </Formulaire>
      {dev && null}
      <p className="muted">Votre numéro client et votre PIN provisoire vous sont remis en agence. Ne communiquez jamais votre PIN ni vos codes SMS, même à un agent.</p>
    </>
  )
}

function Code({ numero, onRetour, onOk }: { numero: string; onRetour: () => void; onOk: (provisoire: boolean) => void }) {
  const [code, setCode] = useState('')
  const dev = (() => { try { return sessionStorage.getItem('sfd_otp_dev') } catch { return null } })()
  const { erreur, occupe, lancer } = useEnvoi()
  return (
    <Formulaire titre="Code de vérification" bouton="Valider" erreur={erreur} occupe={occupe}
      onSubmit={() => void lancer(async () => {
        const r = await appel<{ access_token: string; pin_provisoire: boolean }>('POST', '/api/espace/otp', { numero: numero.trim(), code: code.trim() })
        try { sessionStorage.removeItem('sfd_otp_dev') } catch { /* sans effet */ }
        ecrire(r.access_token)
        onOk(r.pin_provisoire)
      })}>
      <p style={{ margin: 0 }}>Un code à 6 chiffres vient d'être envoyé par SMS. Il est valable 5 minutes et ne sert qu'une fois.</p>
      {dev && <div className="alert warn">Mode développement : code {dev}</div>}
      <label>Code reçu<input className="input" inputMode="numeric" value={code} onChange={(e) => setCode(e.target.value)} maxLength={6} autoComplete="one-time-code" required /></label>
      <button type="button" className="btn" onClick={onRetour}>Retour</button>
    </Formulaire>
  )
}

function ChangerPin({ onOk }: { onOk: () => void }) {
  const [f, setF] = useState({ ancien: '', nouveau: '', confirmation: '' })
  const { erreur, occupe, lancer } = useEnvoi()
  const [local, setLocal] = useState<string | null>(null)
  return (
    <Formulaire titre="Choisissez votre PIN personnel" bouton="Enregistrer mon PIN" erreur={local ?? erreur} occupe={occupe}
      onSubmit={() => {
        setLocal(null)
        if (f.nouveau !== f.confirmation) { setLocal('Les deux PIN ne sont pas identiques'); return }
        void lancer(async () => { await appel('POST', '/api/espace/pin', { ancien: f.ancien, nouveau: f.nouveau }); onOk() })
      }}>
      <p style={{ margin: 0 }}>Votre PIN actuel est provisoire. Choisissez un PIN de 6 à 8 chiffres, sans suite (123456) ni répétition (111111).</p>
      <label>PIN provisoire<input className="input" type="password" inputMode="numeric" value={f.ancien} onChange={(e) => setF({ ...f, ancien: e.target.value })} maxLength={8} required /></label>
      <label>Nouveau PIN<input className="input" type="password" inputMode="numeric" value={f.nouveau} onChange={(e) => setF({ ...f, nouveau: e.target.value })} maxLength={8} required /></label>
      <label>Confirmer le nouveau PIN<input className="input" type="password" inputMode="numeric" value={f.confirmation} onChange={(e) => setF({ ...f, confirmation: e.target.value })} maxLength={8} required /></label>
    </Formulaire>
  )
}

function useDonnees<T>(chemin: string | null, expire: () => void) {
  const [d, setD] = useState<T | null>(null)
  const [err, setErr] = useState<string | null>(null)
  useEffect(() => {
    if (!chemin) return
    let actif = true
    appel<T>('GET', chemin).then((x) => actif && setD(x)).catch((e) => { if (!actif) return; if (e instanceof ErreurClient && e.status === 401) expire(); else setErr(e.message) })
    return () => { actif = false }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chemin])
  return { d, err }
}

function Accueil({ onQuitter, onExpire }: { onQuitter: () => void; onExpire: () => void }) {
  const [onglet, setOnglet] = useState<'comptes' | 'tontine' | 'credits' | 'securite'>('comptes')
  const { d: moi } = useDonnees<Moi>('/api/espace/moi', onExpire)
  return (
    <>
      <div className="actions" style={{ justifyContent: 'space-between', marginBottom: 8 }}>
        <div><strong>{moi?.nom ?? '…'}</strong><div className="muted">{moi?.numero} · {moi?.telephone}</div></div>
        <button className="btn" onClick={onQuitter}>Se déconnecter</button>
      </div>
      <div className="tabs" role="tablist" style={{ marginBottom: 12 }}>
        {([['comptes', 'Mes comptes'], ['tontine', 'Ma tontine'], ['credits', 'Mes crédits'], ['securite', 'Sécurité']] as const).map(([k, t]) => (
          <button key={k} role="tab" aria-selected={onglet === k} className={`tab ${onglet === k ? 'actif' : ''}`} onClick={() => setOnglet(k)}>{t}</button>
        ))}
      </div>
      {onglet === 'comptes' && <Comptes onExpire={onExpire} />}
      {onglet === 'tontine' && <Tontine onExpire={onExpire} />}
      {onglet === 'credits' && <Credits onExpire={onExpire} />}
      {onglet === 'securite' && <Securite onExpire={onExpire} derniere={moi?.derniere_connexion ?? null} />}
    </>
  )
}

function Comptes({ onExpire }: { onExpire: () => void }) {
  const { d, err } = useDonnees<Compte[]>('/api/espace/comptes', onExpire)
  const [ouvert, setOuvert] = useState<number | null>(null)
  const mv = useDonnees<Mouvement[]>(ouvert ? `/api/espace/comptes/${ouvert}/mouvements` : null, onExpire)
  if (err) return <div className="alert bad">{err}</div>
  if (!d) return <p>Chargement…</p>
  if (d.length === 0) return <p className="muted">Aucun compte d'épargne.</p>
  return (
    <div style={{ display: 'grid', gap: 12 }}>
      {d.map((c) => (
        <div key={c.id} className="card" style={{ padding: 12 }}>
          <div className="actions" style={{ justifyContent: 'space-between' }}><strong>{c.produit}</strong><span className="muted">{c.numero}</span></div>
          <div style={{ fontSize: '1.5rem', fontWeight: 600 }}>{xof(c.solde)}</div>
          <div className="muted">Disponible : {xof(c.disponible)}</div>
          <button className="btn" onClick={() => setOuvert(ouvert === c.id ? null : c.id)}>{ouvert === c.id ? 'Masquer les mouvements' : 'Voir les derniers mouvements'}</button>
          {ouvert === c.id && mv.d && (
            <table className="t" style={{ marginTop: 8 }}><tbody>
              {mv.d.map((m, i) => <tr key={i}><td>{fdate(m.date_operation)}</td><td>{LIB_MVT[m.type] ?? m.type}</td><td className="num">{xof(m.montant)}</td></tr>)}
              {mv.d.length === 0 && <tr><td className="muted">Aucun mouvement</td></tr>}
            </tbody></table>
          )}
        </div>
      ))}
    </div>
  )
}

function Tontine({ onExpire }: { onExpire: () => void }) {
  const { d, err } = useDonnees<Cycle[]>('/api/espace/cycles', onExpire)
  const [ouvert, setOuvert] = useState<number | null>(null)
  const carnet = useDonnees<Ligne[]>(ouvert ? `/api/espace/cycles/${ouvert}/carnet` : null, onExpire)
  if (err) return <div className="alert bad">{err}</div>
  if (!d) return <p>Chargement…</p>
  if (d.length === 0) return <p className="muted">Aucun cycle de tontine.</p>
  return (
    <div style={{ display: 'grid', gap: 12 }}>
      {d.map((c) => (
        <div key={c.id} className="card" style={{ padding: 12 }}>
          <div className="actions" style={{ justifyContent: 'space-between' }}><strong>Cycle {c.numero}</strong><span className="muted">{c.statut === 'en_cours' ? 'En cours' : c.statut === 'clos' ? 'Clos' : 'Retiré'}</span></div>
          <div style={{ fontSize: '1.5rem', fontWeight: 600 }}>{xof(c.montant_collecte)}</div>
          <button className="btn" onClick={() => setOuvert(ouvert === c.id ? null : c.id)}>{ouvert === c.id ? 'Masquer mon carnet' : 'Voir mon carnet'}</button>
          {ouvert === c.id && carnet.d && (
            <table className="t" style={{ marginTop: 8 }}><tbody>
              {carnet.d.map((l, i) => <tr key={i}><td>Page {l.page} · ligne {l.no_ligne}</td><td>{fdate(l.date_collecte)}</td><td className="num">{xof(l.montant_collecte)}</td></tr>)}
            </tbody></table>
          )}
        </div>
      ))}
    </div>
  )
}

function Credits({ onExpire }: { onExpire: () => void }) {
  const { d, err } = useDonnees<Credit[]>('/api/espace/credits', onExpire)
  const [ouvert, setOuvert] = useState<number | null>(null)
  const ech = useDonnees<Echeance[]>(ouvert ? `/api/espace/credits/${ouvert}/echeances` : null, onExpire)
  if (err) return <div className="alert bad">{err}</div>
  if (!d) return <p>Chargement…</p>
  if (d.length === 0) return <p className="muted">Aucun crédit.</p>
  return (
    <div style={{ display: 'grid', gap: 12 }}>
      {d.map((c) => (
        <div key={c.id} className="card" style={{ padding: 12 }}>
          <div className="actions" style={{ justifyContent: 'space-between' }}><strong>Crédit {c.numero}</strong><span className="muted">{c.statut === 'solde' ? 'Soldé' : c.statut === 'en_retard' ? 'En retard' : 'En cours'}</span></div>
          <div>Capital restant : <strong>{xof(c.capital_restant)}</strong></div>
          {c.prochaine_echeance && <div>Prochaine échéance : <strong>{fdate(c.prochaine_echeance)}</strong> · {xof(c.montant_prochaine_echeance ?? 0)}</div>}
          <button className="btn" onClick={() => setOuvert(ouvert === c.id ? null : c.id)}>{ouvert === c.id ? 'Masquer le calendrier' : 'Voir le calendrier'}</button>
          {ouvert === c.id && ech.d && (
            <table className="t" style={{ marginTop: 8 }}><tbody>
              {ech.d.map((e) => <tr key={e.no_echeance}><td>n°{e.no_echeance}</td><td>{fdate(e.date_prevue)}</td><td className="num">{e.statut === 'payee' ? 'Payée' : xof(e.reste_a_payer)}</td></tr>)}
            </tbody></table>
          )}
        </div>
      ))}
    </div>
  )
}

function Securite({ onExpire, derniere }: { onExpire: () => void; derniere: string | null }) {
  const { d } = useDonnees<Acces[]>('/api/espace/journal', onExpire)
  return (
    <div className="card" style={{ padding: 12 }}>
      <h2 style={{ marginTop: 0, fontSize: '1.1rem' }}>Mes derniers accès</h2>
      <p className="muted">Si vous ne reconnaissez pas une connexion, prévenez immédiatement votre agence pour faire bloquer l'accès.{derniere ? ` Dernière connexion : ${new Date(derniere).toLocaleString('fr-FR')}.` : ''}</p>
      <table className="t"><tbody>
        {(d ?? []).map((a, i) => <tr key={i}><td>{new Date(a.cree_le).toLocaleString('fr-FR')}</td><td>{LIB_EVT[a.evenement] ?? a.evenement}</td><td className="muted">{a.ip}</td></tr>)}
      </tbody></table>
      <ul className="muted">
        <li>Votre agence ne vous demandera jamais votre PIN ni vos codes SMS.</li>
        <li>La session se ferme seule après 5 minutes d'inactivité.</li>
        <li>Après 5 PIN erronés, l'accès est verrouillé quelques minutes.</li>
      </ul>
    </div>
  )
}
