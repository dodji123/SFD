import { useState } from 'react'
import { api } from '../lib/api'
import type { ClientVue } from './file'

interface CreditVue { id: number; numero: string; statut: string }
interface Position { latitude: number; longitude: number; precision_m: number | null }

type Saisie =
  | { kind: 'localisation'; cle: string; client_id: number; role: 'lieu_travail' | 'caution' | 'visite'; latitude: number; longitude: number; libelle: string | null; precision_m: number | null }
  | { kind: 'visite'; cle: string; credit_id: number; type: 'visite' | 'recouvrement'; localisation_cle: string | null; resultat: string | null }

const CLE_FILE = 'sfd.terrain.file'
function lireFile(): Saisie[] {
  try { const v = JSON.parse(localStorage.getItem(CLE_FILE) ?? '[]'); return Array.isArray(v) ? v : [] } catch { return [] }
}
function ecrireFile(f: Saisie[]) {
  try { localStorage.setItem(CLE_FILE, JSON.stringify(f)) } catch { /* stockage plein ou indisponible : la saisie reste à l'écran */ }
}
function nouvelleCle(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`
}

// Section Crédit : positions GPS (lieu de travail de l'emprunteur ou de la caution, lieu visité) et visites de terrain
// ou de recouvrement. En ligne uniquement : l'enregistrement a lieu au moment de la sortie.
export default function Terrain({ clients, onSaisi }: { clients: ClientVue[]; onSaisi: (m: string) => void }) {
  const [clientId, setClientId] = useState('')
  const [credits, setCredits] = useState<CreditVue[]>([])
  const [creditId, setCreditId] = useState('')
  const [role, setRole] = useState<'lieu_travail' | 'caution' | 'visite'>('lieu_travail')
  const [libelle, setLibelle] = useState('')
  const [position, setPosition] = useState<Position | null>(null)
  const [localisationCle, setLocalisationCle] = useState<string | null>(null)
  const [type, setType] = useState<'visite' | 'recouvrement'>('visite')
  const [resultat, setResultat] = useState('')
  const [erreur, setErreur] = useState<string | null>(null)
  const [occupe, setOccupe] = useState(false)

  async function choisirClient(id: string) {
    setClientId(id)
    setCreditId('')
    setCredits([])
    if (!id) return
    try {
      setCredits(await api.get<CreditVue[]>('/api/credits', { client_id: Number(id) }))
    } catch (e) {
      setErreur(e instanceof Error ? e.message : 'Liste des crédits indisponible')
    }
  }

  function localiser() {
    setErreur(null)
    if (!navigator.geolocation) { setErreur('Position indisponible sur cet appareil'); return }
    navigator.geolocation.getCurrentPosition(
      (p) => setPosition({ latitude: p.coords.latitude, longitude: p.coords.longitude, precision_m: p.coords.accuracy ?? null }),
      () => setErreur("Position refusée ou indisponible : autorisez la localisation pour l'application"),
      { enableHighAccuracy: true, timeout: 15000, maximumAge: 0 },
    )
  }

  // Saisies gardées sur le téléphone jusqu'à la synchronisation en agence.
  const [file, setFile] = useState<Saisie[]>(lireFile)

  function ajouter(s: Saisie) {
    const n = [...lireFile(), s]
    ecrireFile(n)
    setFile(n)
  }

  function enregistrerLieu() {
    if (!clientId || !position) return
    const cle = nouvelleCle()
    ajouter({ kind: 'localisation', cle, client_id: Number(clientId), role, latitude: position.latitude, longitude: position.longitude,
      libelle: libelle.trim() || null, precision_m: position.precision_m })
    setLocalisationCle(cle)
    onSaisi('Position gardée sur le téléphone')
  }

  function enregistrerVisite() {
    if (!creditId) return
    ajouter({ kind: 'visite', cle: nouvelleCle(), credit_id: Number(creditId), type, localisation_cle: localisationCle, resultat: resultat.trim() || null })
    setResultat('')
    setLocalisationCle(null)
    onSaisi(type === 'recouvrement' ? 'Recouvrement gardé sur le téléphone' : 'Visite gardée sur le téléphone')
  }

  // À lancer en agence, connecté : envoie tout ce qui est en attente, positions avant visites.
  async function synchroniser() {
    const a_envoyer = lireFile()
    if (a_envoyer.length === 0) return
    setOccupe(true)
    setErreur(null)
    try {
      const reponse = await api.post<{ resultats: { cle: string; statut: 'ok' | 'erreur'; motif?: string }[] }>('/api/terrain/sync', {
        localisations: a_envoyer.filter((s) => s.kind === 'localisation').map(({ kind: _k, ...l }) => l),
        visites: a_envoyer.filter((s) => s.kind === 'visite').map(({ kind: _k, ...v }) => v),
      })
      const ok = new Set(reponse.resultats.filter((r) => r.statut === 'ok').map((r) => r.cle))
      const restent = a_envoyer.filter((s) => !ok.has(s.cle))
      ecrireFile(restent)
      setFile(restent)
      const erreurs = reponse.resultats.filter((r) => r.statut === 'erreur')
      if (erreurs.length) setErreur(`${erreurs.length} saisie(s) refusée(s) : ${erreurs.map((r) => r.motif).join(' ; ')}`)
      else onSaisi(`${ok.size} saisie(s) synchronisée(s)`)
    } catch (e) {
      setErreur(e instanceof Error ? e.message : 'Synchronisation impossible : vérifiez la connexion')
    } finally {
      setOccupe(false)
    }
  }

  return (
    <div className="m-terrain">
      <label className="m-champ">
        Client
        <select className="input" value={clientId} onChange={(e) => void choisirClient(e.target.value)}>
          <option value="">Choisir un client</option>
          {clients.map((c) => <option key={String(c.id)} value={String(c.id)}>{c.nom}</option>)}
        </select>
      </label>

      {clientId && (
        <section className="m-bloc">
          <h2>Position GPS</h2>
          <label className="m-champ">
            Lieu
            <select className="input" value={role} onChange={(e) => setRole(e.target.value as typeof role)}>
              <option value="lieu_travail">Lieu de travail de l'emprunteur</option>
              <option value="caution">Lieu de travail de la caution</option>
              <option value="visite">Lieu visité pendant la sortie</option>
            </select>
          </label>
          <input className="input" placeholder="Description du lieu (facultatif)" value={libelle} onChange={(e) => setLibelle(e.target.value)} />
          <button className="btn m-gros" onClick={localiser} disabled={occupe}>Prendre la position</button>
          {position && <p className="muted">Position : {position.latitude.toFixed(6)}, {position.longitude.toFixed(6)}{position.precision_m !== null ? ` (± ${Math.round(position.precision_m)} m)` : ''}</p>}
          <button className="btn btn-primary m-gros" onClick={() => void enregistrerLieu()} disabled={!position || occupe}>Enregistrer ce lieu</button>
          {localisationCle !== null && <p className="muted">Lieu gardé sur le téléphone : il sera rattaché à la prochaine visite.</p>}
        </section>
      )}

      {clientId && (
        <section className="m-bloc">
          <h2>Visite ou recouvrement</h2>
          <label className="m-champ">
            Crédit
            <select className="input" value={creditId} onChange={(e) => setCreditId(e.target.value)}>
              <option value="">Choisir un crédit</option>
              {credits.map((c) => <option key={c.id} value={c.id}>{c.numero} ({c.statut})</option>)}
            </select>
          </label>
          <label className="m-champ">
            Type
            <select className="input" value={type} onChange={(e) => setType(e.target.value as typeof type)}>
              <option value="visite">Visite de suivi</option>
              <option value="recouvrement">Recouvrement</option>
            </select>
          </label>
          <input className="input" placeholder="Résultat de la visite (facultatif)" value={resultat} onChange={(e) => setResultat(e.target.value)} />
          <button className="btn btn-primary m-gros" onClick={() => void enregistrerVisite()} disabled={!creditId || occupe}>Enregistrer la visite</button>
        </section>
      )}

      <section className="m-bloc">
        <h2>À synchroniser</h2>
        <p className="muted">{file.length} saisie(s) gardée(s) sur le téléphone. Synchronisez en agence, connecté.</p>
        <button className="btn btn-primary m-gros" onClick={() => void synchroniser()} disabled={occupe || file.length === 0}>Synchroniser</button>
      </section>

      {erreur && <p className="m-bandeau bad">{erreur}</p>}
    </div>
  )
}
