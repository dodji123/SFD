import { useState } from 'react'
import { Link } from 'react-router-dom'
import { api } from '../lib/api'
import { date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { FiltreTableau, filtrer } from '../components/ChampClient'
import { Alert, Badge, Button, Card, Charge, Kpi, Page, Table, Tabs, useAction, useFetch } from '../components/ui'

interface Garantie { id: number; numero: string; client_numero: string; client: string; compte: string; montant: number; motif: string | null; credit: string | null; credit_statut: string | null; date_depot: string }
interface Terme { id: number; numero: string; client_numero: string; client: string; compte: string; montant: number; duree_mois: number; taux_annuel: number; date_depot: string; date_echeance: string; interets_prevus: number; echu: boolean }
interface CreditAttente { id: number; numero: string; client_numero: string; client: string; montant: number }
interface Reponse { garanties: Garantie[]; termes: Terme[]; credits: CreditAttente[] }

export default function Deblocages() {
  const { can, agenceId } = useSession()
  const q = useFetch(() => api.get<Reponse>('/api/depots/deblocages'), [agenceId])
  const [onglet, setOnglet] = useState<'garanties' | 'termes' | 'credits'>('garanties')
  const [filtre, setFiltre] = useState('')
  const { run, busy } = useAction()
  const peut = can('depot:debloquer')

  return (
    <Page title="Déblocages" subtitle="Libération des dépôts de garantie, versement des dépôts à terme (échéance ou rupture anticipée) et crédits approuvés en attente">
      <Charge q={q}>
        {(d) => (
          <>
            <div className="grid-kpi">
              <Kpi label="Garanties bloquées" value={`${d.garanties.length} — ${xof(d.garanties.reduce((s, g) => s + g.montant, 0))}`} />
              <Kpi label="Dépôts à terme en cours" value={`${d.termes.length} — ${xof(d.termes.reduce((s, t) => s + t.montant, 0))}`} />
              <Kpi label="À l'échéance" value={d.termes.filter((t) => t.echu).length} tone={d.termes.some((t) => t.echu) ? 'warn' : undefined} />
              <Kpi label="Crédits approuvés à débloquer" value={d.credits.length} tone={d.credits.length ? 'warn' : undefined} />
            </div>
            <Card>
              <Tabs actif={onglet} onChange={(id) => { setOnglet(id as typeof onglet); setFiltre('') }} tabs={[
                { id: 'garanties', titre: 'Dépôts de garantie' }, { id: 'termes', titre: 'Dépôts à terme' }, { id: 'credits', titre: 'Crédits' }]} />
              <FiltreTableau valeur={filtre} onChange={setFiltre} />
              {onglet === 'garanties' && (
                <Table rows={filtrer(d.garanties, filtre, (g) => [g.client, g.client_numero, g.compte, g.numero, g.credit])} vide="Aucun dépôt de garantie bloqué" cols={[
                  { titre: 'N°', render: (g) => g.numero },
                  { titre: 'Client', render: (g) => <><strong>{g.client}</strong><div className="muted">{g.client_numero}</div></> },
                  { titre: 'Compte', render: (g) => g.compte },
                  { titre: 'Crédit rattaché', render: (g) => (g.credit ? <>{g.credit} {g.credit_statut === 'solde' ? <Badge tone="ok">soldé</Badge> : <Badge tone="warn">non soldé</Badge>}</> : '—') },
                  { titre: 'Déposé le', render: (g) => fdate(g.date_depot) },
                  { titre: 'Montant', num: true, render: (g) => xof(g.montant) },
                  { titre: '', render: (g) => peut
                    ? <Button small variant="primary" disabled={busy || (g.credit !== null && g.credit_statut !== 'solde')}
                        onClick={() => { if (window.confirm(`Libérer le dépôt de garantie de ${xof(g.montant)} de ${g.client} ? La somme redevient disponible sur le compte ${g.compte}.`)) void run(() => api.post(`/api/depots/garanties/${g.id}/liberer`, {}), 'Dépôt de garantie libéré', q.reload) }}>Débloquer</Button>
                    : null },
                ]} />
              )}
              {onglet === 'termes' && (
                <Table rows={filtrer(d.termes, filtre, (t) => [t.client, t.client_numero, t.compte, t.numero])} vide="Aucun dépôt à terme en cours" cols={[
                  { titre: 'N°', render: (t) => t.numero },
                  { titre: 'Client', render: (t) => <><strong>{t.client}</strong><div className="muted">{t.client_numero}</div></> },
                  { titre: 'Compte', render: (t) => t.compte },
                  { titre: 'Placé', num: true, render: (t) => xof(t.montant) },
                  { titre: 'Échéance', render: (t) => <>{fdate(t.date_echeance)} {t.echu ? <Badge tone="warn">échu</Badge> : <Badge tone="info">en cours</Badge>}</> },
                  { titre: 'Intérêts prévus', num: true, render: (t) => xof(t.interets_prevus) },
                  { titre: '', render: (t) => !peut ? null : t.echu
                    ? <Button small variant="primary" disabled={busy}
                        onClick={() => { if (window.confirm(`Débloquer ${t.numero} : ${xof(t.montant)} de capital et ${xof(t.interets_prevus)} d'intérêts seront versés sur le compte ${t.compte}.`)) void run(() => api.post(`/api/depots/terme/${t.id}/debloquer`, {}), 'Dépôt à terme débloqué', q.reload) }}>Débloquer</Button>
                    : <Button small variant="danger" disabled={busy}
                        onClick={() => { if (window.confirm(`Rupture anticipée de ${t.numero} avant le ${fdate(t.date_echeance)} : le capital de ${xof(t.montant)} est rendu, les intérêts courus sont diminués de la pénalité. Continuer ?`)) void run(() => api.post(`/api/depots/terme/${t.id}/rompre`, {}), 'Rupture anticipée enregistrée', q.reload) }}>Rupture anticipée</Button> },
                ]} />
              )}
              {onglet === 'credits' && (
                <>
                  <Alert tone="info">Le déblocage d'un crédit approuvé se fait dans la page Crédits (mode, caisse, échéancier).</Alert>
                  <Table rows={filtrer(d.credits, filtre, (c) => [c.client, c.client_numero, c.numero])} vide="Aucun crédit approuvé en attente de déblocage" cols={[
                    { titre: 'Demande', render: (c) => c.numero },
                    { titre: 'Client', render: (c) => <><strong>{c.client}</strong><div className="muted">{c.client_numero}</div></> },
                    { titre: 'Montant', num: true, render: (c) => xof(c.montant) },
                    { titre: '', render: () => <Link to="/credits">Ouvrir la page Crédits</Link> },
                  ]} />
                </>
              )}
            </Card>
          </>
        )}
      </Charge>
    </Page>
  )
}
