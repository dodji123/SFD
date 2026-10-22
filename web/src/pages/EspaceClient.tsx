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

interface PaiementMobile { reference: string; cycle: string; produit: string; operateur: string; operateur_libelle: string; montant: number; statut: string; motif: string | null; cree_le: string; expire_le: string }
interface LigneSuivi extends Ligne { origine: string }
interface Suivi {
  id: number; numero: string; statut: string; type_cycle: number; nb_lignes: number; montant_collecte: number; reste_a_collecter: number | null
  date_debut: string; date_fin: string; date_limite: string; nb_lignes_prevues: number; objectif: number | null; mise_courante: number; produit: string; produit_libelle: string
  lignes: LigneSuivi[]; paiements: PaiementMobile[]; progression: number | null
  demande_retrait: { id: number; statut: string; canal: string; cree_le: string; commentaire: string | null } | null
  retrait: { statut: string; montant: number; date_demande: string } | null
}
interface Operateurs { mode: string; operateurs: { code: string; libelle: string }[] }

const LIB_ORIGINE: Record<string, string> = { collecte: 'Collecte par l’agent', virement: 'Virement depuis l’épargne', mobile: 'Mobile money' }
const LIB_PAIEMENT: Record<string, string> = { initie: 'En attente de confirmation', reussi: 'Réussi', echoue: 'Échoué', expire: 'Expiré', a_rembourser: 'À rembourser', rembourse: 'Remboursé' }
const LIB_DEMANDE: Record<string, string> = { en_attente: 'En attente d’examen par l’agence', acceptee: 'Acceptée', refusee: 'Refusée', annulee: 'Annulée' }
const LIB_RETRAIT: Record<string, string> = { demande: 'Retrait demandé', ecart_en_traitement: 'Retrait en cours de traitement', fonds_disponibles: 'Fonds disponibles à l’agence', execute: 'Retrait payé' }

function Tontine({ onExpire }: { onExpire: () => void }) {
  const { d, err } = useDonnees<Cycle[]>('/api/espace/cycles', onExpire)
  const [ouvert, setOuvert] = useState<number | null>(null)
  if (err) return <div className="alert bad">{err}</div>
  if (!d) return <p>Chargement…</p>
  if (d.length === 0) return <p className="muted">Aucun cycle de tontine.</p>
  return (
    <div style={{ display: 'grid', gap: 12 }}>
      {d.map((c) => (
        <div key={c.id} className="card" style={{ padding: 12 }}>
          <div className="actions" style={{ justifyContent: 'space-between' }}><strong>Cycle {c.numero}</strong><span className="muted">{c.statut === 'en_cours' ? 'En cours' : c.statut === 'clos' ? 'Clos' : 'Retiré'}</span></div>
          <div style={{ fontSize: '1.5rem', fontWeight: 600 }}>{xof(c.montant_collecte)}</div>
          <button className="btn" onClick={() => setOuvert(ouvert === c.id ? null : c.id)}>{ouvert === c.id ? 'Masquer' : 'Suivre ma collecte'}</button>
          {ouvert === c.id && <SuiviCycle id={c.id} onExpire={onExpire} />}
        </div>
      ))}
    </div>
  )
}

function SuiviCycle({ id, onExpire }: { id: number; onExpire: () => void }) {
  const [version, setVersion] = useState(0)
  const [d, setD] = useState<Suivi | null>(null)
  const [err, setErr] = useState<string | null>(null)
  const [mode, setMode] = useState<null | 'verser' | 'retrait'>(null)
  const recharger = () => setVersion((v) => v + 1)
  useEffect(() => {
    let actif = true
    appel<Suivi>('GET', `/api/espace/cycles/${id}/suivi`).then((x) => actif && setD(x)).catch((e) => { if (!actif) return; if (e instanceof ErreurClient && e.status === 401) onExpire(); else setErr(e.message) })
    return () => { actif = false }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [id, version])
  if (err) return <div className="alert bad" style={{ marginTop: 8 }}>{err}</div>
  if (!d) return <p>Chargement…</p>
  const peutVerser = d.statut === 'en_cours'
  const peutDemander = d.statut !== 'retire' && !d.retrait && d.demande_retrait?.statut !== 'en_attente'
  return (
    <div style={{ display: 'grid', gap: 10, marginTop: 10 }}>
      <div className="muted">{d.produit_libelle} · du {fdate(d.date_debut)} au {fdate(d.date_fin)}{d.date_limite !== d.date_fin ? ` (saisie possible jusqu’au ${fdate(d.date_limite)})` : ''}</div>
      {d.progression !== null && (
        <div>
          <div style={{ height: 10, borderRadius: 5, background: 'var(--line, #e5e7eb)', overflow: 'hidden' }}><div style={{ width: `${d.progression}%`, height: '100%', background: 'var(--brand, #0f766e)' }} /></div>
          <div className="muted">{d.progression} % de l’objectif ({xof(d.objectif ?? 0)})</div>
        </div>
      )}
      <div className="actions" style={{ justifyContent: 'space-between' }}>
        <span>Collecté : <strong>{xof(d.montant_collecte)}</strong> sur {d.nb_lignes} ligne(s)</span>
        {d.reste_a_collecter !== null && <span className="muted">Reste : {xof(d.reste_a_collecter)}</span>}
      </div>
      {d.retrait && <div className="alert info">{LIB_RETRAIT[d.retrait.statut] ?? d.retrait.statut} — {xof(d.retrait.montant)}</div>}
      {d.demande_retrait && !d.retrait && (
        <div className="alert info">Demande de retrait : {LIB_DEMANDE[d.demande_retrait.statut] ?? d.demande_retrait.statut}{d.demande_retrait.commentaire ? ` — ${d.demande_retrait.commentaire}` : ''}
          {d.demande_retrait.statut === 'en_attente' && <> <button className="btn" onClick={() => void appel('POST', `/api/espace/demandes-retrait/${d.demande_retrait?.id}/annuler`).then(recharger).catch((e) => setErr(e.message))}>Annuler la demande</button></>}
        </div>
      )}
      <div className="actions">
        {peutVerser && <button className="btn primary" onClick={() => setMode(mode === 'verser' ? null : 'verser')}>Verser par mobile money</button>}
        {peutDemander && <button className="btn" onClick={() => setMode(mode === 'retrait' ? null : 'retrait')}>Demander un retrait</button>}
        <button className="btn" onClick={recharger}>Actualiser</button>
      </div>
      {mode === 'verser' && <VersementMobile suivi={d} onFait={() => { setMode(null); recharger() }} onExpire={onExpire} />}
      {mode === 'retrait' && <DemandeRetrait suivi={d} onFait={() => { setMode(null); recharger() }} />}
      {d.paiements.length > 0 && (
        <div>
          <strong>Mes paiements mobile money</strong>
          <table className="t"><tbody>
            {d.paiements.map((p) => <tr key={p.reference}><td>{fdate(p.cree_le)}</td><td>{p.operateur_libelle}</td><td className="num">{xof(p.montant)}</td><td>{LIB_PAIEMENT[p.statut] ?? p.statut}</td></tr>)}
          </tbody></table>
        </div>
      )}
      <div>
        <strong>Mon carnet</strong>
        <table className="t"><tbody>
          {d.lignes.map((l, i) => <tr key={i}><td>Page {l.page} · ligne {l.no_ligne}</td><td>{fdate(l.date_collecte)}</td><td>{LIB_ORIGINE[l.origine] ?? l.origine}</td><td className="num">{xof(l.montant_collecte)}</td></tr>)}
          {d.lignes.length === 0 && <tr><td className="muted">Aucune ligne pour le moment</td></tr>}
        </tbody></table>
      </div>
    </div>
  )
}

type PaiementSuivi = PaiementMobile & { simulation: boolean; message: string | null }

function VersementMobile({ suivi, onFait, onExpire }: { suivi: Suivi; onFait: () => void; onExpire: () => void }) {
  const ops = useDonnees<Operateurs>('/api/espace/operateurs', onExpire)
  const { erreur, occupe, lancer } = useEnvoi()
  const [f, setF] = useState({ operateur: '', telephone: '', montant: suivi.type_cycle === 3 ? '' : String(suivi.mise_courante) })
  const [cle] = useState(() => `cl-${crypto.randomUUID()}`)
  const [paiement, setPaiement] = useState<PaiementSuivi | null>(null)
  const termine = (statut: string) => { if (statut === 'reussi') window.setTimeout(onFait, 1500) }
  useEffect(() => {
    if (!paiement || paiement.statut !== 'initie') return
    const t = window.setInterval(() => {
      void appel<PaiementMobile>('GET', `/api/espace/paiements/${paiement.reference}`).then((p) => { setPaiement((x) => (x ? { ...x, ...p } : x)); termine(p.statut) }).catch(() => {})
    }, 3000)
    return () => window.clearInterval(t)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [paiement?.reference, paiement?.statut])
  const simuler = (issue: 'succes' | 'echec') => void lancer(async () => {
    if (!paiement) return
    const p = await appel<PaiementMobile>('POST', `/api/espace/paiements/${paiement.reference}/simuler`, { issue })
    setPaiement({ ...paiement, ...p })
    termine(p.statut)
  })
  if (paiement) {
    return (
      <div className="card" style={{ padding: 12, display: 'grid', gap: 8 }}>
        <strong>Paiement {paiement.reference} — {LIB_PAIEMENT[paiement.statut] ?? paiement.statut}</strong>
        <div>{xof(paiement.montant)} via {paiement.operateur_libelle}</div>
        {paiement.statut === 'initie' && <div className="alert info">{paiement.message ?? 'Confirmez le paiement sur votre téléphone.'}</div>}
        {paiement.statut === 'initie' && paiement.simulation && (
          <div className="actions"><button className="btn primary" disabled={occupe} onClick={() => simuler('succes')}>Simuler : paiement réussi</button><button className="btn" disabled={occupe} onClick={() => simuler('echec')}>Simuler : paiement refusé</button></div>
        )}
        {paiement.statut === 'reussi' && <div className="alert info">Versement inscrit sur votre carnet.</div>}
        {['echoue', 'expire'].includes(paiement.statut) && <div className="alert bad">{paiement.motif ?? 'Le paiement n’a pas abouti.'}</div>}
        {paiement.statut === 'a_rembourser' && <div className="alert bad">Votre versement n’a pas pu être inscrit au carnet : l’agence va vous le rembourser.</div>}
        {erreur && <div className="alert bad" role="alert">{erreur}</div>}
        {paiement.statut !== 'initie' && <button className="btn" onClick={onFait}>Fermer</button>}
      </div>
    )
  }
  return (
    <Formulaire titre="Verser par mobile money" erreur={erreur} occupe={occupe} bouton="Payer"
      onSubmit={() => void lancer(async () => { setPaiement(await appel<PaiementSuivi>('POST', '/api/espace/paiements', { cycle_id: suivi.id, operateur: f.operateur, telephone: f.telephone.replace(/\s/g, ''), montant: Number(f.montant), cle })) })}>
      {ops.d?.mode === 'simulation' && <div className="alert info">Mode démonstration : aucun argent réel n’est débité.</div>}
      <label>Opérateur<select className="input" value={f.operateur} onChange={(e) => setF({ ...f, operateur: e.target.value })} required><option value="">— choisir —</option>{ops.d?.operateurs.map((o) => <option key={o.code} value={o.code}>{o.libelle}</option>)}</select></label>
      <label>Numéro mobile money<input className="input" inputMode="tel" value={f.telephone} onChange={(e) => setF({ ...f, telephone: e.target.value })} placeholder="+228 90 12 34 56" required /></label>
      <label>Montant (F)<input className="input" type="number" min={suivi.type_cycle === 3 ? 1 : suivi.mise_courante} step={suivi.type_cycle === 3 ? 1 : suivi.mise_courante} value={f.montant} onChange={(e) => setF({ ...f, montant: e.target.value })} required /></label>
      {suivi.type_cycle !== 3 && <div className="muted">Le montant doit être un multiple de votre mise ({xof(suivi.mise_courante)}).</div>}
    </Formulaire>
  )
}

function DemandeRetrait({ suivi, onFait }: { suivi: Suivi; onFait: () => void }) {
  const ops = useDonnees<Operateurs>('/api/espace/operateurs', () => {})
  const { erreur, occupe, lancer } = useEnvoi()
  const [f, setF] = useState({ canal: 'agence', operateur: '', telephone: '', motif: '' })
  return (
    <Formulaire titre="Demander un retrait" erreur={erreur} occupe={occupe} bouton="Envoyer ma demande"
      onSubmit={() => void lancer(async () => {
        await appel('POST', '/api/espace/demandes-retrait', { cycle_id: suivi.id, canal: f.canal, operateur: f.canal === 'mobile_money' ? f.operateur : null, telephone: f.canal === 'mobile_money' ? f.telephone.replace(/\s/g, '') : null, motif: f.motif.trim() || null })
        onFait()
      })}>
      <div className="muted">Votre demande est examinée par l’agence : votre cycle n’est clôturé qu’après son accord.{suivi.statut === 'en_cours' ? ' Un retrait avant la fin du cycle le clôture.' : ''}</div>
      <label>Paiement souhaité<select className="input" value={f.canal} onChange={(e) => setF({ ...f, canal: e.target.value })}><option value="agence">En agence</option><option value="mobile_money">Par mobile money</option></select></label>
      {f.canal === 'mobile_money' && (
        <>
          <label>Opérateur<select className="input" value={f.operateur} onChange={(e) => setF({ ...f, operateur: e.target.value })} required><option value="">— choisir —</option>{ops.d?.operateurs.map((o) => <option key={o.code} value={o.code}>{o.libelle}</option>)}</select></label>
          <label>Numéro mobile money<input className="input" inputMode="tel" value={f.telephone} onChange={(e) => setF({ ...f, telephone: e.target.value })} required /></label>
        </>
      )}
      <label>Motif (facultatif)<input className="input" value={f.motif} onChange={(e) => setF({ ...f, motif: e.target.value })} maxLength={300} /></label>
    </Formulaire>
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
