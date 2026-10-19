import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { api } from '../lib/api'
import { useZones } from '../lib/hooks'
import { useSession } from '../lib/session'
import { Button, Card, Charge, Field, FormModal, Input, Page, Select, Table, useAction, useFetch } from '../components/ui'

interface Client { id: number; numero: string; nom: string; telephone: string | null; zone: string | null; actif: boolean }

export default function Clients() {
  const nav = useNavigate()
  const { can, agenceId } = useSession()
  const zones = useZones()
  const [q, setQ] = useState('')
  const [qDiff, setQDiff] = useState('')
  const [zone, setZone] = useState('')
  const [nouveau, setNouveau] = useState(false)
  useEffect(() => { const t = setTimeout(() => setQDiff(q), 250); return () => clearTimeout(t) }, [q])
  const liste = useFetch(() => api.get<Client[]>('/api/clients', { q: qDiff, zone_id: zone, limit: 200 }), [qDiff, zone, agenceId])

  return (
    <Page title="Clients" subtitle="Recherche par nom, numéro ou téléphone"
      actions={can('ref:write') && <Button variant="primary" onClick={() => setNouveau(true)}>Nouveau client</Button>}>
      <Card flush>
        <div className="card-b row">
          <Field label="Recherche"><Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Nom, numéro, téléphone…" autoFocus /></Field>
          <Field label="Zone">
            <Select value={zone} onChange={(e) => setZone(e.target.value)}>
              <option value="">Toutes</option>
              {zones.map((z) => <option key={z.id} value={z.id}>{z.code} — {z.libelle}</option>)}
            </Select>
          </Field>
        </div>
        <Charge q={liste}>
          {(rows) => (
            <Table rows={rows} onRowClick={(c) => nav(`/clients/${c.id}`)} vide="Aucun client trouvé" cols={[
              { titre: 'Numéro', render: (c) => c.numero },
              { titre: 'Nom', render: (c) => <strong>{c.nom}</strong> },
              { titre: 'Téléphone', render: (c) => c.telephone ?? '—' },
              { titre: 'Zone', render: (c) => c.zone ?? '—' },
            ]} />
          )}
        </Charge>
      </Card>
      {nouveau && <NouveauClient onClose={() => setNouveau(false)} onFait={(id) => nav(`/clients/${id}`)} />}
    </Page>
  )
}

function NouveauClient({ onClose, onFait }: { onClose: () => void; onFait: (id: number) => void }) {
  const zones = useZones()
  const { run, busy } = useAction()
  const [f, setF] = useState({ nom: '', telephone: '', zone_id: '', numero: '' })
  const maj = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  const envoyer = () =>
    void run(async () => {
      const c = await api.post<{ id: number }>('/api/clients', { nom: f.nom.trim(), telephone: f.telephone || null, zone_id: f.zone_id ? Number(f.zone_id) : null, numero: f.numero || null })
      onClose()
      onFait(c.id)
    }, 'Client créé')
  return (
    <FormModal titre="Nouveau client" onClose={onClose} onSubmit={envoyer} busy={busy} valider="Créer le client">
      <Field label="Nom complet"><Input value={f.nom} onChange={maj('nom')} required autoFocus /></Field>
      <Field label="Téléphone"><Input value={f.telephone} onChange={maj('telephone')} inputMode="tel" /></Field>
      <Field label="Zone">
        <Select value={f.zone_id} onChange={maj('zone_id')}>
          <option value="">— aucune —</option>
          {zones.map((z) => <option key={z.id} value={z.id}>{z.code} — {z.libelle}</option>)}
        </Select>
      </Field>
      <Field label="Numéro" hint="Laisser vide : attribué automatiquement"><Input value={f.numero} onChange={maj('numero')} /></Field>
    </FormModal>
  )
}
