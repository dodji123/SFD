import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { FiltreTableau, filtrer } from '../components/ChampClient'
import { useAffichagePiece } from '../components/Piece'
import { Button, Card, Charge, Field, Input, Kpi, Page, Select, Table, useFetch } from '../components/ui'

interface Ligne { id: number; numero: string; type: string; date_piece: string; libelle: string; montant: number; client_numero: string; client: string; compte: string | null; nb_lignes: number }

const TYPES: Record<string, string> = {
  depot_epargne: 'Dépôt', retrait_epargne: 'Retrait', adhesion: 'Adhésion', souscription_parts: 'Parts sociales', depot_garantie: 'Dépôt de garantie',
  liberation_garantie: 'Déblocage de garantie', depot_terme: 'Dépôt à terme', deblocage_terme: 'Déblocage de dépôt à terme', rupture_terme: 'Rupture de dépôt à terme',
  retrait_tontine: 'Retrait de tontine',
}

export default function Pieces() {
  const { agenceId } = useSession()
  const [jour, setJour] = useState(aujourdhui())
  const [toutes, setToutes] = useState(false)
  const [type, setType] = useState('')
  const [filtre, setFiltre] = useState('')
  const piece = useAffichagePiece()
  const q = useFetch(() => api.get<Ligne[]>('/api/pieces', { ...(toutes ? {} : { date: jour }), ...(type ? { type } : {}) }), [jour, toutes, type, agenceId])

  return (
    <Page title="Pièces justificatives" subtitle="Reçus et pièces des opérations de guichet, à réimprimer. Le dépôt de tontine n'a pas de pièce ; les retraits de plusieurs cycles se regroupent sur une seule pièce">
      <Card>
        <div className="row">
          <Field label="Jour"><Input type="date" max={aujourdhui()} value={jour} disabled={toutes} onChange={(e) => setJour(e.target.value || aujourdhui())} /></Field>
          <Field label="Type de pièce">
            <Select value={type} onChange={(e) => setType(e.target.value)}>
              <option value="">— tous les types —</option>
              {Object.entries(TYPES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
            </Select>
          </Field>
          <label className="actions"><input type="checkbox" checked={toutes} onChange={(e) => setToutes(e.target.checked)} /> Toutes les dates (200 dernières pièces)</label>
        </div>
      </Card>
      <Charge q={q}>
        {(rows) => {
          const vues = filtrer(rows, filtre, (r) => [r.client, r.client_numero, r.compte, r.numero])
          return (
            <Card title={toutes ? 'Dernières pièces' : `Pièces du ${fdate(jour)}`} flush>
              <div className="grid-kpi" style={{ padding: '0 16px' }}>
                <Kpi label="Pièces" value={vues.length} />
                <Kpi label="Montant total" value={xof(vues.reduce((s, r) => s + r.montant, 0))} />
              </div>
              <FiltreTableau valeur={filtre} onChange={setFiltre} />
              <Table rows={vues} onRowClick={(r) => piece.ouvrir(r.id)} vide={filtre ? 'Aucune pièce ne correspond au filtre' : 'Aucune pièce'} cols={[
                { titre: 'N°', render: (r) => r.numero },
                { titre: 'Date', render: (r) => fdate(r.date_piece) },
                { titre: 'Type', render: (r) => TYPES[r.type] ?? r.type },
                { titre: 'Client', render: (r) => <><strong>{r.client}</strong><div className="muted">{r.client_numero}</div></> },
                { titre: 'Compte', render: (r) => r.compte ?? '—' },
                { titre: 'Lignes', num: true, render: (r) => r.nb_lignes },
                { titre: 'Montant', num: true, render: (r) => xof(r.montant) },
                { titre: '', render: (r) => <Button small onClick={(e) => { e.stopPropagation(); piece.ouvrir(r.id) }}>Voir / imprimer</Button> },
              ]} />
            </Card>
          )
        }}
      </Charge>
      {piece.modal}
    </Page>
  )
}
