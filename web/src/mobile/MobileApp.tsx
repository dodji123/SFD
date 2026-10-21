// Application mobile du collecteur (PWA) : cycles à collecter, saisie rapide, file hors ligne, refus à corriger.
import { useCallback, useEffect, useMemo, useState } from 'react'
import { api, ApiError } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { MotDePasse } from '../components/ui'
import { ChangementObligatoire } from '../pages/MotDePasse'
import {
  demarrerSynchro, ecrireCache, enregistrer, lireCache, marquerReseau, reessayer, retirer, sessionRetablie, synchroniser, useFile, viderCache,
  type CycleCollecte, type Operation,
} from './file'
import './mobile.css'

type Onglet = 'collecte' | 'envoi' | 'refus'

const CODES: Record<string, { titre: string; conseil: string }> = {
  hors_delai: { titre: 'Hors délai', conseil: 'Le cycle est terminé. Demandez une prolongation au chef d\'agence, puis réessayez.' },
  cycle_clos: { titre: 'Cycle clos', conseil: 'Ce cycle est clôturé : la collecte ne peut plus y être ajoutée. Voyez le chef d\'agence.' },
  avant_debut: { titre: 'Avant le début du cycle', conseil: 'La date saisie précède le début du cycle. Abandonnez et ressaisissez avec la bonne date.' },
  droit_agence: { titre: 'Droit refusé', conseil: 'Ce cycle n\'est pas dans votre périmètre. Abandonnez cette saisie.' },
  montant_invalide: { titre: 'Montant invalide', conseil: 'Abandonnez et ressaisissez le bon montant.' },
  depasse_reste: { titre: 'Dépasse l\'encours', conseil: 'Le cycle a déjà reçu d\'autres collectes. Abandonnez ou ressaisissez un montant plus petit.' },
  date_future: { titre: 'Date dans le futur', conseil: 'L\'horloge du téléphone est peut-être décalée. Abandonnez et ressaisissez.' },
  livret_plein: { titre: 'Livret plein', conseil: 'Toutes les lignes du livret sont utilisées. Voyez le chef d\'agence.' },
  lot_refuse: { titre: 'Envoi refusé', conseil: 'Le serveur a refusé la demande. Réessayez plus tard ou abandonnez.' },
}
const libelleCode = (c?: string) => CODES[c ?? '']?.titre ?? 'Refusée'

interface Donnees { cycles: CycleCollecte[]; majLe: number; horsLigne: boolean }

export default function MobileApp() {
  const { user, chargement } = useSession()
  useEffect(() => { document.title = 'SFD Collecte' }, [])
  useEffect(() => { demarrerSynchro() }, [])
  if (chargement) return <div className="m-centre">Chargement…</div>
  if (!user) return <Connexion />
  if (user.doit_changer_mdp) return <ChangementObligatoire />
  if (user.role !== 'agent' && user.role !== 'collectrice') return <Interdit />
  return <Principal />
}

// ------------------------------------------------------------------ connexion
function Connexion() {
  const { login } = useSession()
  const f = useFile()
  const [l, setL] = useState('')
  const [p, setP] = useState('')
  const [erreur, setErreur] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const attente = f.ops.filter((o) => o.etat === 'attente').length
  const refus = f.ops.filter((o) => o.etat === 'refusee').length
  async function envoyer() {
    setBusy(true)
    setErreur(null)
    try {
      await login(l.trim(), p)
      sessionRetablie()
    } catch (e) {
      setErreur(e instanceof ApiError ? e.message : 'Connexion impossible')
    } finally {
      setBusy(false)
    }
  }
  return (
    <div className="m-app m-login">
      <form onSubmit={(e) => { e.preventDefault(); void envoyer() }}>
        <h1>SFD Collecte</h1>
        {(attente > 0 || refus > 0) && (
          <p className="m-bandeau warn">
            {attente > 0 && `${attente} collecte(s) à synchroniser sur ce téléphone. `}
            {refus > 0 && `${refus} refusée(s) à corriger. `}Connectez-vous pour les envoyer.
          </p>
        )}
        {erreur && <p className="m-bandeau bad" role="alert">{erreur}</p>}
        <label>Identifiant<input className="input" value={l} onChange={(e) => setL(e.target.value)} autoComplete="username" autoCapitalize="none" required /></label>
        <label>Mot de passe<MotDePasse value={p} onChange={(e) => setP(e.target.value)} autoComplete="current-password" required /></label>
        <button className="btn btn-primary m-gros" disabled={busy || !l || !p}>{busy ? 'Connexion…' : 'Se connecter'}</button>
        <p className="muted">La connexion demande le réseau.</p>
      </form>
    </div>
  )
}

function Interdit() {
  const { logout } = useSession()
  return (
    <div className="m-app m-login">
      <h1>SFD Collecte</h1>
      <p className="m-bandeau warn">Cette application est réservée aux agents et collectrices. Utilisez l'interface bureau.</p>
      <button className="btn m-gros" onClick={logout}>Se déconnecter</button>
    </div>
  )
}

// ------------------------------------------------------------------ écran principal
function Principal() {
  const { user, logout } = useSession()
  const f = useFile()
  const [onglet, setOnglet] = useState<Onglet>('collecte')
  const [donnees, setDonnees] = useState<Donnees | null>(null)
  const [chargeErreur, setChargeErreur] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const cle = `cycles:${user?.id}`

  const charger = useCallback(async () => {
    try {
      const cycles = await api.get<CycleCollecte[]>('/api/cycles', { statut: 'en_cours', limit: 500, tri: 'client' })
      const d = { cycles, majLe: Date.now(), horsLigne: false }
      setDonnees(d)
      setChargeErreur(null)
      void ecrireCache(cle, d).catch(() => {})
    } catch (e) {
      if (e instanceof ApiError && (e.status === 0 || e.status >= 500)) marquerReseau(false)
      const cache = await lireCache<Donnees>(cle).catch(() => null)
      if (cache) setDonnees({ ...cache, horsLigne: true })
      else setChargeErreur(e instanceof ApiError ? e.message : 'Chargement impossible')
    }
  }, [cle])

  useEffect(() => { void charger() }, [charger])
  // les restes à collecter changent après une synchro réussie
  useEffect(() => { if (f.derniereSynchro) void charger() }, [f.derniereSynchro, charger])
  useEffect(() => { if (!message) return; const t = window.setTimeout(() => setMessage(null), 3500); return () => window.clearTimeout(t) }, [message])

  const attente = f.ops.filter((o) => o.etat === 'attente')
  const refus = f.ops.filter((o) => o.etat === 'refusee')

  async function quitter() {
    if (attente.length + refus.length > 0 && !window.confirm(`${attente.length + refus.length} saisie(s) restent sur ce téléphone et seront envoyées à votre prochaine connexion. Se déconnecter ?`)) return
    await viderCache().catch(() => {})       // la file des saisies est conservée, pas la liste des clients
    logout()
  }

  return (
    <div className="m-app">
      <header className="m-entete">
        <div>
          <strong>{user?.nom}</strong>
          <span className={`m-reseau ${f.reseau ? 'ok' : 'hors'}`}>{f.reseau ? 'En ligne' : 'Hors ligne'}</span>
        </div>
        <button className="btn btn-sm" onClick={() => void quitter()}>Quitter</button>
      </header>
      {(attente.length > 0 || f.enCours) && (
        <button className="m-bandeau warn m-sync" onClick={() => void synchroniser()} disabled={f.enCours}>
          {f.enCours ? 'Synchronisation…' : `${attente.length} à synchroniser${f.reseau ? ' — envoyer maintenant' : ' — en attente du réseau'}`}
        </button>
      )}
      {f.sessionExpiree && <p className="m-bandeau bad">Session expirée : reconnectez-vous pour envoyer vos saisies (elles sont conservées).</p>}
      {message && <p className="m-bandeau ok" role="status">{message}</p>}
      <main>
        {onglet === 'collecte' && (
          <Collecte donnees={donnees} erreur={chargeErreur} ops={f.ops} onRecharger={() => void charger()}
            onSaisi={(m) => setMessage(m)} />
        )}
        {onglet === 'envoi' && <Envoi ops={attente} />}
        {onglet === 'refus' && <Refus ops={refus} />}
      </main>
      <nav className="m-nav">
        <button className={onglet === 'collecte' ? 'actif' : ''} onClick={() => setOnglet('collecte')}>À collecter</button>
        <button className={onglet === 'envoi' ? 'actif' : ''} onClick={() => setOnglet('envoi')}>
          À envoyer{attente.length > 0 && <span className="m-pastille warn">{attente.length}</span>}
        </button>
        <button className={onglet === 'refus' ? 'actif' : ''} onClick={() => setOnglet('refus')}>
          Refus{refus.length > 0 && <span className="m-pastille bad">{refus.length}</span>}
        </button>
      </nav>
    </div>
  )
}

// ------------------------------------------------------------------ cycles du jour et saisie
function Collecte({ donnees, erreur, ops, onRecharger, onSaisi }: {
  donnees: Donnees | null; erreur: string | null; ops: Operation[]; onRecharger: () => void; onSaisi: (m: string) => void
}) {
  const [q, setQ] = useState('')
  const [choisi, setChoisi] = useState<CycleCollecte | null>(null)
  const filtres = useMemo(() => {
    const s = q.trim().toLowerCase()
    return (donnees?.cycles ?? []).filter((c) => !s || c.client.toLowerCase().includes(s) || c.numero.toLowerCase().includes(s))
  }, [donnees, q])
  const enFile = useMemo(() => {
    const m = new Map<number, number>()
    for (const o of ops) m.set(o.cycle_id, (m.get(o.cycle_id) ?? 0) + o.montant_collecte)
    return m
  }, [ops])

  if (erreur) return <p className="m-bandeau bad">{erreur} <button className="btn btn-sm" onClick={onRecharger}>Réessayer</button></p>
  if (!donnees) return <p className="m-centre">Chargement des cycles…</p>
  return (
    <>
      {donnees.horsLigne && <p className="m-bandeau info">Liste enregistrée le {new Date(donnees.majLe).toLocaleString('fr-FR', { dateStyle: 'short', timeStyle: 'short' })} (hors ligne).</p>}
      <div className="m-recherche">
        <input className="input" type="search" placeholder="Client ou n° de cycle" value={q} onChange={(e) => setQ(e.target.value)} />
        <button className="btn" onClick={onRecharger} aria-label="Actualiser">↻</button>
      </div>
      <p className="muted m-compte">{filtres.length} cycle(s) en cours</p>
      <ul className="m-liste">
        {filtres.map((c) => {
          const local = enFile.get(c.id)
          return (
            <li key={c.id}>
              <button className="m-carte" onClick={() => setChoisi(c)}>
                <span className="m-carte-haut"><strong>{c.client}</strong><span>{xof(c.mise_courante)}</span></span>
                <span className="muted">{c.numero} · {c.produit}{c.type_cycle === 3 ? ' · libre' : ''}</span>
                <span className="m-carte-bas">
                  <span>Reste {c.reste_a_collecter === null ? '—' : xof(c.reste_a_collecter)}</span>
                  {local ? <span className="m-pastille warn">+{xof(local)} à envoyer</span> : null}
                </span>
              </button>
            </li>
          )
        })}
      </ul>
      {filtres.length === 0 && <p className="m-centre muted">Aucun cycle.</p>}
      {choisi && <Saisie cycle={choisi} onFermer={() => setChoisi(null)} onSaisi={(m) => { setChoisi(null); onSaisi(m) }} />}
    </>
  )
}

function Saisie({ cycle, onFermer, onSaisi }: { cycle: CycleCollecte; onFermer: () => void; onSaisi: (m: string) => void }) {
  const [montant, setMontant] = useState(String(cycle.mise_courante))
  const [jour, setJour] = useState(aujourdhui())
  const [erreur, setErreur] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const libre = cycle.type_cycle === 3

  async function valider() {
    const n = Number(montant)
    if (!Number.isInteger(n) || n <= 0) return setErreur('Saisissez un montant entier positif.')
    if (!libre && n % cycle.mise_courante !== 0) return setErreur(`Le montant doit être un multiple de la mise (${xof(cycle.mise_courante)}).`)
    if (jour > aujourdhui()) return setErreur('La date ne peut pas être dans le futur.')
    setBusy(true)
    try {
      await enregistrer({ cycle_id: cycle.id, date_collecte: jour, montant_collecte: n, client: cycle.client, cycle: cycle.numero, produit: cycle.produit })
      onSaisi(`${xof(n)} enregistré pour ${cycle.client}`)
    } catch {
      setErreur('Impossible d\'écrire sur le téléphone (stockage plein ou bloqué).')
      setBusy(false)
    }
  }

  return (
    <div className="m-feuille-fond" onClick={onFermer}>
      <form className="m-feuille" onClick={(e) => e.stopPropagation()} onSubmit={(e) => { e.preventDefault(); void valider() }}>
        <h2>{cycle.client}</h2>
        <p className="muted">{cycle.numero} · {cycle.produit} · mise {xof(cycle.mise_courante)}</p>
        {erreur && <p className="m-bandeau bad" role="alert">{erreur}</p>}
        <label>Montant collecté (F)
          <input className="input m-montant" inputMode="numeric" pattern="[0-9]*" value={montant} onChange={(e) => setMontant(e.target.value.replace(/\D/g, ''))} autoFocus />
        </label>
        {!libre && (
          <div className="m-rapide">
            {[1, 2, 3, 5].map((k) => <button type="button" className="btn" key={k} onClick={() => setMontant(String(cycle.mise_courante * k))}>{k > 1 ? `${k} ×` : 'Mise'}</button>)}
          </div>
        )}
        <label>Date de collecte
          <input className="input" type="date" value={jour} max={aujourdhui()} onChange={(e) => setJour(e.target.value)} />
        </label>
        {jour > cycle.date_limite && <p className="m-bandeau warn">Après la fin du cycle ({fdate(cycle.date_limite)}) : le serveur la refusera.</p>}
        <div className="m-actions">
          <button type="button" className="btn m-gros" onClick={onFermer}>Annuler</button>
          <button className="btn btn-primary m-gros" disabled={busy}>Enregistrer</button>
        </div>
      </form>
    </div>
  )
}

// ------------------------------------------------------------------ file d'attente et refus
function Ligne({ o, children }: { o: Operation; children?: React.ReactNode }) {
  return (
    <li className="m-op">
      <span className="m-carte-haut"><strong>{o.client}</strong><span>{xof(o.montant_collecte)}</span></span>
      <span className="muted">{o.cycle} · {o.produit} · collecte du {fdate(o.date_collecte)}</span>
      {children}
    </li>
  )
}

function Envoi({ ops }: { ops: Operation[] }) {
  if (ops.length === 0) return <p className="m-centre muted">Tout est synchronisé.</p>
  return (
    <ul className="m-liste">
      {ops.map((o) => (
        <Ligne key={o.cle} o={o}>
          <span className="m-carte-bas">
            <span className="muted">Saisi à {new Date(o.cree_le).toLocaleTimeString('fr-FR', { timeStyle: 'short' })}</span>
            <button className="btn btn-sm btn-danger" onClick={() => { if (window.confirm('Annuler cette saisie ?')) void retirer(o.cle) }}>Annuler</button>
          </span>
        </Ligne>
      ))}
    </ul>
  )
}

function Refus({ ops }: { ops: Operation[] }) {
  if (ops.length === 0) return <p className="m-centre muted">Aucune saisie refusée.</p>
  return (
    <ul className="m-liste">
      {ops.map((o) => (
        <Ligne key={o.cle} o={o}>
          <span className="m-bandeau bad"><strong>{libelleCode(o.code)}</strong> — {o.motif}</span>
          <span className="muted">{CODES[o.code ?? '']?.conseil}</span>
          <span className="m-actions">
            <button className="btn btn-sm btn-danger" onClick={() => { if (window.confirm('Abandonner cette saisie ? Elle ne sera pas enregistrée.')) void retirer(o.cle) }}>Abandonner</button>
            <button className="btn btn-sm btn-primary" onClick={() => void reessayer(o.cle)}>Réessayer</button>
          </span>
        </Ligne>
      ))}
    </ul>
  )
}
