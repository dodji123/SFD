import { useState } from 'react'
import { api } from '../lib/api'
import { date as fdate, xof } from '../lib/format'
import { useProduitsEpargne } from '../lib/hooks'
import { Card, Charge, Field, Input, Page, Select, Table, useFetch } from '../components/ui'

interface Ligne { produit_code: string; produit_libelle: string; client_numero: string; client: string; zone: string | null; cycle: string; statut: string; date_fin: string | null; solde: number }

// Soldes que les clients peuvent encore retirer, cycle par cycle, regroupés par produit avec leur total.
export default function RapportSoldeARetirer() {
  const produits = useProduitsEpargne('collecte')
  const [produit, setProduit] = useState('')
  const [recherche, setRecherche] = useState('')
  const q = useFetch(() => api.get<Ligne[]>('/api/rapports/solde-a-retirer', { produit_id: produit ? Number(produit) : undefined }), [produit])
  return (
    <Page title="Solde à retirer" subtitle="Ce que les clients peuvent encore retirer, par produit">
      <Card>
        <div className="grid-form">
          <Field label="Produit">
            <Select value={produit} onChange={(e) => setProduit(e.target.value)}>
              <option value="">Tous les produits</option>
              {produits.map((p) => <option key={p.id} value={p.id}>{p.code} — {p.libelle}</option>)}
            </Select>
          </Field>
          <Field label="Client" hint="Nom ou numéro, une partie suffit">
            <Input value={recherche} placeholder="ex. Mensah ou C001" autoComplete="off" onChange={(e) => setRecherche(e.target.value)} />
          </Field>
        </div>
      </Card>
      <Charge q={q}>
        {(rows) => {
          const terme = recherche.trim().toLowerCase()
          const visibles = rows.filter((l) => !terme || `${l.client} ${l.client_numero}`.toLowerCase().includes(terme))
          const groupes = new Map<string, Ligne[]>()
          for (const l of visibles) groupes.set(l.produit_code, [...(groupes.get(l.produit_code) ?? []), l])
          if (groupes.size === 0) return <Card><p className="muted">Aucun solde à retirer</p></Card>
          const total = visibles.reduce((s, l) => s + Number(l.solde), 0)
          return (
            <>
              {[...groupes.entries()].map(([code, lignes]) => (
                <Card key={code} title={`${code} — ${lignes[0].produit_libelle}`} flush
                  actions={<span className="muted">{lignes.length} cycle(s) · {xof(lignes.reduce((s, l) => s + Number(l.solde), 0))}</span>}>
                  <Table rows={lignes} cols={[
                    { titre: 'Client', render: (l) => <><strong>{l.client}</strong><div className="muted">{l.client_numero}</div></> },
                    { titre: 'Zone', render: (l) => l.zone ?? '—' },
                    { titre: 'Cycle', render: (l) => <>{l.cycle}<div className="muted">{l.statut}</div></> },
                    { titre: 'Fin prévue', render: (l) => (l.date_fin ? fdate(l.date_fin) : '—') },
                    { titre: 'Solde à retirer', num: true, render: (l) => <strong>{xof(l.solde)}</strong> },
                  ]} />
                </Card>
              ))}
              <p className="muted" style={{ padding: '8px 16px' }}>Total à retirer : {xof(total)}</p>
            </>
          )
        }}
      </Charge>
    </Page>
  )
}
