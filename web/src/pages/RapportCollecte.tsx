import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, xof } from '../lib/format'
import { useProduitsEpargne } from '../lib/hooks'
import { Alert, Card, Charge, Field, Input, Page, Select, Table, useFetch } from '../components/ui'

interface Ligne { cle: string; libelle: string; nb_lignes: number; montant_collecte: number; mises: number; collectrices: string | null }
type Groupe = 'produit' | 'agent' | 'zone'

const premierJour = () => aujourdhui().slice(0, 8) + '01'
const TITRES: Record<Groupe, string> = { produit: 'Produit', agent: 'Agent', zone: 'Zone' }

// Rapport des collectes d'une période. Une zone regroupe les collectes de tous ses clients, même si elle a changé de collectrice :
// la colonne « Collectrices » donne chaque affectation de la période avec ses dates.
export default function RapportCollecte() {
  const produits = useProduitsEpargne('collecte')
  const [du, setDu] = useState(premierJour)
  const [au, setAu] = useState(aujourdhui)
  const [groupe, setGroupe] = useState<Groupe>('produit')
  const [produit, setProduit] = useState('')
  const invalide = au < du
  const q = useFetch(() => (invalide ? Promise.resolve([] as Ligne[]) : api.get<Ligne[]>('/api/rapports/collecte-periode',
    { du, au, groupe, produit_id: produit ? Number(produit) : undefined })), [du, au, groupe, produit])
  return (
    <Page title="Rapport de collecte" subtitle="Collectes d'une période, par produit, par agent ou par zone">
      <Card>
        <div className="grid-form">
          <Field label="Du"><Input type="date" value={du} onChange={(e) => setDu(e.target.value)} /></Field>
          <Field label="Au"><Input type="date" value={au} onChange={(e) => setAu(e.target.value)} /></Field>
          <Field label="Regrouper par">
            <Select value={groupe} onChange={(e) => setGroupe(e.target.value as Groupe)}>
              <option value="produit">Produit</option>
              <option value="agent">Agent</option>
              <option value="zone">Zone</option>
            </Select>
          </Field>
          <Field label="Produit">
            <Select value={produit} onChange={(e) => setProduit(e.target.value)}>
              <option value="">Tous les produits</option>
              {produits.map((p) => <option key={p.id} value={p.id}>{p.code} — {p.libelle}</option>)}
            </Select>
          </Field>
        </div>
        {invalide && <Alert tone="warn">La date de fin précède la date de début.</Alert>}
      </Card>
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
    </Page>
  )
}
