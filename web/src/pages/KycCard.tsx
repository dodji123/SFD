import { useState } from 'react'
import { api } from '../lib/api'
import { date as fdate } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Select, Table, useAction, useFetch } from '../components/ui'

interface Piece { id: number; type: string; numero: string; date_emission: string | null; date_expiration: string | null }
interface Dossier {
  id: number; qualite_interne: string; type_client: string; sexe: string | null; date_naissance: string | null; profession: string | null; adresse: string | null
  latitude_domicile: number | null; longitude_domicile: number | null; ppe: boolean; statut_kyc: 'complet' | 'incomplet'
  kyc_valide_le: string | null; manquants: string[]; pieces: Piece[]
  liens: { id: number; type: string; lie_a_nom: string; lie_a_numero: string }[]
  alertes: { id: number; type: string; statut: string; score: number; nom_liste: string; source: string }[]
}

const TYPES_CLIENT: [string, string][] = [['physique', 'Personne physique'], ['groupe_solidaire', 'Groupe solidaire'], ['personne_morale', 'Personne morale'], ['cooperative', 'GIC / coopérative']]
const TYPES_PIECE: [string, string][] = [['cni', 'Carte nationale d\'identité'], ['passeport', 'Passeport'], ['carte_electeur', 'Carte d\'électeur'], ['permis', 'Permis de conduire'],
  ['carte_consulaire', 'Carte consulaire'], ['registre_commerce', 'Registre du commerce'], ['statuts', 'Statuts'], ['autre', 'Autre']]
const LIB_TYPE = Object.fromEntries(TYPES_CLIENT)
const LIB_PIECE = Object.fromEntries(TYPES_PIECE)

export default function KycCard({ clientId }: { clientId: number }) {
  const { can } = useSession()
  const q = useFetch(() => api.get<Dossier>(`/api/clients/${clientId}/kyc`), [clientId])
  const [modale, setModale] = useState<null | 'profil' | 'piece' | 'lien'>(null)
  const { run, busy } = useAction()
  const fin = () => { setModale(null); q.reload() }
  return (
    <Card title="Dossier KYC" flush actions={<>
      {can('ref:write') && <Button small onClick={() => setModale('profil')}>Profil</Button>}
      {can('ref:write') && <Button small onClick={() => setModale('piece')}>Ajouter une pièce</Button>}
      {can('kyc:validate') && q.data && q.data.statut_kyc === 'incomplet' && (
        <Button small variant="primary" disabled={busy || q.data.manquants.length > 0}
          onClick={() => void run(() => api.post(`/api/clients/${clientId}/kyc/valider`), 'KYC validé', q.reload)}>Valider le KYC</Button>)}
    </>}>
      <Charge q={q}>
        {(d) => (
          <div className="card-b stack">
            <div className="actions">
              <Badge tone={d.statut_kyc === 'complet' ? 'ok' : 'warn'}>{d.statut_kyc === 'complet' ? `KYC complet${d.kyc_valide_le ? ' · ' + fdate(d.kyc_valide_le) : ''}` : 'KYC incomplet'}</Badge>
              <Badge>{LIB_TYPE[d.type_client] ?? d.type_client}</Badge>
              {d.ppe && <Badge tone="bad">Personne politiquement exposée</Badge>}
            </div>
            {d.manquants.length > 0 && <Alert tone="warn">À compléter : {d.manquants.join(', ')}.</Alert>}
            {d.alertes.filter((a) => a.statut === 'a_examiner').map((a) => (
              <Alert key={a.id} tone="bad">Alerte {a.type === 'ppe' ? 'PPE' : 'sanction'} à examiner : proche de « {a.nom_liste} » ({a.source}, similarité {Math.round(a.score * 100)} %). La direction doit trancher (page Conformité).</Alert>
            ))}
            <p className="muted" style={{ margin: 0 }}>
              {d.date_naissance ? `Né(e) le ${fdate(d.date_naissance)} · ` : ''}{d.profession ?? 'profession non renseignée'} · {d.adresse ?? 'adresse non renseignée'}
              {d.latitude_domicile !== null && d.longitude_domicile !== null ? ` · domicile ${d.latitude_domicile}, ${d.longitude_domicile}` : ''}
            </p>
            <Table rows={d.pieces} vide="Aucune pièce enregistrée" cols={[
              { titre: 'Pièce', render: (p) => LIB_PIECE[p.type] ?? p.type },
              { titre: 'Numéro', render: (p) => p.numero },
              { titre: 'Expiration', render: (p) => (p.date_expiration ? fdate(p.date_expiration) : '—') },
              { titre: '', render: (p) => p.date_expiration && p.date_expiration < new Date().toISOString().slice(0, 10) && <Badge tone="bad">Expirée</Badge> },
            ]} />
            <div className="actions">
              {d.liens.length > 0 && <span className="muted">Liens : {d.liens.map((l) => `${l.lie_a_nom} (${l.type})`).join(', ')}</span>}
              {can('ref:write') && <Button small onClick={() => setModale('lien')}>Ajouter un lien</Button>}
            </div>
            {modale === 'profil' && <Profil d={d} clientId={clientId} onClose={() => setModale(null)} onFait={fin} />}
            {modale === 'piece' && <NouvellePiece clientId={clientId} onClose={() => setModale(null)} onFait={fin} />}
            {modale === 'lien' && <NouveauLien clientId={clientId} onClose={() => setModale(null)} onFait={fin} />}
          </div>
        )}
      </Charge>
    </Card>
  )
}

function Profil({ d, clientId, onClose, onFait }: { d: Dossier; clientId: number; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({
    type_client: d.type_client, sexe: d.sexe ?? '', date_naissance: d.date_naissance ?? '', profession: d.profession ?? '', adresse: d.adresse ?? '',
    lat: d.latitude_domicile?.toString() ?? '', lon: d.longitude_domicile?.toString() ?? '', qualite_interne: d.qualite_interne ?? 'aucune',
  })
  const maj = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  return (
    <FormModal titre="Profil du client" onClose={onClose} busy={busy} valider="Enregistrer" large
      onSubmit={() => void run(() => api.put(`/api/clients/${clientId}/profil`, {
        type_client: f.type_client, sexe: f.sexe || null, date_naissance: f.date_naissance || null, profession: f.profession || null, adresse: f.adresse || null,
        latitude_domicile: f.lat ? Number(f.lat) : null, longitude_domicile: f.lon ? Number(f.lon) : null, qualite_interne: f.qualite_interne,
      }), 'Profil enregistré', onFait)}>
      <Field label="Type de client"><Select value={f.type_client} onChange={maj('type_client')}>{TYPES_CLIENT.map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
      <Field label="Sexe"><Select value={f.sexe} onChange={maj('sexe')}><option value="">—</option><option value="F">Féminin</option><option value="M">Masculin</option></Select></Field>
      <Field label="Date de naissance"><Input type="date" value={f.date_naissance} onChange={maj('date_naissance')} /></Field>
      <Field label="Profession / activité"><Input value={f.profession} onChange={maj('profession')} /></Field>
      <Field label="Adresse"><Input value={f.adresse} onChange={maj('adresse')} /></Field>
      <Field label="Lien avec l'institution" hint="Sert au ratio prudentiel III (prêts aux dirigeants et au personnel)">
        <Select value={f.qualite_interne} onChange={maj('qualite_interne')}>
          <option value="aucune">Aucun</option><option value="dirigeant">Dirigeant</option><option value="personnel">Membre du personnel</option><option value="personne_liee">Personne liée</option>
        </Select>
      </Field>
      <Field label="Latitude du domicile"><Input type="number" step="0.000001" value={f.lat} onChange={maj('lat')} /></Field>
      <Field label="Longitude du domicile"><Input type="number" step="0.000001" value={f.lon} onChange={maj('lon')} /></Field>
    </FormModal>
  )
}

function NouvellePiece({ clientId, onClose, onFait }: { clientId: number; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ type: 'cni', numero: '', date_emission: '', date_expiration: '' })
  const maj = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  return (
    <FormModal titre="Ajouter une pièce" onClose={onClose} busy={busy} valider="Ajouter"
      onSubmit={() => void run(() => api.post(`/api/clients/${clientId}/pieces`, { type: f.type, numero: f.numero, date_emission: f.date_emission || null, date_expiration: f.date_expiration || null }), 'Pièce ajoutée', onFait)}>
      <Field label="Type"><Select value={f.type} onChange={maj('type')}>{TYPES_PIECE.map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
      <Field label="Numéro"><Input value={f.numero} onChange={maj('numero')} required /></Field>
      <Field label="Date d'émission"><Input type="date" value={f.date_emission} onChange={maj('date_emission')} /></Field>
      <Field label="Date d'expiration"><Input type="date" value={f.date_expiration} onChange={maj('date_expiration')} /></Field>
    </FormModal>
  )
}

function NouveauLien({ clientId, onClose, onFait }: { clientId: number; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ q: '', lie_a_id: '', type: 'famille' })
  const trouves = useFetch(() => (f.q.length >= 2 ? api.get<{ id: number; nom: string; numero: string }[]>('/api/clients', { q: f.q, limit: 8 }) : Promise.resolve([])), [f.q])
  return (
    <FormModal titre="Lien avec un autre client" onClose={onClose} busy={busy} valider="Ajouter"
      onSubmit={() => void run(() => api.post(`/api/clients/${clientId}/liens`, { lie_a_id: Number(f.lie_a_id), type: f.type }), 'Lien ajouté', onFait)}>
      <Field label="Rechercher un client"><Input value={f.q} onChange={(e) => setF({ ...f, q: e.target.value })} placeholder="Nom ou numéro" /></Field>
      <Field label="Client lié">
        <Select value={f.lie_a_id} onChange={(e) => setF({ ...f, lie_a_id: e.target.value })} required>
          <option value="">— choisir —</option>
          {(trouves.data ?? []).filter((c) => c.id !== clientId).map((c) => <option key={c.id} value={c.id}>{c.nom} · {c.numero}</option>)}
        </Select>
      </Field>
      <Field label="Nature du lien">
        <Select value={f.type} onChange={(e) => setF({ ...f, type: e.target.value })}>
          <option value="famille">Famille</option><option value="groupe">Groupe</option><option value="employeur">Employeur</option><option value="associe">Associé</option><option value="autre">Autre</option>
        </Select>
      </Field>
    </FormModal>
  )
}
