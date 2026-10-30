import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useAgents, useProduitsEpargne } from '../lib/hooks'
import { Button, Card, Charge, Field, Input, Page, Select, Table, useAction, useFetch } from '../components/ui'

type Vue = 'ecarts' | 'collectes' | 'situation' | 'ecarts_collecte'

interface EcartCollecte { id: number; date_collecte: string; matricule: string | null; agent: string | null; client_numero: string; client: string; cycle: string; manquant: number; surplus_utilise: number; impute_agent: number; surplus_meme_date: number; surplus_autres_dates: number; toutes_retirees: boolean; reglement_id: number | null; solde_reglable: number; statut: string }

interface Ecart { id: number; date_tournee: string; matricule: string; agent: string; montant_collecte: number; montant_verse: number; ecart: number; sens: string; montant: number; reste: number; paye: boolean }
interface Collecte { id: number; date_collecte: string; matricule: string | null; agent: string | null; client_numero: string; client: string; souscription: string; produit: string; montant_collecte: number; origine: string }
interface Situation { agent_id: number; matricule: string; agent: string; nb_versements: number; total_collecte: number; total_verse: number; manquants: number; surplus: number; ecart_net: number; nb_ecarts: number; solde_compte_agent: number }

const VUES: { id: Vue; titre: string }[] = [
  { id: 'ecarts', titre: 'Écarts de versement' },
  { id: 'collectes', titre: 'Collectes' },
  { id: 'situation', titre: 'Situation par agent' },
  { id: 'ecarts_collecte', titre: 'Écarts de collecte' },
]

const STATUTS: Record<string, string> = { a_regler: 'À régler par surplus', en_attente: 'En attente (aucun surplus)', regle: 'Réglé' }

// Suivi des collectes et des écarts de versement, sur une période : une vue par bouton.
export default function EcartsVersement() {
  const agents = useAgents()
  const produits = useProduitsEpargne('collecte')
  const [vue, setVue] = useState<Vue>('ecarts')
  const [du, setDu] = useState(aujourdhui().slice(0, 8) + '01')
  const [au, setAu] = useState(aujourdhui())
  const [agent, setAgent] = useState('')
  const [tri, setTri] = useState<'' | 'manquant' | 'surplus'>('')
  const [paiement, setPaiement] = useState<'' | 'paye' | 'non_paye'>('')
  const [produit, setProduit] = useState('')
  const agentId = agent ? Number(agent) : undefined

  const ecarts = useFetch(() => (vue === 'ecarts' ? api.get<Ecart[]>('/api/ecarts-versement', { du, au, agent_id: agentId }) : Promise.resolve([] as Ecart[])), [vue, du, au, agent])
  const collectes = useFetch(() => (vue === 'collectes' ? api.get<Collecte[]>('/api/collectes/liste', { du, au, agent_id: agentId, produit_id: produit ? Number(produit) : undefined }) : Promise.resolve([] as Collecte[])), [vue, du, au, agent, produit])
  const ecartsCollecte = useFetch(() => (vue === 'ecarts_collecte' ? api.get<EcartCollecte[]>('/api/ecarts-collecte') : Promise.resolve([] as EcartCollecte[])), [vue])
  const { run, busy } = useAction()
  const situation = useFetch(() => (vue === 'situation' ? api.get<Situation[]>('/api/ecarts-versement/situation-agents', { du, au }) : Promise.resolve([] as Situation[])), [vue, du, au])

  return (
    <Page title="Collectes et écarts" subtitle="Écarts de versement, collectes et situation des écarts par agent">
      <div className="row" style={{ gap: 8, flexWrap: 'wrap', marginBottom: 12 }}>
        {VUES.map((v) => (
          <Button key={v.id} variant={vue === v.id ? 'primary' : undefined} aria-pressed={vue === v.id} onClick={() => setVue(v.id)}>{v.titre}</Button>
        ))}
      </div>
      {vue !== 'ecarts_collecte' && (
      <Card>
        <div className="grid-form">
          <Field label="Du"><Input type="date" value={du} onChange={(e) => setDu(e.target.value)} /></Field>
          <Field label="Au"><Input type="date" value={au} onChange={(e) => setAu(e.target.value)} /></Field>
          {vue !== 'situation' && (
            <Field label="Agent">
              <Select value={agent} onChange={(e) => setAgent(e.target.value)}>
                <option value="">Tous les agents</option>
                {agents.map((a) => <option key={a.id} value={a.id}>{a.matricule} — {a.nom}</option>)}
              </Select>
            </Field>
          )}
          {vue === 'collectes' && (
            <Field label="Produit">
              <Select value={produit} onChange={(e) => setProduit(e.target.value)}>
                <option value="">Tous les produits</option>
                {produits.map((p) => <option key={p.id} value={p.id}>{p.code} — {p.libelle}</option>)}
              </Select>
            </Field>
          )}
        </div>
      </Card>
      )}

      {vue === 'ecarts' && (
        <Charge q={ecarts}>
          {(rows) => {
            const filtrees = rows.filter((r) => (tri === '' || r.sens === tri) && (paiement === '' || (paiement === 'paye') === r.paye))
            return (
            <>
              <div className="row no-print" style={{ gap: 8, alignItems: 'flex-end', marginBottom: 8 }}>
                <Field label="Afficher">
                  <Select value={tri} onChange={(e) => setTri(e.target.value as '' | 'manquant' | 'surplus')}>
                    <option value="">Tous les écarts</option>
                    <option value="manquant">Manquants seulement</option>
                    <option value="surplus">Surplus seulement</option>
                  </Select>
                </Field>
                <Field label="Paiement">
                  <Select value={paiement} onChange={(e) => setPaiement(e.target.value as '' | 'paye' | 'non_paye')}>
                    <option value="">Tous</option>
                    <option value="paye">Payé / soldé</option>
                    <option value="non_paye">Non payé / restant</option>
                  </Select>
                </Field>
                <Button onClick={() => window.print()}>Imprimer</Button>
              </div>
            <Card title={`Écarts de versement (${rows.length})`} flush actions={<span className="muted">Manquants {xof(rows.filter((r) => r.sens === 'manquant').reduce((s, r) => s + Number(r.montant), 0))} · Surplus {xof(rows.filter((r) => r.sens === 'surplus').reduce((s, r) => s + Number(r.montant), 0))}</span>}>
              <Table rows={filtrees} vide="Aucun écart de versement sur la période" cols={[
                { titre: 'Date tournée', render: (r) => fdate(r.date_tournee) },
                { titre: 'Agent', render: (r) => <><strong>{r.agent}</strong><div className="muted">{r.matricule}</div></> },
                { titre: 'Collecté', num: true, render: (r) => xof(r.montant_collecte) },
                { titre: 'Versé', num: true, render: (r) => xof(r.montant_verse) },
                { titre: 'Sens', render: (r) => (r.sens === 'manquant' ? 'Manquant' : 'Surplus') },
                { titre: 'Montant', num: true, render: (r) => <strong>{xof(r.montant)}</strong> },
                { titre: 'Observation', render: (r) => (r.sens === 'manquant'
                  ? (r.paye ? 'Manquant payé' : `Reste dû ${xof(r.reste)}`)
                  : `Surplus restant ${xof(r.reste)}`) },
              ]} />
            </Card>
            </>
            )
          }}
        </Charge>
      )}

      {vue === 'collectes' && (
        <Charge q={collectes}>
          {(rows) => (
            <Card title={`Collectes (${rows.length})`} flush actions={<span className="muted">Total {xof(rows.reduce((s, r) => s + Number(r.montant_collecte), 0))}</span>}>
              <Table rows={rows} vide="Aucune collecte sur la période" cols={[
                { titre: 'Date', render: (r) => fdate(r.date_collecte) },
                { titre: 'Agent', render: (r) => r.agent ?? '—' },
                { titre: 'Client', render: (r) => <><strong>{r.client}</strong><div className="muted">{r.client_numero}</div></> },
                { titre: 'Souscription', render: (r) => r.souscription },
                { titre: 'Produit', render: (r) => r.produit },
                { titre: 'Montant', num: true, render: (r) => <strong>{xof(r.montant_collecte)}</strong> },
              ]} />
            </Card>
          )}
        </Charge>
      )}

      {vue === 'situation' && (
        <Charge q={situation}>
          {(rows) => (
            <Card title="Situation des écarts par agent" flush>
              <Table rows={rows} vide="Aucun agent" cols={[
                { titre: 'Agent', render: (r) => <><strong>{r.agent}</strong><div className="muted">{r.matricule}</div></> },
                { titre: 'Versements', num: true, render: (r) => `${r.nb_versements} (${r.nb_ecarts} écart${r.nb_ecarts > 1 ? 's' : ''})` },
                { titre: 'Collecté', num: true, render: (r) => xof(r.total_collecte) },
                { titre: 'Versé', num: true, render: (r) => xof(r.total_verse) },
                { titre: 'Manquants', num: true, render: (r) => xof(r.manquants) },
                { titre: 'Surplus', num: true, render: (r) => xof(r.surplus) },
                { titre: 'Solde compte agent', num: true, render: (r) => <strong>{xof(r.solde_compte_agent)}</strong> },
              ]} />
            </Card>
          )}
        </Charge>
      )}
      {vue === 'ecarts_collecte' && (
        <Charge q={ecartsCollecte}>
          {(rows) => (
            <Card title={`Écarts de collecte des clients (${rows.length})`} flush>
              <Table rows={rows} vide="Aucun écart de collecte relevé au contrôle au carnet" cols={[
                { titre: 'Date collecte', render: (r) => fdate(r.date_collecte) },
                { titre: 'Agent', render: (r) => r.agent ?? '—' },
                { titre: 'Client', render: (r) => <><strong>{r.client}</strong><div className="muted">{r.client_numero} · {r.cycle}</div></> },
                { titre: 'Manquant', num: true, render: (r) => <strong>{xof(r.manquant)}</strong> },
                { titre: 'Surplus même date', num: true, render: (r) => xof(r.surplus_meme_date) },
                { titre: 'Surplus autres dates', num: true, render: (r) => (r.toutes_retirees ? xof(r.surplus_autres_dates) : 'Non utilisable (collectes non retirées)') },
                { titre: 'Réglable', num: true, render: (r) => xof(r.solde_reglable) },
                { titre: 'Statut', render: (r) => STATUTS[r.statut] ?? r.statut },
                { titre: '', render: (r) => (r.reglement_id === null ? (
                  <Button small disabled={busy} onClick={() => void run(() => api.post(`/api/ecarts-collecte/${r.id}/regler`), 'Manquant réglé : le reste éventuel est imputé à l’agent', () => ecartsCollecte.reload())}>Régler</Button>
                ) : null) },
              ]} />
            </Card>
          )}
        </Charge>
      )}
    </Page>
  )
}
