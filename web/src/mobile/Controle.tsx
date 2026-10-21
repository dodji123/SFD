// Contrôle des livrets sur le terrain (PWA) : scan du QR du cycle, comparaison avec les lignes du système, constat avec écarts,
// file locale hors ligne et envoi idempotent. La validation du constat se fait côté bureau, jamais ici.
import { useCallback, useEffect, useMemo, useState } from 'react'
import { BoutonScanner, lireQr } from '../components/Qr'
import { api, ApiError } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import {
  demarrerSynchroConstats, ecrireCacheC, enregistrerConstat, lireCacheC, marquerReseauC, reessayerConstat, retirerConstat, sessionRetablieC, synchroniserConstats,
  useConstats, viderCacheC, type Constat, type CorpsConstat, type Ecart, type EtatLivret, type NatureEcart,
} from './fileConstats'
import './mobile.css'

interface CycleLite { id: number; numero: string; client_id: number; client: string; produit: string; statut: string; nb_lignes: number; montant_collecte: number; date_fin: string }
interface Ligne { page: number; no_ligne: number; date_collecte: string; montant_collecte: number }
interface DetailCycle { nb_lignes: number; montant_collecte: number; lignes: Ligne[] }
interface Liste { cycles: CycleLite[]; majLe: number; horsLigne: boolean }

const ETATS: Record<EtatLivret, string> = { conforme: 'Conforme', incomplet: 'Incomplet', abime: 'Abîmé', perdu: 'Perdu', non_presente: 'Non présenté' }
const NATURES: Record<NatureEcart, string> = { absente_systeme: 'Sur le livret, absente du système', absente_livret: 'Dans le système, absente du livret', montant_different: 'Montant différent' }
const STATUTS = { a_valider: { lib: 'À valider', ton: 'info' }, valide: { lib: 'Validé', ton: 'ok' }, rejete: { lib: 'Rejeté', ton: 'bad' } } as const
const absolu = (l: Ligne) => (l.page - 1) * 31 + l.no_ligne

export default function ControleApp() {
  const { user, logout } = useSession()
  const f = useConstats()
  const [onglet, setOnglet] = useState<'controler' | 'suivi'>('controler')
  const [liste, setListe] = useState<Liste | null>(null)
  const [erreur, setErreur] = useState<string | null>(null)
  const [message, setMessage] = useState<string | null>(null)
  const cle = `cycles:${user?.id}`

  useEffect(() => { demarrerSynchroConstats() }, [])
  useEffect(() => { sessionRetablieC() }, [])
  const charger = useCallback(async () => {
    try {
      const cycles = await api.get<CycleLite[]>('/api/cycles', { limit: 500, tri: 'client' })
      const l = { cycles, majLe: Date.now(), horsLigne: false }
      setListe(l)
      setErreur(null)
      void ecrireCacheC(cle, l).catch(() => {})
    } catch (e) {
      if (e instanceof ApiError && (e.status === 0 || e.status >= 500)) marquerReseauC(false)
      const cache = await lireCacheC<Liste>(cle).catch(() => null)
      if (cache) setListe({ ...cache, horsLigne: true })
      else setErreur(e instanceof ApiError ? e.message : 'Chargement impossible')
    }
  }, [cle])
  useEffect(() => { void charger() }, [charger])
  useEffect(() => { if (f.derniereSynchro) void charger() }, [f.derniereSynchro, charger])
  useEffect(() => { if (!message) return; const t = window.setTimeout(() => setMessage(null), 3500); return () => window.clearTimeout(t) }, [message])

  const aEnvoyer = f.constats.filter((c) => c.etat === 'attente').length
  const aRevoir = f.constats.filter((c) => c.etat === 'refuse' || c.statut === 'rejete').length

  async function quitter() {
    if (aEnvoyer + f.constats.filter((c) => c.etat === 'refuse').length > 0 && !window.confirm('Des constats restent sur ce téléphone et seront envoyés à votre prochaine connexion. Se déconnecter ?')) return
    await viderCacheC().catch(() => {})
    logout()
  }

  return (
    <div className="m-app">
      <header className="m-entete">
        <div>
          <strong>{user?.nom}</strong>
          <span className={`m-reseau ${f.reseau ? 'ok' : 'hors'}`}>{f.reseau ? 'En ligne' : 'Hors ligne'} · contrôle des livrets</span>
        </div>
        <button className="btn btn-sm" onClick={() => void quitter()}>Quitter</button>
      </header>
      {(aEnvoyer > 0 || f.enCours) && (
        <button className="m-bandeau warn m-sync" onClick={() => void synchroniserConstats()} disabled={f.enCours}>
          {f.enCours ? 'Envoi…' : `${aEnvoyer} constat(s) à synchroniser${f.reseau ? ' — envoyer maintenant' : ' — en attente du réseau'}`}
        </button>
      )}
      {f.sessionExpiree && <p className="m-bandeau bad">Session expirée : reconnectez-vous pour envoyer vos constats (ils sont conservés).</p>}
      {message && <p className="m-bandeau ok" role="status">{message}</p>}
      <main>
        {erreur && <p className="m-bandeau bad">{erreur} <button className="btn btn-sm" onClick={() => void charger()}>Réessayer</button></p>}
        {!liste && !erreur && <p className="m-centre">Chargement…</p>}
        {liste?.horsLigne && <p className="m-bandeau info">Liste enregistrée le {new Date(liste.majLe).toLocaleString('fr-FR', { dateStyle: 'short', timeStyle: 'short' })} (hors ligne).</p>}
        {liste && onglet === 'controler' && <Choisir liste={liste} reseau={f.reseau} onRecharger={() => void charger()} onFait={setMessage} />}
        {onglet === 'suivi' && <Suivi constats={f.constats} />}
      </main>
      <nav className="m-nav" style={{ gridTemplateColumns: 'repeat(2, 1fr)' }}>
        <button className={onglet === 'controler' ? 'actif' : ''} onClick={() => setOnglet('controler')}>Contrôler</button>
        <button className={onglet === 'suivi' ? 'actif' : ''} onClick={() => setOnglet('suivi')}>
          Suivi{aRevoir > 0 ? <span className="m-pastille bad">{aRevoir}</span> : aEnvoyer > 0 ? <span className="m-pastille warn">{aEnvoyer}</span> : null}
        </button>
      </nav>
    </div>
  )
}

// ------------------------------------------------------------------ choix du cycle : QR ou recherche
function Choisir({ liste, reseau, onRecharger, onFait }: { liste: Liste; reseau: boolean; onRecharger: () => void; onFait: (m: string) => void }) {
  const [q, setQ] = useState('')
  const [clientId, setClientId] = useState<number | null>(null)
  const [info, setInfo] = useState<string | null>(null)
  const [choisi, setChoisi] = useState<CycleLite | null>(null)
  const [prep, setPrep] = useState<string | null>(null)

  const filtres = useMemo(() => {
    const s = q.trim().toLowerCase()
    return liste.cycles.filter((c) => (clientId === null || c.client_id === clientId) &&
      (!s || c.numero.toLowerCase().includes(s) || c.client.toLowerCase().includes(s) || c.produit.toLowerCase().includes(s))).slice(0, 80)
  }, [liste.cycles, q, clientId])

  async function scanne(texte: string) {
    const { nature, numero } = lireQr(texte)
    setInfo(null)
    if (nature === 'CL') {                        // QR d'un client : ses cycles (demande au serveur, donc réseau requis)
      try {
        const cl = await api.get<{ id: number; nom: string }[]>('/api/clients', { q: numero, limit: 5 })
        if (cl.length === 0) return setInfo(`Client ${numero} introuvable.`)
        setClientId(cl[0].id)
        setQ('')
        setInfo(`Cycles de ${cl[0].nom}`)
      } catch { setInfo('Le QR d\'un client demande le réseau : scannez le QR du cycle ou saisissez son numéro.') }
      return
    }
    setClientId(null)
    setQ(numero)
    const exact = liste.cycles.filter((c) => c.numero.toLowerCase() === numero.toLowerCase())
    if (exact.length === 1) setChoisi(exact[0])
    else if (exact.length === 0) setInfo(`Aucun cycle « ${numero} » dans la liste.`)
  }

  async function preparer() {
    let n = 0
    for (const c of filtres.slice(0, 60)) {
      setPrep(`Téléchargement ${++n}/${Math.min(filtres.length, 60)}…`)
      try { await ecrireCacheC(`detail:${c.id}`, await api.get<DetailCycle>(`/api/cycles/${c.id}`)) } catch { setPrep('Interrompu : réseau indisponible.'); return }
    }
    setPrep(`${n} livret(s) prêts pour le travail hors ligne.`)
  }

  return (
    <>
      <div className="m-recherche">
        <input className="input" type="search" placeholder="N° de cycle, client ou produit" value={q} onChange={(e) => { setQ(e.target.value); setClientId(null) }} />
        <BoutonScanner libelle="QR" onLu={(t) => void scanne(t)} />
      </div>
      {info && <p className="m-bandeau info">{info}</p>}
      <p className="muted m-compte">{filtres.length} cycle(s){clientId !== null ? ' du client' : ''} <button className="btn btn-sm" onClick={onRecharger}>↻</button>{' '}
        <button className="btn btn-sm" disabled={!reseau || filtres.length === 0} onClick={() => void preparer()}>Préparer hors ligne</button></p>
      {prep && <p className="m-bandeau info">{prep}</p>}
      <ul className="m-liste">
        {filtres.map((c) => (
          <li key={c.id}>
            <button className="m-carte" onClick={() => setChoisi(c)}>
              <span className="m-carte-haut"><strong>{c.client}</strong><span>{c.statut === 'en_cours' ? '' : 'clos'}</span></span>
              <span className="muted">{c.numero} · {c.produit}</span>
              <span className="m-carte-bas"><span>Système : {c.nb_lignes} ligne(s)</span><span>{xof(c.montant_collecte)}</span></span>
            </button>
          </li>
        ))}
      </ul>
      {filtres.length === 0 && <p className="m-centre muted">Aucun cycle.</p>}
      {choisi && <Constater cycle={choisi} onFermer={() => setChoisi(null)} onFait={(m) => { setChoisi(null); onFait(m) }} />}
    </>
  )
}

// ------------------------------------------------------------------ formulaire de constat
const nombre = (s: string): number | null => (s.trim() === '' ? null : Number(s))

function Constater({ cycle, onFermer, onFait }: { cycle: CycleLite; onFermer: () => void; onFait: (m: string) => void }) {
  const [detail, setDetail] = useState<DetailCycle | null | 'absent'>(null)
  const [etat, setEtat] = useState<EtatLivret>('conforme')
  const [nb, setNb] = useState('')
  const [total, setTotal] = useState('')
  const [commentaire, setCommentaire] = useState('')
  const [jour, setJour] = useState(aujourdhui())
  const [ecarts, setEcarts] = useState<Ecart[]>([])
  const [voir, setVoir] = useState(false)
  const [erreur, setErreur] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  useEffect(() => {
    let ok = true
    const cle = `detail:${cycle.id}`
    api.get<DetailCycle>(`/api/cycles/${cycle.id}`)
      .then((d) => { if (ok) { setDetail(d); void ecrireCacheC(cle, d).catch(() => {}) } })
      .catch(async () => { const c = await lireCacheC<DetailCycle>(cle).catch(() => null); if (ok) setDetail(c ?? 'absent') })
    return () => { ok = false }
  }, [cycle.id])

  const sans = etat === 'perdu' || etat === 'non_presente'
  const lignes = detail && detail !== 'absent' ? detail.lignes : []
  const majEcart = (i: number, p: Partial<Ecart>) => setEcarts(ecarts.map((e, k) => (k === i ? { ...e, ...p } : e)))

  async function envoyer() {
    if (etat === 'conforme' && ecarts.length > 0) return setErreur('Un livret conforme ne présente aucun écart.')
    if ((etat !== 'conforme' || ecarts.length > 0) && commentaire.trim().length < 3) return setErreur('Un commentaire est obligatoire (livret non conforme ou écart).')
    if (!sans && (nb.trim() === '' || total.trim() === '')) return setErreur('Saisissez le nombre de lignes et le total constatés sur le livret.')
    if (ecarts.some((e) => !e.no_ligne || e.no_ligne < 1 || e.no_ligne > 62)) return setErreur('Chaque écart demande un numéro de ligne (1 à 62).')
    const corps: CorpsConstat = {
      cycle_id: cycle.id, etat_livret: etat, date_controle: jour, commentaire: commentaire.trim() || null,
      nb_lignes_constatees: sans ? null : nombre(nb), total_constate: sans ? null : nombre(total),
      ecarts: sans ? [] : ecarts.map((e) => ({ ...e, note: e.note?.trim() || null })),
    }
    setBusy(true)
    try {
      await enregistrerConstat({ cycle: cycle.numero, client: cycle.client, produit: cycle.produit }, corps)
      onFait(`Constat enregistré pour ${cycle.client}`)
    } catch {
      setErreur('Impossible d\'écrire sur le téléphone (stockage plein ou bloqué).')
      setBusy(false)
    }
  }

  return (
    <div className="m-feuille-fond" onClick={onFermer}>
      <form className="m-feuille" onClick={(e) => e.stopPropagation()} onSubmit={(e) => { e.preventDefault(); void envoyer() }}>
        <h2>{cycle.client}</h2>
        <p className="muted">{cycle.numero} · {cycle.produit}</p>
        <p className="m-bandeau info">
          Système : {detail && detail !== 'absent' ? detail.nb_lignes : cycle.nb_lignes} ligne(s), {xof(detail && detail !== 'absent' ? detail.montant_collecte : cycle.montant_collecte)}
          {detail === 'absent' && ' — lignes non téléchargées (le serveur comparera à la réception).'}
          {lignes.length > 0 && <> <button type="button" className="btn btn-sm" onClick={() => setVoir(!voir)}>{voir ? 'Masquer' : 'Voir les lignes'}</button></>}
        </p>
        {voir && (
          <div className="m-lignes">
            {lignes.map((l) => <span key={absolu(l)}><b>{absolu(l)}</b> {fdate(l.date_collecte)} · {xof(l.montant_collecte)}</span>)}
          </div>
        )}
        {erreur && <p className="m-bandeau bad" role="alert">{erreur}</p>}
        <label>État du livret
          <select className="input" value={etat} onChange={(e) => setEtat(e.target.value as EtatLivret)}>{Object.entries(ETATS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
        </label>
        {!sans && (
          <div className="m-deux">
            <label>Lignes sur le livret<input className="input" inputMode="numeric" value={nb} onChange={(e) => setNb(e.target.value.replace(/\D/g, ''))} /></label>
            <label>Total sur le livret (F)<input className="input" inputMode="numeric" value={total} onChange={(e) => setTotal(e.target.value.replace(/\D/g, ''))} /></label>
          </div>
        )}
        {!sans && (
          <>
            <p className="muted">Écarts ligne par ligne ({ecarts.length})</p>
            {ecarts.map((e, i) => (
              <div key={i} className="m-ecart">
                <div className="m-deux">
                  <label>Ligne n°<input className="input" inputMode="numeric" value={e.no_ligne || ''} onChange={(x) => majEcart(i, { no_ligne: Number(x.target.value.replace(/\D/g, '')) })} /></label>
                  <label>Date<input className="input" type="date" value={e.date_collecte ?? ''} onChange={(x) => majEcart(i, { date_collecte: x.target.value || null })} /></label>
                </div>
                <label>Nature<select className="input" value={e.nature} onChange={(x) => majEcart(i, { nature: x.target.value as NatureEcart })}>{Object.entries(NATURES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select></label>
                <div className="m-deux">
                  <label>Montant livret<input className="input" inputMode="numeric" value={e.montant_livret ?? ''} onChange={(x) => majEcart(i, { montant_livret: nombre(x.target.value.replace(/\D/g, '')) })} /></label>
                  <label>Montant système<input className="input" inputMode="numeric" value={e.montant_systeme ?? ''} onChange={(x) => majEcart(i, { montant_systeme: nombre(x.target.value.replace(/\D/g, '')) })} /></label>
                </div>
                <label>Note<input className="input" value={e.note ?? ''} maxLength={300} onChange={(x) => majEcart(i, { note: x.target.value })} /></label>
                <button type="button" className="btn btn-sm btn-danger" onClick={() => setEcarts(ecarts.filter((_, k) => k !== i))}>Retirer cet écart</button>
              </div>
            ))}
            <div className="m-actions">
              {lignes.length > 0 && (
                <select className="input" value="" onChange={(x) => {
                  const l = lignes.find((y) => String(absolu(y)) === x.target.value)
                  if (l) setEcarts([...ecarts, { no_ligne: absolu(l), date_collecte: l.date_collecte, montant_systeme: l.montant_collecte, nature: 'montant_different' }])
                }}><option value="">+ Écart sur une ligne du système…</option>{lignes.map((l) => <option key={absolu(l)} value={absolu(l)}>{absolu(l)} — {fdate(l.date_collecte)} — {xof(l.montant_collecte)}</option>)}</select>
              )}
              <button type="button" className="btn" onClick={() => setEcarts([...ecarts, { no_ligne: 0, nature: 'absente_systeme' }])}>+ Écart</button>
            </div>
          </>
        )}
        <label>Commentaire{(etat !== 'conforme' || ecarts.length > 0) ? ' (obligatoire)' : ''}
          <textarea className="input" rows={3} maxLength={1000} value={commentaire} onChange={(e) => setCommentaire(e.target.value)} />
        </label>
        <label>Date du contrôle<input className="input" type="date" value={jour} max={aujourdhui()} onChange={(e) => setJour(e.target.value)} /></label>
        <div className="m-actions">
          <button type="button" className="btn m-gros" onClick={onFermer}>Annuler</button>
          <button className="btn btn-primary m-gros" disabled={busy}>Enregistrer le constat</button>
        </div>
      </form>
    </div>
  )
}

// ------------------------------------------------------------------ suivi des constats
function Suivi({ constats }: { constats: Constat[] }) {
  if (constats.length === 0) return <p className="m-centre muted">Aucun constat.</p>
  return (
    <ul className="m-liste">
      {constats.map((c) => {
        const s = c.statut ? STATUTS[c.statut] : null
        return (
          <li key={c.cle} className="m-op">
            <span className="m-carte-haut"><strong>{c.client}</strong>
              {c.etat === 'attente' ? <span className="m-pastille warn">À envoyer</span> : c.etat === 'refuse' ? <span className="m-pastille bad">Refusé</span> : s && <span className={`m-pastille ${s.ton}`}>{s.lib}</span>}
            </span>
            <span className="muted">{c.cycle} · {c.produit} · {ETATS[c.corps.etat_livret]} · contrôlé le {fdate(c.corps.date_controle)}</span>
            {c.ecart_montant ? <span>Écart de montant avec le système : <strong>{xof(c.ecart_montant)}</strong></span> : null}
            {c.etat === 'refuse' && <span className="m-bandeau bad">{c.motif}</span>}
            {c.statut === 'rejete' && <span className="m-bandeau bad">Rejeté par le responsable{c.decision ? ` — ${c.decision}` : ''}</span>}
            {c.statut === 'valide' && c.decision && <span className="muted">{c.decision}</span>}
            <span className="m-actions">
              {c.etat === 'attente' && <button className="btn btn-sm btn-danger" onClick={() => { if (window.confirm('Annuler ce constat ?')) void retirerConstat(c.cle) }}>Annuler</button>}
              {c.etat === 'refuse' && <button className="btn btn-sm btn-danger" onClick={() => { if (window.confirm('Abandonner ce constat ?')) void retirerConstat(c.cle) }}>Abandonner</button>}
              {c.etat === 'refuse' && <button className="btn btn-sm btn-primary" onClick={() => void reessayerConstat(c.cle)}>Réessayer</button>}
              {c.etat === 'envoye' && c.statut !== 'a_valider' && <button className="btn btn-sm" onClick={() => void retirerConstat(c.cle)}>Retirer de la liste</button>}
            </span>
          </li>
        )
      })}
    </ul>
  )
}
