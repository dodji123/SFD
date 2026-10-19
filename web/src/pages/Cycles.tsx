import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { api } from '../lib/api'
import { date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Card, Charge, Field, Input, Page, Select, Statut, Table, useFetch } from '../components/ui'

export interface CycleLigne {
  id: number; numero: string; client_id: number; client: string; type_cycle: number; statut: string
  mise_courante: number; mise_finale: number | null; date_debut: string; date_fin: string
  nb_lignes: number; nb_lignes_prevues: number; montant_collecte: number; montant_previsionnel: number | null; net: number
}

export default function Cycles() {
  const nav = useNavigate()
  const { agenceId } = useSession()
  const [statut, setStatut] = useState('en_cours')
  const [q, setQ] = useState('')
  const [qd, setQd] = useState('')
  useEffect(() => { const t = setTimeout(() => setQd(q), 250); return () => clearTimeout(t) }, [q])
  const liste = useFetch(() => api.get<CycleLigne[]>('/api/cycles', { statut, q: qd, limit: 300 }), [statut, qd, agenceId])
  return (
    <Page title="Cycles de tontine" subtitle="Les cycles d'épargne journalière avec leur livret de 31 lignes par page">
      <Card flush>
        <div className="card-b row">
          <Field label="Recherche"><Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Numéro de cycle ou nom du client" /></Field>
          <Field label="Statut">
            <Select value={statut} onChange={(e) => setStatut(e.target.value)}>
              <option value="">Tous</option>
              <option value="en_cours">En cours</option>
              <option value="clos">Clos (retrait à faire)</option>
              <option value="retire">Retirés</option>
            </Select>
          </Field>
        </div>
        <Charge q={liste}>
          {(rows) => (
            <Table rows={rows} onRowClick={(c) => nav(`/cycles/${c.id}`)} vide="Aucun cycle" cols={[
              { titre: 'Cycle', render: (c) => <strong>{c.numero}</strong> },
              { titre: 'Client', render: (c) => c.client },
              { titre: 'Type', render: (c) => `Type ${c.type_cycle}` },
              { titre: 'Mise', num: true, render: (c) => xof(c.mise_finale ?? c.mise_courante) },
              { titre: 'Livret', num: true, render: (c) => `${c.nb_lignes} / ${c.nb_lignes_prevues}` },
              { titre: 'Collecté', num: true, render: (c) => xof(c.montant_collecte) },
              { titre: 'Fin', render: (c) => fdate(c.date_fin) },
              { titre: 'Statut', render: (c) => <Statut s={c.statut} /> },
            ]} />
          )}
        </Charge>
      </Card>
    </Page>
  )
}
