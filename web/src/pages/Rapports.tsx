import { useState } from 'react'
import { api } from '../lib/api'
import { telechargerCsv } from '../lib/csv'
import { aujourdhui, date as fdate, nombre, xof } from '../lib/format'
import { ESTCOMPTE, LIBELLES_RUBRIQUES, SECTIONS_RUBRIQUES } from '../lib/rubriques'
import { useSession } from '../lib/session'
import { Button, Card, Charge, Field, Input, Page, Statut, Table, Tabs, useFetch } from '../components/ui'
import { ActiviteCredit, PortefeuilleCredit, RapportFinancier } from './RapportsCredit'

interface Rubrique { rubrique: string; valeur: number }
interface AgentLigne { agent: string; montant_collecte: number; mises: number; nb_lignes: number; montant_verse: number; ecart_versement: number; pertes_retrait: number }
interface ZoneLigne { zone: string; collectrice: string | null; montant_collecte: number; mises: number; nb_lignes: number; retraits: number; remboursements: number; ecarts_retrait: number }
interface Situation { credit: string; client: string; type: string; mode_remboursement: string; montant_accorde: number; capital_restant: number; echeances_restantes: number; prochaine_echeance: string | null; garantie_bloquee: number; statut_a_date: string }

export default function Rapports() {
  const { agenceId } = useSession()
  const [jour, setJour] = useState(aujourdhui())
  const [onglet, setOnglet] = useState('journalier')
  const [debut, setDebut] = useState(`${aujourdhui().slice(0, 7)}-01`)
  const periode = onglet === 'activite' || onglet === 'financier'
  return (
    <Page title="Rapports" subtitle="Calculés à partir des dates d'opération : une date passée se reproduit à l'identique"
      actions={<>
        {periode && <Field label="Du"><Input type="date" value={debut} onChange={(e) => setDebut(e.target.value || debut)} /></Field>}
        <Field label={periode ? 'Au' : 'Jour'}><Input type="date" value={jour} onChange={(e) => setJour(e.target.value || aujourdhui())} /></Field>
        <Button onClick={() => window.print()}>Imprimer</Button></>}>
      <Tabs actif={onglet} onChange={setOnglet} tabs={[
        { id: 'journalier', titre: 'Journalier' }, { id: 'agents', titre: 'Par agent' }, { id: 'zones', titre: 'Par zone' }, { id: 'credits', titre: 'Situation des crédits' },
        { id: 'portefeuille', titre: 'Portefeuille & PAR' }, { id: 'activite', titre: 'Activité de crédit' }, { id: 'financier', titre: 'Rapport financier' },
      ]} />
      {onglet === 'portefeuille' && <PortefeuilleCredit key={`${jour}-${agenceId}`} jour={jour} />}
      {onglet === 'activite' && <ActiviteCredit key={`${debut}-${jour}-${agenceId}`} du={debut} au={jour} />}
      {onglet === 'financier' && <RapportFinancier key={`${debut}-${jour}-${agenceId}`} du={debut} au={jour} />}
      {onglet === 'journalier' && <Journalier key={`${jour}-${agenceId}`} jour={jour} />}
      {onglet === 'agents' && <Agents key={`${jour}-${agenceId}`} jour={jour} />}
      {onglet === 'zones' && <Zones key={`${jour}-${agenceId}`} jour={jour} />}
      {onglet === 'credits' && <Credits key={`${jour}-${agenceId}`} jour={jour} />}
    </Page>
  )
}

function Journalier({ jour }: { jour: string }) {
  const q = useFetch(() => api.get<{ rubriques: Rubrique[] }>('/api/rapports/journalier', { date: jour }), [jour])
  return (
    <Charge q={q}>
      {(d) => {
        const v = new Map(d.rubriques.map((r) => [r.rubrique, r.valeur]))
        const fmt = (c: string) => (ESTCOMPTE.has(c) ? nombre(v.get(c)) : xof(v.get(c)))
        return (
          <div className="stack">
            <div className="actions">
              <Button small onClick={() => telechargerCsv(`rapport-journalier-${jour}`, ['Rubrique', 'Valeur'],
                d.rubriques.map((r) => [LIBELLES_RUBRIQUES[r.rubrique] ?? r.rubrique, r.valeur]))}>Exporter en CSV</Button>
            </div>
            <div className="grid-2">
              {SECTIONS_RUBRIQUES.map((s) => (
                <Card key={s.titre} title={s.titre} flush>
                  <table className="t"><tbody>
                    {s.cles.map((c) => <tr key={c}><td>{LIBELLES_RUBRIQUES[c]}</td><td className="num">{fmt(c)}</td></tr>)}
                  </tbody></table>
                </Card>
              ))}
            </div>
          </div>
        )
      }}
    </Charge>
  )
}

function Agents({ jour }: { jour: string }) {
  const q = useFetch(() => api.get<AgentLigne[]>('/api/rapports/journalier/agents', { date: jour }), [jour])
  return (
    <Card flush actions={q.data && <Button small onClick={() => telechargerCsv(`rapport-agents-${jour}`, ['Agent', 'Collecté', 'Mises', 'Lignes', 'Versé', 'Écart', 'Pertes'],
      q.data!.map((a) => [a.agent, a.montant_collecte, a.mises, a.nb_lignes, a.montant_verse, a.ecart_versement, a.pertes_retrait]))}>Exporter en CSV</Button>}>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucun agent" cols={[
            { titre: 'Agent', render: (a) => <strong>{a.agent}</strong> },
            { titre: 'Collecté', num: true, render: (a) => xof(a.montant_collecte) },
            { titre: 'Mises', num: true, render: (a) => xof(a.mises) },
            { titre: 'Lignes', num: true, render: (a) => a.nb_lignes },
            { titre: 'Versé', num: true, render: (a) => xof(a.montant_verse) },
            { titre: 'Écart de versement', num: true, render: (a) => (a.ecart_versement > 0 ? `Manquant ${xof(a.ecart_versement)}` : a.ecart_versement < 0 ? `Surplus ${xof(-a.ecart_versement)}` : '—') },
            { titre: 'Pertes sur retraits', num: true, render: (a) => xof(a.pertes_retrait) },
          ]} />
        )}
      </Charge>
    </Card>
  )
}

function Zones({ jour }: { jour: string }) {
  const q = useFetch(() => api.get<ZoneLigne[]>('/api/rapports/journalier/zones', { date: jour }), [jour])
  return (
    <Card flush actions={q.data && <Button small onClick={() => telechargerCsv(`rapport-zones-${jour}`, ['Zone', 'Collectrice', 'Collecté', 'Mises', 'Lignes', 'Retraits', 'Remboursements', 'Écarts'],
      q.data!.map((z) => [z.zone, z.collectrice, z.montant_collecte, z.mises, z.nb_lignes, z.retraits, z.remboursements, z.ecarts_retrait]))}>Exporter en CSV</Button>}>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucune zone" cols={[
            { titre: 'Zone', render: (z) => <strong>{z.zone}</strong> },
            { titre: 'Collectrice', render: (z) => z.collectrice ?? '—' },
            { titre: 'Collecté', num: true, render: (z) => xof(z.montant_collecte) },
            { titre: 'Mises', num: true, render: (z) => xof(z.mises) },
            { titre: 'Lignes', num: true, render: (z) => z.nb_lignes },
            { titre: 'Retraits payés', num: true, render: (z) => xof(z.retraits) },
            { titre: 'Remboursements', num: true, render: (z) => xof(z.remboursements) },
            { titre: 'Pertes sur écarts', num: true, render: (z) => xof(z.ecarts_retrait) },
          ]} />
        )}
      </Charge>
    </Card>
  )
}

function Credits({ jour }: { jour: string }) {
  const q = useFetch(() => api.get<Situation[]>('/api/rapports/credits/situation', { date: jour }), [jour])
  return (
    <Card flush actions={q.data && <Button small onClick={() => telechargerCsv(`situation-credits-${jour}`, ['Crédit', 'Client', 'Accordé', 'Capital restant', 'Échéances restantes', 'Prochaine échéance', 'Garantie bloquée', 'Statut'],
      q.data!.map((c) => [c.credit, c.client, c.montant_accorde, c.capital_restant, c.echeances_restantes, c.prochaine_echeance, c.garantie_bloquee, c.statut_a_date]))}>Exporter en CSV</Button>}>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucun crédit débloqué à cette date" cols={[
            { titre: 'Crédit', render: (c) => <><strong>{c.credit}</strong><div className="muted">{c.client}</div></> },
            { titre: 'Accordé', num: true, render: (c) => xof(c.montant_accorde) },
            { titre: 'Capital restant', num: true, render: (c) => xof(c.capital_restant) },
            { titre: 'Échéances restantes', num: true, render: (c) => c.echeances_restantes },
            { titre: 'Prochaine échéance', render: (c) => fdate(c.prochaine_echeance) },
            { titre: 'Garantie bloquée', num: true, render: (c) => (c.garantie_bloquee ? xof(c.garantie_bloquee) : '—') },
            { titre: 'Statut à la date', render: (c) => <Statut s={c.statut_a_date} /> },
          ]} />
        )}
      </Charge>
    </Card>
  )
}
