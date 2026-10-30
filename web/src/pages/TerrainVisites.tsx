import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate } from '../lib/format'
import { Card, Charge, Field, Input, Page, Table, useFetch } from '../components/ui'

interface Visite { id: number; date_visite: string; type: string; resultat: string | null; agent: string; client_numero: string; client: string; credit: string | null; latitude: number | null; longitude: number | null; lieu: string | null; precision_m: number | null }

// Visites de terrain et recouvrements de la période, avec la position GPS du lieu visité (ouvrable dans une carte).
export default function TerrainVisites() {
  const debutMois = aujourdhui().slice(0, 8) + '01'
  const [du, setDu] = useState(debutMois)
  const [au, setAu] = useState(aujourdhui())
  const q = useFetch(() => api.get<Visite[]>('/api/terrain/visites', { du, au }), [du, au])
  return (
    <Page title="Visites terrain et recouvrements" subtitle="Sorties de l'agent, avec la position GPS du lieu visité">
      <Card>
        <div className="grid-form">
          <Field label="Du"><Input type="date" value={du} onChange={(e) => setDu(e.target.value)} /></Field>
          <Field label="Au"><Input type="date" value={au} onChange={(e) => setAu(e.target.value)} /></Field>
        </div>
      </Card>
      <Charge q={q}>
        {(rows) => (
          <Card title={`Visites et recouvrements (${rows.length})`} flush>
            <Table rows={rows} vide="Aucune visite sur la période" cols={[
              { titre: 'Date', render: (v) => fdate(v.date_visite) },
              { titre: 'Type', render: (v) => (v.type === 'recouvrement' ? 'Recouvrement' : 'Visite') },
              { titre: 'Agent', render: (v) => v.agent },
              { titre: 'Client', render: (v) => <><strong>{v.client}</strong><div className="muted">{v.client_numero}{v.credit ? ` · ${v.credit}` : ''}</div></> },
              { titre: 'Lieu visité', render: (v) => (v.latitude !== null && v.longitude !== null
                ? <a href={`https://www.google.com/maps?q=${v.latitude},${v.longitude}`} target="_blank" rel="noreferrer">{v.lieu ?? 'Voir sur la carte'}</a>
                : <span className="muted">Pas de position</span>) },
              { titre: 'Précision', num: true, render: (v) => (v.precision_m !== null ? `± ${Math.round(v.precision_m)} m` : '—') },
              { titre: 'Résultat', render: (v) => v.resultat ?? '—' },
            ]} />
          </Card>
        )}
      </Charge>
    </Page>
  )
}
