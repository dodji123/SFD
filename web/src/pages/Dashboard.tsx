import { useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof, nombre } from '../lib/format'
import { ESTCOMPTE, LIBELLES_RUBRIQUES, SECTIONS_RUBRIQUES } from '../lib/rubriques'
import { useSession } from '../lib/session'
import { Card, Charge, Field, Input, Kpi, Page, Statut, Table, useFetch } from '../components/ui'

interface Tdb {
  cycles_en_cours: number; collecte_du_jour: number; retraits_a_traiter: number; credits_en_retard: number
  demandes_a_decider: number; sessions_ouvertes: number; dettes_agents: number; surplus_a_traiter: number
}
interface Rubrique { rubrique: string; valeur: number }
interface Retrait { id: number; cycle: string; client: string; nature: string; montant: number; statut: string; date_demande: string }
interface Echu { credit: string; client: string; no_echeance: number; date_prevue: string; jours_retard: number; du: number; penalite: number }

const NATURES: Record<string, string> = { retrait_client: 'Retrait client', virement_vers_epargne: 'Virement vers épargne', remboursement: 'Remboursement de crédit', regularisation: 'Régularisation' }

export default function Dashboard() {
  const { can, agenceId } = useSession()
  const nav = useNavigate()
  const [jour, setJour] = useState(aujourdhui())
  const tdb = useFetch(() => api.get<Tdb>('/api/tableau-de-bord', { date: jour }), [jour, agenceId])
  const rapport = useFetch(() => (can('rapports:read') ? api.get<{ rubriques: Rubrique[] }>('/api/rapports/journalier', { date: jour }) : Promise.resolve({ rubriques: [] })), [jour, agenceId])
  const retraits = useFetch(() => api.get<Retrait[]>('/api/retraits', { limit: 100 }), [agenceId])
  const echus = useFetch(() => (can('rapports:read') ? api.get<Echu[]>('/api/rapports/credits/echus', { date: jour }) : Promise.resolve([] as Echu[])), [jour, agenceId])

  const valeurs = new Map((rapport.data?.rubriques ?? []).map((r) => [r.rubrique, r.valeur]))
  const aTraiter = (retraits.data ?? []).filter((r) => r.statut !== 'execute' && r.statut !== 'annule' && r.nature !== 'regularisation')

  return (
    <Page title="Tableau de bord" subtitle="Vue d'ensemble de l'agence" actions={<Field label="Jour"><Input type="date" value={jour} onChange={(e) => setJour(e.target.value || aujourdhui())} /></Field>}>
      <Charge q={tdb}>
        {(t) => (
          <div className="grid-kpi">
            <Kpi label="Collecte du jour" value={xof(t.collecte_du_jour)} />
            <Kpi label="Cycles en cours" value={nombre(t.cycles_en_cours)} />
            <Kpi label="Retraits à traiter" value={nombre(t.retraits_a_traiter)} tone={t.retraits_a_traiter ? 'warn' : undefined} />
            <Kpi label="Crédits en retard" value={nombre(t.credits_en_retard)} tone={t.credits_en_retard ? 'bad' : undefined} />
            <Kpi label="Demandes de crédit à décider" value={nombre(t.demandes_a_decider)} tone={t.demandes_a_decider ? 'warn' : undefined} />
            <Kpi label="Sessions de caisse ouvertes" value={nombre(t.sessions_ouvertes)} />
            <Kpi label="Dettes des agents" value={xof(t.dettes_agents)} tone={t.dettes_agents ? 'warn' : undefined} />
            <Kpi label="Surplus à traiter" value={xof(t.surplus_a_traiter)} />
          </div>
        )}
      </Charge>

      <div className="grid-2">
        <Card title="Retraits en attente" actions={<Link to="/retraits">Tout voir</Link>} flush>
          <Charge q={retraits}>
            {() => (
              <Table rows={aTraiter.slice(0, 8)} vide="Aucun retrait en attente" onRowClick={() => nav('/retraits')} cols={[
                { titre: 'Client', render: (r) => <><strong>{r.client}</strong><div className="muted">{r.cycle}</div></> },
                { titre: 'Nature', render: (r) => NATURES[r.nature] ?? r.nature },
                { titre: 'Montant', num: true, render: (r) => xof(r.montant) },
                { titre: 'Statut', render: (r) => <Statut s={r.statut} /> },
              ]} />
            )}
          </Charge>
        </Card>
        {can('rapports:read') && (
          <Card title={`Échéances échues au ${fdate(jour)}`} actions={<Link to="/credits">Crédits</Link>} flush>
            <Charge q={echus}>
              {(rows) => (
                <Table rows={rows.slice(0, 8)} vide="Aucune échéance en retard" cols={[
                  { titre: 'Client', render: (r) => <><strong>{r.client}</strong><div className="muted">{r.credit} · éch. {r.no_echeance}</div></> },
                  { titre: 'Retard', num: true, render: (r) => `${r.jours_retard} j` },
                  { titre: 'Dû', num: true, render: (r) => xof(r.du) },
                  { titre: 'Pénalité', num: true, render: (r) => xof(r.penalite) },
                ]} />
              )}
            </Charge>
          </Card>
        )}
      </div>

      {can('rapports:read') && (
        <Card title={`Journée du ${fdate(jour)}`} actions={<Link to="/rapports">Rapports détaillés</Link>}>
          <Charge q={rapport}>
            {() => (
              <div className="grid-2">
                {SECTIONS_RUBRIQUES.map((s) => {
                  const lignes = s.cles.filter((c) => valeurs.get(c))
                  return (
                    <div key={s.titre}>
                      <h3>{s.titre}</h3>
                      {lignes.length === 0 ? <p className="muted">Aucune opération</p> : (
                        <table className="t"><tbody>
                          {lignes.map((c) => (
                            <tr key={c}><td>{LIBELLES_RUBRIQUES[c]}</td><td className="num">{ESTCOMPTE.has(c) ? nombre(valeurs.get(c)) : xof(valeurs.get(c))}</td></tr>
                          ))}
                        </tbody></table>
                      )}
                    </div>
                  )
                })}
              </div>
            )}
          </Charge>
        </Card>
      )}
    </Page>
  )
}
