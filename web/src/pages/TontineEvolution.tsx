import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { Card, Charge, Field, Input, Kpi, Page, Table, useFetch } from '../components/ui'

interface Jour { jour: string; total: number }
interface Agent { agent_id: number; matricule: string | null; agent: string | null; total: number; precedent: number; jours: Jour[] }
interface Evolution { du: string; au: string; precedent_du: string; precedent_au: string; total: number; total_precedent: number; jours: Jour[]; agents: Agent[] }

const variation = (actuel: number, precedent: number) => (precedent === 0 ? (actuel === 0 ? '—' : 'nouveau') : `${actuel >= precedent ? '+' : ''}${(((actuel - precedent) / precedent) * 100).toFixed(1)} %`)

// Évolution de la collecte : global et par agent, jour par jour, comparé à la période précédente de même durée.
// Par défaut : le mois calendaire en cours.
export default function TontineEvolution() {
  const debutMois = aujourdhui().slice(0, 8) + '01'
  const [du, setDu] = useState(debutMois)
  const [au, setAu] = useState(aujourdhui())
  const evo = useFetch(() => api.get<Evolution>('/api/rapports/collecte-evolution', { du, au }), [du, au])

  return (
    <Page title="Évolution des collectes" subtitle="Collecte globale et par agent, comparée à la période précédente de même durée">
      <Card>
        <div className="grid-form">
          <Field label="Du"><Input type="date" value={du} onChange={(e) => setDu(e.target.value)} /></Field>
          <Field label="Au"><Input type="date" value={au} onChange={(e) => setAu(e.target.value)} /></Field>
          <div className="row" style={{ alignItems: 'flex-end' }}>
            <button type="button" className="btn btn-sm" onClick={() => { setDu(debutMois); setAu(aujourdhui()) }}>Mois en cours</button>
          </div>
        </div>
      </Card>
      <Charge q={evo}>
        {(d) => (
          <>
            <div className="grid-kpi">
              <Kpi label="Collecte de la période" value={xof(d.total)} />
              <Kpi label="Période précédente" value={xof(d.total_precedent)} />
              <Kpi label="Évolution" value={variation(d.total, d.total_precedent)} tone={d.total < d.total_precedent ? 'warn' : undefined} />
            </div>
            <p className="muted" style={{ margin: '8px 0 16px' }}>
              Période précédente : du {fdate(d.precedent_du)} au {fdate(d.precedent_au)}.
            </p>
            <Card title="Collecte globale par jour" flush>
              <Table rows={d.jours} vide="Aucune collecte sur la période" cols={[
                { titre: 'Jour', render: (j) => fdate(j.jour) },
                { titre: 'Collecté', num: true, render: (j) => <strong>{xof(j.total)}</strong> },
              ]} />
            </Card>
            <div style={{ height: 16 }} />
            <Card title="Collecte par agent" flush>
              <Table rows={d.agents} vide="Aucune collecte sur la période" cols={[
                { titre: 'Agent', render: (a) => <><strong>{a.agent ?? '—'}</strong><div className="muted">{a.matricule ?? ''}</div></> },
                { titre: 'Jours actifs', num: true, render: (a) => a.jours.length },
                { titre: 'Collecté', num: true, render: (a) => <strong>{xof(a.total)}</strong> },
                { titre: 'Période précédente', num: true, render: (a) => xof(a.precedent) },
                { titre: 'Évolution', num: true, render: (a) => variation(a.total, a.precedent) },
              ]} />
            </Card>
          </>
        )}
      </Charge>
    </Page>
  )
}
