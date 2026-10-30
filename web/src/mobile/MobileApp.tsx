// Application mobile du collecteur (PWA) : clients de la zone, cycles, saisie rapide, création sur le terrain, suivi des validations.
import { useCallback, useEffect, useMemo, useState } from 'react'
import { api, ApiError } from '../lib/api'
import { aujourdhui, date as fdate, decaler, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { ChangementObligatoire } from '../pages/MotDePasse'
import { EnrolementTotp } from '../pages/Totp'
import {
  appliquerStatuts, demarrerSynchro, ecrireCache, enregistrer, lireCache, marquerReseau, reessayer, retirer, sessionRetablie, synchroniser, useFile, viderCache,
  type ClientVue, type CycleVue, type EtatOp, type Operation, type Produit, type Ref, type Tournee,
} from './file'
import { BoutonScanner, lireQr } from '../components/Qr'
import ControleApp from './Controle'
import Terrain from './Terrain'
import { demarrerSynchroConstats, sessionRetablieC } from './fileConstats'
import './mobile.css'

type Onglet = 'cycles' | 'clients' | 'credit' | 'suivi'

const CODES: Record<string, { titre: string; conseil: string }> = {
  rejet_operateur: { titre: 'Rejetée par l\'opérateur', conseil: 'Voyez le motif ci-dessus, puis ressaisissez si besoin.' },
  hors_delai: { titre: 'Hors délai', conseil: 'Le cycle est terminé. Demandez une prolongation au chef d\'agence, puis ressaisissez.' },
  cycle_clos: { titre: 'Cycle clos', conseil: 'Ce cycle est clôturé : la collecte ne peut plus y être ajoutée.' },
  avant_debut: { titre: 'Avant le début du cycle', conseil: 'Ressaisissez avec la bonne date.' },
  droit_agence: { titre: 'Droit refusé', conseil: 'Cet élément n\'est pas dans votre périmètre. Abandonnez cette saisie.' },
  hors_zone: { titre: 'Hors de votre zone', conseil: 'Vous ne travaillez que sur les clients de votre zone. Abandonnez cette saisie.' },
  montant_invalide: { titre: 'Montant invalide', conseil: 'Ressaisissez le bon montant.' },
  depasse_reste: { titre: 'Dépasse l\'encours', conseil: 'Le cycle a déjà reçu d\'autres collectes. Ressaisissez un montant plus petit.' },
  date_future: { titre: 'Date dans le futur', conseil: 'L\'horloge du téléphone est peut-être décalée. Ressaisissez.' },
  livret_plein: { titre: 'Livret plein', conseil: 'Toutes les lignes du livret sont utilisées. Voyez le chef d\'agence.' },
  dependance: { titre: 'Opération liée rejetée', conseil: 'Le client ou le cycle dont elle dépend n\'a pas été accepté.' },
  format: { titre: 'Saisie incomplète', conseil: 'Ressaisissez en vérifiant les champs.' },
  produit_invalide: { titre: 'Produit invalide', conseil: 'Choisissez un autre produit.' },
  lot_refuse: { titre: 'Envoi refusé', conseil: 'Le serveur a refusé la demande. Réessayez plus tard ou abandonnez.' },
}
const ETATS: Record<EtatOp, { lib: string; ton: string }> = {
  attente: { lib: 'À envoyer', ton: 'warn' }, envoyee: { lib: 'En attente de validation', ton: 'info' },
  validee: { lib: 'Validée', ton: 'ok' }, rejetee: { lib: 'Rejetée', ton: 'bad' }, refusee: { lib: 'Refusée', ton: 'bad' },
}

interface Donnees { t: Tournee; majLe: number; horsLigne: boolean }
const actif = (o: Operation) => o.etat === 'attente' || o.etat === 'envoyee'

export default function MobileApp() {
  const { user, chargement, can } = useSession()
  useEffect(() => { document.title = 'SFD Collecte' }, [])
  useEffect(() => { demarrerSynchro(); demarrerSynchroConstats() }, [])
  if (chargement) return <div className="m-centre">Chargement…</div>
  if (!user) return <Connexion />
  if (user.doit_changer_mdp) return <ChangementObligatoire />
  if (user.totp_a_enroler) return <EnrolementTotp />
  if (user.role === 'agent' || user.role === 'collectrice') return <Principal />
  if (can('livret:controler')) return <ControleApp />      // contrôleurs de livrets (chef d'agence, directeur, coordinateur…)
  return <Interdit />
}

// ------------------------------------------------------------------ connexion
function Connexion() {
  const { login, loginTotp } = useSession()
  const f = useFile()
  const [l, setL] = useState('')
  const [p, setP] = useState('')
  const [erreur, setErreur] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [etape2, setEtape2] = useState(false)
  const [code, setCode] = useState('')
  const attente = f.ops.filter((o) => o.etat === 'attente').length
  async function envoyer() {
    setBusy(true)
    setErreur(null)
    try {
      if (etape2) await loginTotp(code.trim())
      else if (await login(l.trim(), p) === 'totp') { setEtape2(true); setP(''); return }
      sessionRetablie()
      sessionRetablieC()
    } catch (e) {
      setErreur(e instanceof ApiError ? e.message : 'Connexion impossible')
      if (etape2 && e instanceof ApiError && (e.status === 429 || e.message.startsWith('Défi'))) { setEtape2(false); setCode('') }
    } finally {
      setBusy(false)
    }
  }
  return (
    <div className="m-app m-login">
      <form onSubmit={(e) => { e.preventDefault(); void envoyer() }}>
        <h1>SFD Collecte</h1>
        {attente > 0 && <p className="m-bandeau warn">{attente} saisie(s) à synchroniser sur ce téléphone : connectez-vous pour les envoyer.</p>}
        {erreur && <p className="m-bandeau bad" role="alert">{erreur}</p>}
        {etape2 ? (<>
          <p className="muted">Second facteur : code à 6 chiffres de votre application d'authentification, ou code de secours.</p>
          <label>Code<input className="input" value={code} onChange={(e) => setCode(e.target.value)} autoComplete="one-time-code" autoCapitalize="characters" autoFocus required /></label>
          <button className="btn btn-primary m-gros" disabled={busy || code.trim().length < 6}>{busy ? 'Vérification…' : 'Valider'}</button>
          <button type="button" className="btn m-gros" onClick={() => { setEtape2(false); setCode(''); setErreur(null) }}>Retour</button>
        </>) : (<>
        <label>Identifiant<input className="input" value={l} onChange={(e) => setL(e.target.value)} autoComplete="username" autoCapitalize="none" required /></label>
        <label>Mot de passe<input className="input" type="password" value={p} onChange={(e) => setP(e.target.value)} autoComplete="current-password" required /></label>
        <button className="btn btn-primary m-gros" disabled={busy || !l || !p}>{busy ? 'Connexion…' : 'Se connecter'}</button>
        </>)}
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
      <p className="m-bandeau warn">Cette application est réservée aux agents, collectrices et contrôleurs de livrets. Utilisez l'interface bureau.</p>
      <button className="btn m-gros" onClick={logout}>Se déconnecter</button>
    </div>
  )
}

// ------------------------------------------------------------------ vue fusionnée : serveur + opérations locales pas encore validées
function fusionner(t: Tournee | null, ops: Operation[]) {
  const enCours = ops.filter(actif)
  const clients: ClientVue[] = [...(t?.clients ?? [])]
  for (const o of enCours.filter((x) => x.type === 'client')) {
    const p = o.payload as { nom: string; telephone?: string | null; zone_id?: number }
    clients.push({ id: o.cle, nom: p.nom, telephone: p.telephone ?? null, zone_id: p.zone_id ?? t?.zones[0]?.id ?? null, local: true })
  }
  const nom = (ref: Ref) => clients.find((c) => c.id === ref)?.nom ?? '?'
  const cycles: CycleVue[] = [...(t?.cycles ?? [])]
  for (const o of enCours.filter((x) => x.type === 'cycle')) {
    const p = o.payload as { client: Ref; produit_id: number; mise: number; type_cycle?: number; date_debut: string; date_fin: string }
    const prod = t?.produits.find((x) => x.id === p.produit_id)
    cycles.push({ id: o.cle, client_id: p.client, numero: 'Nouveau cycle', client: nom(p.client), produit: prod?.code ?? '?', type_cycle: p.type_cycle ?? prod?.type_cycle ?? 3,
      mise_courante: p.mise, reste_a_collecter: null, date_debut: p.date_debut, date_fin: p.date_fin, date_limite: p.date_fin, local: true })
  }
  const clotures = new Set(enCours.filter((o) => o.type === 'cloture').map((o) => String((o.payload as { cycle: Ref }).cycle)))
  const enFile = new Map<string, number>()
  for (const o of enCours.filter((x) => x.type === 'collecte')) {
    const k = String((o.payload as { cycle: Ref }).cycle)
    enFile.set(k, (enFile.get(k) ?? 0) + (o.payload as { montant_collecte: number }).montant_collecte)
  }
  return { clients, cycles, clotures, enFile }
}

// ------------------------------------------------------------------ écran principal
function Principal() {
  const { user, logout } = useSession()
  const f = useFile()
  const [onglet, setOnglet] = useState<Onglet>('cycles')
  const [donnees, setDonnees] = useState<Donnees | null>(null)
  const [chargeErreur, setChargeErreur] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const cle = `tournee:${user?.id}`

  const charger = useCallback(async () => {
    try {
      const t = await api.get<Tournee>('/api/collecte/mobile/tournee')
      const d = { t, majLe: Date.now(), horsLigne: false }
      setDonnees(d)
      setChargeErreur(null)
      void ecrireCache(cle, d).catch(() => {})
      void appliquerStatuts(t.operations)
    } catch (e) {
      if (e instanceof ApiError && (e.status === 0 || e.status >= 500)) marquerReseau(false)
      const cache = await lireCache<Donnees>(cle).catch(() => null)
      if (cache) setDonnees({ ...cache, horsLigne: true })
      else setChargeErreur(e instanceof ApiError ? e.message : 'Chargement impossible')
    }
  }, [cle])

  useEffect(() => { void charger() }, [charger])
  // les restes à collecter et les décisions de l'opérateur changent après une synchro ; on interroge aussi toutes les minutes
  useEffect(() => { if (f.derniereSynchro) void charger() }, [f.derniereSynchro, charger])
  const attendDecision = f.ops.some((o) => o.etat === 'envoyee')
  useEffect(() => {
    if (!attendDecision) return
    const t = window.setInterval(() => { if (!document.hidden) void charger() }, 60000)
    return () => window.clearInterval(t)
  }, [attendDecision, charger])
  useEffect(() => { if (!message) return; const t = window.setTimeout(() => setMessage(null), 3500); return () => window.clearTimeout(t) }, [message])

  const vue = useMemo(() => fusionner(donnees?.t ?? null, f.ops), [donnees, f.ops])
  const aEnvoyer = f.ops.filter((o) => o.etat === 'attente').length
  const aRevoir = f.ops.filter((o) => o.etat === 'refusee' || o.etat === 'rejetee').length

  async function quitter() {
    const restent = f.ops.filter((o) => o.etat === 'attente' || o.etat === 'refusee').length
    if (restent > 0 && !window.confirm(`${restent} saisie(s) restent sur ce téléphone et seront envoyées à votre prochaine connexion. Se déconnecter ?`)) return
    await viderCache().catch(() => {})       // la file des saisies est conservée, pas la liste des clients
    logout()
  }

  const t = donnees?.t
  return (
    <div className="m-app">
      <header className="m-entete">
        <div>
          <strong>{user?.nom}</strong>
          <span className={`m-reseau ${f.reseau ? 'ok' : 'hors'}`}>{f.reseau ? 'En ligne' : 'Hors ligne'}{t && t.zones.length > 0 ? ` · zone ${t.zones.map((z) => z.code).join(', ')}` : ''}</span>
        </div>
        <button className="btn btn-sm" onClick={() => void quitter()}>Quitter</button>
      </header>
      {(aEnvoyer > 0 || f.enCours) && (
        <button className="m-bandeau warn m-sync" onClick={() => void synchroniser()} disabled={f.enCours}>
          {f.enCours ? 'Synchronisation…' : `${aEnvoyer} à synchroniser${f.reseau ? ' — envoyer maintenant' : ' — en attente du réseau'}`}
        </button>
      )}
      {f.sessionExpiree && <p className="m-bandeau bad">Session expirée : reconnectez-vous pour envoyer vos saisies (elles sont conservées).</p>}
      {message && <p className="m-bandeau ok" role="status">{message}</p>}
      <main>
        {chargeErreur && <p className="m-bandeau bad">{chargeErreur} <button className="btn btn-sm" onClick={() => void charger()}>Réessayer</button></p>}
        {!donnees && !chargeErreur && <p className="m-centre">Chargement de votre zone…</p>}
        {donnees && donnees.horsLigne && <p className="m-bandeau info">Données enregistrées le {new Date(donnees.majLe).toLocaleString('fr-FR', { dateStyle: 'short', timeStyle: 'short' })} (hors ligne).</p>}
        {donnees && t && t.zones.length === 0 && <p className="m-bandeau warn">Aucune zone ne vous est affectée : voyez le chef d'agence.</p>}
        {donnees && t && t.zones.length > 0 && onglet === 'cycles' && <Cycles vue={vue} onRecharger={() => void charger()} onSaisi={setMessage} />}
        {donnees && t && t.zones.length > 0 && onglet === 'clients' && <Clients vue={vue} t={t} onSaisi={setMessage} />}
        {donnees && t && t.zones.length > 0 && onglet === 'credit' && <Terrain clients={vue.clients} onSaisi={setMessage} />}
        {onglet === 'suivi' && <Suivi ops={f.ops} />}
      </main>
      <nav className="m-nav">
        <button className={onglet === 'cycles' ? 'actif' : ''} onClick={() => setOnglet('cycles')}>Cycles</button>
        <button className={onglet === 'clients' ? 'actif' : ''} onClick={() => setOnglet('clients')}>Clients</button>
        <button className={onglet === 'credit' ? 'actif' : ''} onClick={() => setOnglet('credit')}>Crédit</button>
        <button className={onglet === 'suivi' ? 'actif' : ''} onClick={() => setOnglet('suivi')}>
          Suivi{aRevoir > 0 ? <span className="m-pastille bad">{aRevoir}</span> : aEnvoyer > 0 ? <span className="m-pastille warn">{aEnvoyer}</span> : null}
        </button>
      </nav>
    </div>
  )
}

type Vue = ReturnType<typeof fusionner>

// ------------------------------------------------------------------ cycles et saisie de collecte
function Cycles({ vue, onRecharger, onSaisi }: { vue: Vue; onRecharger: () => void; onSaisi: (m: string) => void }) {
  const [produit, setProduit] = useState('')
  const [q, setQ] = useState('')
  const [choisi, setChoisi] = useState<CycleVue | null>(null)
  const produits = useMemo(() => [...new Set(vue.cycles.map((c) => c.produit))].sort(), [vue.cycles])
  const filtres = useMemo(() => {
    const s = q.trim().toLowerCase()
    return vue.cycles.filter((c) => (!produit || c.produit === produit) && (!s || c.client.toLowerCase().includes(s) || c.numero.toLowerCase().includes(s)))
  }, [vue.cycles, produit, q])
  return (
    <>
      <div className="m-recherche">
        <select className="input" aria-label="Produit" value={produit} onChange={(e) => setProduit(e.target.value)}>
          <option value="">Tous les produits</option>
          {produits.map((p) => <option key={p} value={p}>{p}</option>)}
        </select>
        <input className="input" type="search" placeholder="Nom du client ou n° de cycle" value={q} onChange={(e) => setQ(e.target.value)} />
        <button className="btn" onClick={onRecharger} aria-label="Actualiser">↻</button>
      </div>
      <div className="m-recherche">
        <BoutonScanner libelle="Scanner le QR du cycle" onLu={(t) => setQ(lireQr(t).numero)} />
      </div>
      <p className="muted m-compte">{filtres.length} cycle(s) en cours dans votre zone</p>
      <ul className="m-liste">
        {filtres.map((c) => <li key={String(c.id)}><CarteCycle c={c} vue={vue} onClick={() => setChoisi(c)} /></li>)}
      </ul>
      {filtres.length === 0 && <p className="m-centre muted">Aucun cycle.</p>}
      {choisi && <Saisie cycle={choisi} cloturePrevue={vue.clotures.has(String(choisi.id))} onFermer={() => setChoisi(null)} onSaisi={(m) => { setChoisi(null); onSaisi(m) }} />}
    </>
  )
}

function CarteCycle({ c, vue, onClick }: { c: CycleVue; vue: Vue; onClick: () => void }) {
  const local = vue.enFile.get(String(c.id))
  return (
    <button className="m-carte" onClick={onClick}>
      <span className="m-carte-haut"><strong>{c.client}</strong><span>{xof(c.mise_courante)}</span></span>
      <span className="muted">{c.numero} · {c.produit} · type {c.type_cycle}</span>
      <span className="m-carte-bas">
        <span>{c.local ? 'À valider' : `Reste ${c.reste_a_collecter === null ? '—' : xof(c.reste_a_collecter)}`}</span>
        <span>
          {vue.clotures.has(String(c.id)) && <span className="m-pastille bad">Clôture à valider</span>}
          {local ? <span className="m-pastille warn">+{xof(local)} à valider</span> : null}
        </span>
      </span>
    </button>
  )
}

function Saisie({ cycle, cloturePrevue, onFermer, onSaisi }: { cycle: CycleVue; cloturePrevue: boolean; onFermer: () => void; onSaisi: (m: string) => void }) {
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
      await enregistrer('collecte', { cycle: cycle.id, date_collecte: jour, montant_collecte: n }, `Collecte ${xof(n)} — ${cycle.client}`)
      onSaisi(`${xof(n)} enregistré pour ${cycle.client}`)
    } catch {
      setErreur('Impossible d\'écrire sur le téléphone (stockage plein ou bloqué).')
      setBusy(false)
    }
  }

  async function cloturer() {
    if (!window.confirm(`Clôturer le cycle de ${cycle.client} ? La clôture sera validée par l'opérateur.`)) return
    setBusy(true)
    await enregistrer('cloture', { cycle: cycle.id }, `Clôture du cycle ${cycle.numero} — ${cycle.client}`)
    onSaisi(`Clôture de ${cycle.client} enregistrée`)
  }

  return (
    <div className="m-feuille-fond" onClick={onFermer}>
      <form className="m-feuille" onClick={(e) => e.stopPropagation()} onSubmit={(e) => { e.preventDefault(); void valider() }}>
        <h2>{cycle.client}</h2>
        <p className="muted">{cycle.numero} · {cycle.produit} · mise {xof(cycle.mise_courante)} · type {cycle.type_cycle}</p>
        {cloturePrevue && <p className="m-bandeau warn">Une clôture de ce cycle attend la validation.</p>}
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
        {jour > cycle.date_limite && <p className="m-bandeau warn">Après la fin du cycle ({fdate(cycle.date_limite)}) : l'opérateur ne pourra pas la valider.</p>}
        <div className="m-actions">
          <button type="button" className="btn m-gros" onClick={onFermer}>Annuler</button>
          <button className="btn btn-primary m-gros" disabled={busy}>Enregistrer</button>
        </div>
        {!cloturePrevue && <button type="button" className="btn btn-danger" disabled={busy} onClick={() => void cloturer()}>Clôturer ce cycle</button>}
      </form>
    </div>
  )
}

// ------------------------------------------------------------------ clients, nouveau client, nouveau cycle
function Clients({ vue, t, onSaisi }: { vue: Vue; t: Tournee; onSaisi: (m: string) => void }) {
  const [q, setQ] = useState('')
  const [nouveau, setNouveau] = useState(false)
  const [choisi, setChoisi] = useState<ClientVue | null>(null)
  const [produit, setProduit] = useState('')
  const produits = useMemo(() => [...new Set(vue.cycles.map((c) => c.produit))].sort(), [vue.cycles])
  const filtres = useMemo(() => {
    const s = q.trim().toLowerCase()
    return vue.clients.filter((c) => (!produit || vue.cycles.some((x) => x.client_id === c.id && x.produit === produit))
      && (!s || c.nom.toLowerCase().includes(s) || (c.numero ?? '').toLowerCase().includes(s) || (c.telephone ?? '').includes(s)))
  }, [vue.clients, vue.cycles, q, produit])
  return (
    <>
      <div className="m-recherche">
        <select className="input" aria-label="Produit" value={produit} onChange={(e) => setProduit(e.target.value)}>
          <option value="">Tous les produits</option>
          {produits.map((p) => <option key={p} value={p}>{p}</option>)}
        </select>
        <input className="input" type="search" placeholder="Nom, numéro ou téléphone" value={q} onChange={(e) => setQ(e.target.value)} />
        <button className="btn btn-primary" onClick={() => setNouveau(true)}>+ Client</button>
      </div>
      <p className="muted m-compte">{filtres.length} client(s) de votre zone</p>
      <ul className="m-liste">
        {filtres.map((c) => {
          const n = vue.cycles.filter((x) => x.client_id === c.id).length
          return (
            <li key={String(c.id)}>
              <button className="m-carte" onClick={() => setChoisi(c)}>
                <span className="m-carte-haut"><strong>{c.nom}</strong>{c.local && <span className="m-pastille warn">Nouveau</span>}</span>
                <span className="muted">{c.numero ?? 'Numéro attribué à la validation'}{c.telephone ? ` · ${c.telephone}` : ''}</span>
                <span className="muted">{n} cycle(s) en cours</span>
              </button>
            </li>
          )
        })}
      </ul>
      {nouveau && <NouveauClient zones={t.zones} onFermer={() => setNouveau(false)} onFait={(m) => { setNouveau(false); onSaisi(m) }} />}
      {choisi && <FicheClient client={choisi} vue={vue} produits={t.produits} onFermer={() => setChoisi(null)} onSaisi={(m) => { setChoisi(null); onSaisi(m) }} />}
    </>
  )
}

function NouveauClient({ zones, onFermer, onFait }: { zones: Tournee['zones']; onFermer: () => void; onFait: (m: string) => void }) {
  const [nom, setNom] = useState('')
  const [tel, setTel] = useState('')
  const [zone, setZone] = useState(String(zones[0]?.id ?? ''))
  const [erreur, setErreur] = useState<string | null>(null)
  async function valider() {
    if (nom.trim().length < 2) return setErreur('Saisissez le nom du client.')
    await enregistrer('client', { nom: nom.trim(), telephone: tel.trim() || null, zone_id: Number(zone) }, `Nouveau client — ${nom.trim()}`)
    onFait(`Client ${nom.trim()} enregistré`)
  }
  return (
    <div className="m-feuille-fond" onClick={onFermer}>
      <form className="m-feuille" onClick={(e) => e.stopPropagation()} onSubmit={(e) => { e.preventDefault(); void valider() }}>
        <h2>Nouveau client</h2>
        {erreur && <p className="m-bandeau bad" role="alert">{erreur}</p>}
        <label>Nom et prénoms<input className="input" value={nom} onChange={(e) => setNom(e.target.value)} autoFocus /></label>
        <label>Téléphone<input className="input" type="tel" inputMode="tel" value={tel} onChange={(e) => setTel(e.target.value)} /></label>
        {zones.length > 1 && (
          <label>Zone<select className="input" value={zone} onChange={(e) => setZone(e.target.value)}>{zones.map((z) => <option key={z.id} value={z.id}>{z.code} — {z.libelle}</option>)}</select></label>
        )}
        <p className="muted">Le numéro du client est attribué quand l'opérateur valide.</p>
        <div className="m-actions">
          <button type="button" className="btn m-gros" onClick={onFermer}>Annuler</button>
          <button className="btn btn-primary m-gros">Enregistrer</button>
        </div>
      </form>
    </div>
  )
}

function FicheClient({ client, vue, produits, onFermer, onSaisi }: { client: ClientVue; vue: Vue; produits: Produit[]; onFermer: () => void; onSaisi: (m: string) => void }) {
  const [cycle, setCycle] = useState(false)
  const [saisie, setSaisie] = useState<CycleVue | null>(null)
  const siens = vue.cycles.filter((c) => c.client_id === client.id)
  if (cycle) return <NouveauCycle client={client} produits={produits} onFermer={() => setCycle(false)} onFait={onSaisi} />
  if (saisie) return <Saisie cycle={saisie} cloturePrevue={vue.clotures.has(String(saisie.id))} onFermer={() => setSaisie(null)} onSaisi={onSaisi} />
  return (
    <div className="m-feuille-fond" onClick={onFermer}>
      <div className="m-feuille" onClick={(e) => e.stopPropagation()}>
        <h2>{client.nom}</h2>
        <p className="muted">{client.numero ?? 'Numéro attribué à la validation'}{client.telephone ? ` · ${client.telephone}` : ''}</p>
        <button className="btn btn-primary m-gros" onClick={() => setCycle(true)}>Ouvrir un nouveau cycle</button>
        <p className="muted">Cycles en cours</p>
        <ul className="m-liste">
          {siens.map((c) => <li key={String(c.id)}><CarteCycle c={c} vue={vue} onClick={() => setSaisie(c)} /></li>)}
        </ul>
        {siens.length === 0 && <p className="muted">Aucun cycle en cours.</p>}
        <button className="btn m-gros" onClick={onFermer}>Fermer</button>
      </div>
    </div>
  )
}

function NouveauCycle({ client, produits, onFermer, onFait }: { client: ClientVue; produits: Produit[]; onFermer: () => void; onFait: (m: string) => void }) {
  const [produit, setProduit] = useState(String(produits[0]?.id ?? ''))
  const prod = produits.find((p) => String(p.id) === produit)
  const [type, setType] = useState('')
  const [mise, setMise] = useState('')
  const [debut, setDebut] = useState(aujourdhui())
  const [fin, setFin] = useState(decaler(aujourdhui(), 30))
  const [erreur, setErreur] = useState<string | null>(null)
  const typeEffectif = prod?.type_cycle ? String(prod.type_cycle) : type
  async function valider() {
    const m = Number(mise)
    if (!prod) return setErreur('Choisissez un produit.')
    if (!typeEffectif) return setErreur('Choisissez le type de cycle.')
    if (!Number.isInteger(m) || m <= 0) return setErreur('Saisissez une mise entière positive.')
    if (fin < debut) return setErreur('La fin ne peut pas précéder le début.')
    await enregistrer('cycle', { client: client.id, produit_id: prod.id, mise: m, date_debut: debut, date_fin: fin, ...(prod.type_cycle ? {} : { type_cycle: Number(type) }) },
      `Nouveau cycle ${prod.code} type ${typeEffectif} — ${client.nom}`)
    onFait(`Cycle de ${client.nom} enregistré`)
  }
  return (
    <div className="m-feuille-fond" onClick={onFermer}>
      <form className="m-feuille" onClick={(e) => e.stopPropagation()} onSubmit={(e) => { e.preventDefault(); void valider() }}>
        <h2>Nouveau cycle</h2>
        <p className="muted">{client.nom}</p>
        {erreur && <p className="m-bandeau bad" role="alert">{erreur}</p>}
        <label>Produit<select className="input" value={produit} onChange={(e) => setProduit(e.target.value)}>{produits.map((p) => <option key={p.id} value={p.id}>{p.code} — {p.libelle}</option>)}</select></label>
        <label>Type de cycle
          <select className="input" value={typeEffectif} disabled={!!prod?.type_cycle} onChange={(e) => setType(e.target.value)}>
            <option value="">— choisir —</option>
            <option value="1">Type 1 — mise fixe</option>
            <option value="2">Type 2 — mise modifiable</option>
            <option value="3">Type 3 — mise finale calculée</option>
          </select>
        </label>
        {prod?.type_cycle ? <p className="muted">Type imposé par le produit.</p> : <p className="muted">Libre à chaque cycle.</p>}
        <label>Mise (F)<input className="input" inputMode="numeric" pattern="[0-9]*" value={mise} onChange={(e) => setMise(e.target.value.replace(/\D/g, ''))} /></label>
        <label>Début<input className="input" type="date" value={debut} onChange={(e) => setDebut(e.target.value)} /></label>
        <label>Fin<input className="input" type="date" value={fin} onChange={(e) => setFin(e.target.value)} /></label>
        <div className="m-actions">
          <button type="button" className="btn m-gros" onClick={onFermer}>Annuler</button>
          <button className="btn btn-primary m-gros">Enregistrer</button>
        </div>
      </form>
    </div>
  )
}

// ------------------------------------------------------------------ suivi : état de chaque opération
function Suivi({ ops }: { ops: Operation[] }) {
  const liste = [...ops].sort((a, b) => b.cree_le - a.cree_le)
  if (liste.length === 0) return <p className="m-centre muted">Aucune opération en cours.</p>
  return (
    <ul className="m-liste">
      {liste.map((o) => {
        const e = ETATS[o.etat]
        const c = CODES[o.code ?? '']
        return (
          <li key={o.cle} className="m-op">
            <span className="m-carte-haut"><strong>{o.libelle}</strong><span className={`m-pastille ${e.ton}`}>{e.lib}</span></span>
            <span className="muted">Saisi le {new Date(o.cree_le).toLocaleString('fr-FR', { dateStyle: 'short', timeStyle: 'short' })}</span>
            {(o.etat === 'rejetee' || o.etat === 'refusee') && (
              <span className="m-bandeau bad"><strong>{c?.titre ?? 'Refusée'}</strong>{o.motif ? ` — ${o.motif}` : ''}</span>
            )}
            {(o.etat === 'rejetee' || o.etat === 'refusee') && c && <span className="muted">{c.conseil}</span>}
            <span className="m-actions">
              {o.etat === 'attente' && <button className="btn btn-sm btn-danger" onClick={() => { if (window.confirm('Annuler cette saisie ?')) void retirer(o.cle) }}>Annuler</button>}
              {o.etat === 'refusee' && <button className="btn btn-sm btn-danger" onClick={() => { if (window.confirm('Abandonner cette saisie ? Elle ne sera pas enregistrée.')) void retirer(o.cle) }}>Abandonner</button>}
              {o.etat === 'refusee' && <button className="btn btn-sm btn-primary" onClick={() => void reessayer(o.cle)}>Réessayer</button>}
              {(o.etat === 'rejetee' || o.etat === 'validee') && <button className="btn btn-sm" onClick={() => void retirer(o.cle)}>Retirer de la liste</button>}
            </span>
          </li>
        )
      })}
    </ul>
  )
}
