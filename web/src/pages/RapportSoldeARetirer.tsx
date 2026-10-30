import { useState } from 'react'
import { api } from '../lib/api'
import { date as fdate, xof } from '../lib/format'
import { useProduitsEpargne } from '../lib/hooks'
import { Card, Charge, Field, Input, Page, Select, Table, useFetch } from '../components/ui'

export interface Ligne { produit_code: string; produit_libelle: string; client_numero: string; client: string; zone: string | null; cycle: string; statut: string; date_fin: string | null; solde: number }

interface Props { titre: string; subtitre: string; alaDate: boolean }

// Soldes que les clients peuvent encore retirer : totaux par client et par produit, détail produit > client > cycle.
// alaDate : même rapport à une date donnée (sans date, aujourd'hui).
export function SoldeARetirer({ titre, subtitre, alaDate }: Props) {
  const produits = useProduitsEpargne('collecte')
  const [produit, setProduit] = useState('')
  const [recherche, setRecherche] = useState('')
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10))
  const p = { produit_id: produit ? Number(produit) : undefined }
  const q = useFetch(
    () => (alaDate ? api.get<Ligne[]>('/api/rapports/solde-a-retirer-date', { date, ...p }) : api.get<Ligne[]>('/api/rapports/solde-a-retirer', p)),
    [produit, date, alaDate],
  )
  return (
    <Page title={titre} subtitle={subtitre}>
      <Card>
        <div className="grid-form">
          {alaDate && (
            <Field label="À la date du">
              <Input type="date" value={date} onChange={(e) => setDate(e.target.value || new Date().toISOString().slice(0, 10))} />
            </Field>
          )}
          <Field label="Produit">
            <Select value={produit} onChange={(e) => setProduit(e.target.value)}>
              <option value="">Tous les produits</option>
              {produits.map((x) => <option key={x.id} value={x.id}>{x.code} — {x.libelle}</option>)}
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
          if (visibles.length === 0) return <Card><p className="muted">Aucun solde à retirer</p></Card>
          const total = visibles.reduce((s, l) => s + Number(l.solde), 0)

          // totaux par client (tous produits confondus)
          const parClient = new Map<string, { numero: string; nom: string; total: number; cycles: number; produits: Set<string> }>()
          for (const l of visibles) {
            const k = `${l.client_numero}|${l.client}`
            const e = parClient.get(k) ?? { numero: l.client_numero, nom: l.client, total: 0, cycles: 0, produits: new Set<string>() }
            e.total += Number(l.solde); e.cycles += 1; e.produits.add(l.produit_code)
            parClient.set(k, e)
          }

          // totaux par produit
          const parProduit = new Map<string, { code: string; libelle: string; total: number; clients: Set<string> }>()
          for (const l of visibles) {
            const e = parProduit.get(l.produit_code) ?? { code: l.produit_code, libelle: l.produit_libelle, total: 0, clients: new Set<string>() }
            e.total += Number(l.solde); e.clients.add(l.client_numero)
            parProduit.set(l.produit_code, e)
          }

          // détail : produit > client > cycle, avec sous-totaux
          type Detail = { kind: 'produit' | 'client' | 'cycle'; libelle: string; detail: string; solde: number }
          const detail: Detail[] = []
          for (const [code, pr] of [...parProduit.entries()].sort()) {
            detail.push({ kind: 'produit', libelle: `${code} — ${pr.libelle}`, detail: `${pr.clients.size} client(s)`, solde: pr.total })
            const parCli = new Map<string, Ligne[]>()
            for (const l of visibles.filter((x) => x.produit_code === code)) {
              const k = `${l.client_numero}|${l.client}`
              parCli.set(k, [...(parCli.get(k) ?? []), l])
            }
            for (const [, cycles] of [...parCli.entries()].sort()) {
              const c0 = cycles[0]
              detail.push({ kind: 'client', libelle: `${c0.client}`, detail: c0.client_numero, solde: cycles.reduce((s, l) => s + Number(l.solde), 0) })
              for (const l of cycles) {
                detail.push({ kind: 'cycle', libelle: l.cycle, detail: `${l.statut}${l.date_fin ? ' · fin ' + fdate(l.date_fin) : ''}`, solde: Number(l.solde) })
              }
            }
          }

          return (
            <>
              <p className="muted" style={{ padding: '8px 16px' }}>Total à retirer : <strong>{xof(total)}</strong></p>

              <Card title="Total par client" flush>
                <Table rows={[...parClient.values()].sort((a, b) => b.total - a.total)} cols={[
                  { titre: 'Client', render: (e) => <><strong>{e.nom}</strong><div className="muted">{e.numero}</div></> },
                  { titre: 'Produits', render: (e) => [...e.produits].join(', ') },
                  { titre: 'Cycles', num: true, render: (e) => e.cycles },
                  { titre: 'Total à retirer', num: true, render: (e) => <strong>{xof(e.total)}</strong> },
                ]} />
              </Card>
              <div style={{ height: 16 }} />

              <Card title="Total par produit" flush>
                <Table rows={[...parProduit.values()]} cols={[
                  { titre: 'Produit', render: (e) => <><strong>{e.code}</strong><div className="muted">{e.libelle}</div></> },
                  { titre: 'Clients', num: true, render: (e) => e.clients.size },
                  { titre: 'Total à retirer', num: true, render: (e) => <strong>{xof(e.total)}</strong> },
                ]} />
              </Card>
              <div style={{ height: 16 }} />

              <Card title="Détail par produit, client et cycle" flush>
                <Table rows={detail} cols={[
                  { titre: 'Produit / client / cycle', render: (d) => (d.kind === 'produit' ? <strong>{d.libelle}</strong> : d.kind === 'client' ? <span style={{ paddingLeft: 16 }}><strong>{d.libelle}</strong> <span className="muted">{d.detail}</span></span> : <span style={{ paddingLeft: 32 }}>{d.libelle} <span className="muted">{d.detail}</span></span>) },
                  { titre: 'Solde à retirer', num: true, render: (d) => (d.kind === 'cycle' ? xof(d.solde) : <strong>{xof(d.solde)}</strong>) },
                ]} />
              </Card>
            </>
          )
        }}
      </Charge>
    </Page>
  )
}

export default function RapportSoldeARetirerCourant() {
  return <SoldeARetirer titre="Solde à retirer" subtitre="Ce que les clients peuvent encore retirer, par produit, client et cycle" alaDate={false} />
}
