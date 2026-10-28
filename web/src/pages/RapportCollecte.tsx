import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useAgents, useProduitsEpargne } from '../lib/hooks'
import { Alert, Card, Charge, Field, Input, Page, Select, Table, Tabs, useFetch } from '../components/ui'

interface Ligne { cle: string; libelle: string; nb_lignes: number; montant_collecte: number; mises: number; collectrices: string | null }
interface Detail { date_collecte: string; client_numero: string; client: string; zone: string | null; produit: string; agent: string | null; montant_collecte: number; mise_appliquee: number; cycle: string; page: number; no_ligne: number }
type Groupe = 'produit' | 'agent' | 'zone'

const premierJour = () => aujourdhui().slice(0, 8) + '01'
const TITRES: Record<Groupe, string> = { produit: 'Produit', agent: 'Agent', zone: 'Zone' }

// Rapport des collectes d'une période : synthèse par produit, agent ou zone, ou détail ligne à ligne avec recherche d'un client.
// Une zone regroupe les collectes de tous ses clients, même si elle a changé de collectrice : « Collectrices » donne les affectations et leurs dates.
export default function RapportCollecte() {
  const produits = useProduitsEpargne('collecte')
  const agents = useAgents()
  const [vue, setVue] = useState<'synthese' | 'detail'>('synthese')
  const [du, setDu] = useState(premierJour)
  const [au, setAu] = useState(aujourdhui)
  const [groupe, setGroupe] = useState<Groupe>('produit')
  const [produit, setProduit] = useState('')
  const [agent, setAgent] = useState('')
  const [recherche, setRecherche] = useState('')
  const invalide = au < du
  const q = useFetch(() => (invalide ? Promise.resolve([] as Ligne[]) : api.get<Ligne[]>('/api/rapports/collecte-periode',
    { du, au, groupe, produit_id: produit ? Number(produit) : undefined })), [du, au, groupe, produit])
  const detail = useFetch(() => (invalide || vue !== 'detail' ? Promise.resolve([] as Detail[]) : api.get<Detail[]>('/api/rapports/collecte-periode/detail',
    { du, au, produit_id: produit ? Number(produit) : undefined, agent_id: agent ? Number(agent) : undefined, q: recherche.trim() || undefined })),
  [vue, du, au, produit, agent, recherche])
  return (
    <Page title="Rapport de collecte" subtitle="Collectes d'une période : synthèse par produit, agent ou zone, puis détail par client">
      <Tabs actif={vue} onChange={(id) => setVue(id as 'synthese' | 'detail')} tabs={[{ id: 'synthese', titre: 'Synthèse' }, { id: 'detail', titre: 'Détail par client' }]} />
      <Card>
        <div className="grid-form">
          <Field label="Du"><Input type="date" value={du} onChange={(e) => setDu(e.target.value)} /></Field>
          <Field label="Au"><Input type="date" value={au} onChange={(e) => setAu(e.target.value)} /></Field>
          {vue === 'synthese' && (
            <Field label="Regrouper par">
              <Select value={groupe} onChange={(e) => setGroupe(e.target.value as Groupe)}>
                <option value="produit">Produit</option>
                <option value="agent">Agent</option>
                <option value="zone">Zone</option>
              </Select>
            </Field>
          )}
          <Field label="Produit">
            <Select value={produit} onChange={(e) => setProduit(e.target.value)}>
              <option value="">Tous les produits</option>
              {produits.map((p) => <option key={p.id} value={p.id}>{p.code} — {p.libelle}</option>)}
            </Select>
          </Field>
          {vue === 'detail' && (
            <>
              <Field label="Agent">
                <Select value={agent} onChange={(e) => setAgent(e.target.value)}>
                  <option value="">Tous les agents</option>
                  {agents.map((a) => <option key={a.id} value={a.id}>{a.matricule} — {a.nom}</option>)}
                </Select>
              </Field>
              <Field label="Client" hint="Nom ou numéro, une partie suffit">
                <Input value={recherche} placeholder="ex. Mensah ou C001" autoComplete="off" onChange={(e) => setRecherche(e.target.value)} />
              </Field>
            </>
          )}
        </div>
        {invalide && <Alert tone="warn">La date de fin précède la date de début.</Alert>}
      </Card>
      {vue === 'synthese' && (
        <Card flush>
          {!invalide && (
            <Charge q={q}>
              {(rows) => {
                const total = (k: 'nb_lignes' | 'montant_collecte' | 'mises') => rows.reduce((s, l) => s + Number(l[k]), 0)
                return (
                  <>
                    <Table rows={rows} vide="Aucune collecte sur cette période" cols={[
                      { titre: TITRES[groupe], render: (l) => <><strong>{l.libelle}</strong><div className="muted">{l.cle}</div></> },
                      { titre: 'Collectes', num: true, render: (l) => l.nb_lignes },
                      { titre: 'Montant collecté', num: true, render: (l) => xof(l.montant_collecte) },
                      { titre: 'Mises', num: true, render: (l) => xof(l.mises) },
                      ...(groupe === 'zone' ? [{ titre: 'Collectrices (dates d\'affectation)', render: (l: Ligne) => l.collectrices ?? 'aucune' }] : []),
                    ]} />
                    {rows.length > 0 && (
                      <p className="muted" style={{ padding: '8px 16px' }}>
                        Total : {total('nb_lignes')} collecte(s) · {xof(total('montant_collecte'))} · mises {xof(total('mises'))}
                      </p>
                    )}
                  </>
                )
              }}
            </Charge>
          )}
        </Card>
      )}
      {vue === 'detail' && (
        <Card flush title={`Collectes détaillées (${detail.data?.length ?? 0})`}>
          {!invalide && (
            <Charge q={detail}>
              {(rows) => {
                const total = rows.reduce((s, l) => s + Number(l.montant_collecte), 0)
                return (
                  <>
                    <Table rows={rows} vide={recherche.trim() ? 'Aucune collecte pour ce client sur cette période' : 'Aucune collecte sur cette période'} cols={[
                      { titre: 'Date', render: (l) => fdate(l.date_collecte) },
                      { titre: 'Client', render: (l) => <><strong>{l.client}</strong><div className="muted">{l.client_numero} · {l.cycle}</div></> },
                      { titre: 'Zone', render: (l) => l.zone ?? '—' },
                      { titre: 'Produit', render: (l) => l.produit },
                      { titre: 'Agent', render: (l) => l.agent ?? '—' },
                      { titre: 'Case', render: (l) => `${l.page}-${l.no_ligne}` },
                      { titre: 'Montant', num: true, render: (l) => xof(l.montant_collecte) },
                      { titre: 'Mise', num: true, render: (l) => xof(l.mise_appliquee) },
                    ]} />
                    {rows.length > 0 && <p className="muted" style={{ padding: '8px 16px' }}>Total : {rows.length} collecte(s) · {xof(total)}</p>}
                  </>
                )
              }}
            </Charge>
          )}
        </Card>
      )}
    </Page>
  )
}
