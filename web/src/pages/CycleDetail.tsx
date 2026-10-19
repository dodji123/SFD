import { useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, decaler, xof } from '../lib/format'
import { useAgents } from '../lib/hooks'
import { useSession } from '../lib/session'
import { Button, Card, Charge, Field, FormModal, Input, Kpi, Page, Select, Statut, Table, useAction, useFetch } from '../components/ui'

interface Ligne { id: number; page: number; no_ligne: number; date_collecte: string; montant_collecte: number; mise_appliquee: number; origine: string; agent: string | null }
interface Detail {
  id: number; numero: string; client_id: number; client: string; type_cycle: number; statut: string
  mise_initiale: number; mise_courante: number; mise_finale: number | null; objectif: number | null; nb_lignes_prevues: number
  date_debut: string; date_fin: string; date_cloture: string | null
  nb_lignes: number; montant_collecte: number; montant_previsionnel: number | null; reste_a_collecter: number | null; net: number
  lignes: Ligne[]; mises: { date_effet: string; mise: number; motif: string | null }[]
  retraits: { id: number; nature: string; montant: number; montant_paye: number | null; ecart: number; statut: string; date_demande: string }[]
}
interface Compte { id: number; numero: string; produit: string; disponible: number }

const NATURES: Record<string, string> = { retrait_client: 'Retrait client', virement_vers_epargne: 'Virement vers épargne', remboursement: 'Remboursement de crédit', regularisation: 'Régularisation' }

export default function CycleDetail() {
  const { id } = useParams()
  const nav = useNavigate()
  const { can } = useSession()
  const q = useFetch(() => api.get<Detail>(`/api/cycles/${id}`), [id])
  const [modale, setModale] = useState<null | 'lignes' | 'mise' | 'cloture' | 'retrait'>(null)
  const fin = () => { setModale(null); q.reload() }
  return (
    <Charge q={q}>
      {(c) => {
        const enCours = c.statut === 'en_cours'
        const pages = Math.max(1, Math.ceil(c.nb_lignes_prevues / 31), ...c.lignes.map((l) => l.page))
        const parCase = new Map(c.lignes.map((l) => [`${l.page}-${l.no_ligne}`, l]))
        return (
          <Page title={`Cycle ${c.numero}`} subtitle={`Type ${c.type_cycle} · du ${fdate(c.date_debut)} au ${fdate(c.date_fin)}${c.date_cloture ? ` · clôturé le ${fdate(c.date_cloture)}` : ''}`}
            actions={<>
              <Link to={`/clients/${c.client_id}`} className="btn">{c.client}</Link>
              <Statut s={c.statut} />
              {enCours && can('collecte:write') && <Button variant="primary" onClick={() => setModale('lignes')}>Saisir des lignes</Button>}
              {enCours && c.type_cycle !== 3 && can('collecte:write') && <Button onClick={() => setModale('mise')}>Changer la mise</Button>}
              {enCours && can('collecte:admin') && <Button onClick={() => setModale('cloture')}>Clôturer</Button>}
              {c.statut !== 'retire' && can('retrait:request') && <Button onClick={() => setModale('retrait')}>Demander le retrait</Button>}
            </>}>
            <div className="grid-kpi">
              <Kpi label="Collecté" value={xof(c.montant_collecte)} />
              {c.montant_previsionnel !== null && <Kpi label="Prévisionnel" value={xof(c.montant_previsionnel)} />}
              {c.reste_a_collecter !== null && <Kpi label="Reste à collecter" value={xof(c.reste_a_collecter)} />}
              <Kpi label={c.mise_finale !== null ? 'Mise finale' : 'Mise courante'} value={xof(c.mise_finale ?? c.mise_courante)} />
              <Kpi label="Net (collecté − mise − remboursements)" value={xof(c.net)} />
            </div>

            <Card title={`Livret — ${c.nb_lignes} ligne${c.nb_lignes > 1 ? 's' : ''} sur ${c.nb_lignes_prevues}`}>
              <div className="stack">
                {Array.from({ length: pages }, (_, p) => p + 1).map((p) => (
                  <div key={p}>
                    {pages > 1 && <h3 style={{ marginBottom: 8 }}>Page {p}</h3>}
                    <div className="livret">
                      {Array.from({ length: 31 }, (_, i) => i + 1).map((n) => {
                        const l = parCase.get(`${p}-${n}`)
                        return (
                          <div key={n} className={`case ${l ? (l.origine === 'virement' ? 'virement' : 'plein') : ''}`} title={l ? `${fdate(l.date_collecte)} · ${l.agent ?? 'virement'}` : 'Libre'}>
                            <div className="n">{n}{l ? ` · ${fdate(l.date_collecte).slice(0, 5)}` : ''}</div>
                            <div className="m">{l ? xof(l.montant_collecte) : ''}</div>
                          </div>
                        )
                      })}
                    </div>
                  </div>
                ))}
                <p className="muted" style={{ margin: 0 }}>Vert : collecte · bleu : virement depuis l'épargne.</p>
              </div>
            </Card>

            <div className="grid-2">
              <Card title="Historique des mises" flush>
                <Table rows={c.mises} cols={[
                  { titre: 'À partir du', render: (m) => fdate(m.date_effet) },
                  { titre: 'Mise', num: true, render: (m) => xof(m.mise) },
                  { titre: 'Motif', render: (m) => m.motif ?? '—' },
                ]} />
              </Card>
              <Card title="Retraits liés" flush>
                <Table rows={c.retraits} onRowClick={() => nav('/retraits')} vide="Aucun retrait" cols={[
                  { titre: 'Nature', render: (r) => NATURES[r.nature] ?? r.nature },
                  { titre: 'Montant', num: true, render: (r) => xof(r.montant_paye ?? r.montant) },
                  { titre: 'Écart', num: true, render: (r) => (r.ecart ? xof(r.ecart) : '—') },
                  { titre: 'Statut', render: (r) => <Statut s={r.statut} /> },
                ]} />
              </Card>
            </div>

            {modale === 'lignes' && <SaisieLignes c={c} onClose={() => setModale(null)} onFait={fin} />}
            {modale === 'mise' && <ChangerMise c={c} onClose={() => setModale(null)} onFait={fin} />}
            {modale === 'cloture' && <Cloture c={c} onClose={() => setModale(null)} onFait={fin} />}
            {modale === 'retrait' && <DemandeRetrait c={c} onClose={() => setModale(null)} onFait={() => nav('/retraits')} />}
          </Page>
        )
      }}
    </Charge>
  )
}

function SaisieLignes({ c, onClose, onFait }: { c: Detail; onClose: () => void; onFait: () => void }) {
  const agents = useAgents()
  const { user } = useSession()
  const { run, busy } = useAction()
  const derniere = c.lignes.length ? c.lignes[c.lignes.length - 1].date_collecte : null
  const [f, setF] = useState({ debut: derniere ? decaler(derniere, 1) : c.date_debut, nb: '1', montant: String(c.mise_courante), agent: '' })
  const maj = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  const libres = c.nb_lignes_prevues - c.nb_lignes
  const envoyer = () => {
    const nb = Math.max(1, Number(f.nb))
    const lignes = Array.from({ length: nb }, (_, i) => ({
      date_collecte: decaler(f.debut, i), montant_collecte: Number(f.montant), ...(f.agent ? { agent_id: Number(f.agent) } : {}),
    }))
    void run(() => api.post(`/api/cycles/${c.id}/lignes`, { lignes }), `${nb} ligne${nb > 1 ? 's' : ''} saisie${nb > 1 ? 's' : ''}`, onFait)
  }
  return (
    <FormModal titre="Saisir des lignes du livret" onClose={onClose} busy={busy} onSubmit={envoyer} valider="Enregistrer">
      <Field label="Date de la première ligne"><Input type="date" value={f.debut} onChange={maj('debut')} required /></Field>
      <Field label="Nombre de lignes (jours consécutifs)" hint={`${libres} ligne(s) libre(s)`}><Input type="number" min={1} max={Math.max(libres, 1)} value={f.nb} onChange={maj('nb')} required /></Field>
      <Field label="Montant par ligne (F)"><Input type="number" min={1} value={f.montant} onChange={maj('montant')} required /></Field>
      {user?.role !== 'agent' && (
        <Field label="Agent collecteur">
          <Select value={f.agent} onChange={maj('agent')} required>
            <option value="">— choisir —</option>
            {agents.map((a) => <option key={a.id} value={a.id}>{a.matricule} — {a.nom}</option>)}
          </Select>
        </Field>
      )}
    </FormModal>
  )
}

function ChangerMise({ c, onClose, onFait }: { c: Detail; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const derniere = c.lignes.length ? c.lignes[c.lignes.length - 1].date_collecte : c.date_debut
  const [f, setF] = useState({ mise: String(c.mise_courante), date: decaler(derniere, 1), motif: '' })
  const maj = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  return (
    <FormModal titre="Changer la mise" onClose={onClose} busy={busy} valider="Appliquer"
      onSubmit={() => void run(() => api.post(`/api/cycles/${c.id}/mise`, { mise: Number(f.mise), date_effet: f.date, motif: f.motif || null }), 'Mise modifiée', onFait)}>
      <Field label="Nouvelle mise (F)"><Input type="number" min={1} value={f.mise} onChange={maj('mise')} required autoFocus /></Field>
      <Field label="Applicable à partir du" hint="Les lignes déjà saisies gardent leur mise"><Input type="date" value={f.date} onChange={maj('date')} required /></Field>
      <Field label="Motif"><Input value={f.motif} onChange={maj('motif')} /></Field>
    </FormModal>
  )
}

function Cloture({ c, onClose, onFait }: { c: Detail; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [jour, setJour] = useState(aujourdhui())
  return (
    <FormModal titre={`Clôturer le cycle ${c.numero}`} onClose={onClose} busy={busy} valider="Clôturer"
      onSubmit={() => void run(() => api.post(`/api/cycles/${c.id}/cloturer`, { date: jour }), 'Cycle clôturé', onFait)}>
      <Field label="Date de clôture"><Input type="date" value={jour} onChange={(e) => setJour(e.target.value)} required /></Field>
      {c.type_cycle === 3 && <p className="muted" style={{ gridColumn: '1 / -1', margin: 0 }}>Type 3 : la mise finale sera calculée (collecté ÷ 31, arrondi, au moins la mise initiale).</p>}
    </FormModal>
  )
}

function DemandeRetrait({ c, onClose, onFait }: { c: Detail; onClose: () => void; onFait: () => void }) {
  const comptes = useFetch(() => api.get<Compte[]>('/api/comptes-epargne', { client_id: c.client_id }), [c.client_id])
  const { run, busy } = useAction()
  const [f, setF] = useState({ nature: 'retrait_client', compte_id: '', date: aujourdhui() })
  const maj = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  return (
    <FormModal titre="Demander le retrait du cycle" onClose={onClose} busy={busy} valider="Créer la demande"
      onSubmit={() => void run(() => api.post(`/api/cycles/${c.id}/retrait`, { nature: f.nature, compte_id: f.compte_id ? Number(f.compte_id) : null, date: f.date }), 'Demande de retrait créée', onFait)}>
      <Field label="Destination">
        <Select value={f.nature} onChange={maj('nature')}>
          <option value="retrait_client">Payer le client en espèces</option>
          <option value="virement_vers_epargne">Virer sur un compte d'épargne</option>
        </Select>
      </Field>
      {f.nature === 'virement_vers_epargne' && (
        <Field label="Compte d'épargne">
          <Select value={f.compte_id} onChange={maj('compte_id')} required>
            <option value="">— choisir —</option>
            {(comptes.data ?? []).map((x) => <option key={x.id} value={x.id}>{x.numero} · {x.produit}</option>)}
          </Select>
        </Field>
      )}
      <Field label="Date"><Input type="date" value={f.date} onChange={maj('date')} required /></Field>
      {c.statut === 'en_cours' && <p className="alert warn" style={{ gridColumn: '1 / -1', margin: 0 }}>Le cycle est encore en cours : il sera clôturé à cette date (retrait anticipé).</p>}
    </FormModal>
  )
}
