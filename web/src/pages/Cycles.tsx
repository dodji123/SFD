import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useProduitsEpargne } from '../lib/hooks'
import { useSession } from '../lib/session'
import { Alert, Button, Card, Charge, Field, FormModal, Input, Page, Select, Statut, Table, useAction, useFetch } from '../components/ui'

export interface CycleLigne {
  id: number; numero: string; client_id: number; client: string; type_cycle: number; statut: string; produit: string
  mise_courante: number; mise_finale: number | null; date_debut: string; date_fin: string
  nb_lignes: number; nb_lignes_prevues: number; montant_collecte: number; montant_previsionnel: number | null; net: number
}

export default function Cycles() {
  const nav = useNavigate()
  const { agenceId, can } = useSession()
  const produits = useProduitsEpargne('collecte')
  const { run, busy } = useAction()
  const [statut, setStatut] = useState('en_cours')
  const [produit, setProduit] = useState('')
  const [tri, setTri] = useState('produit')
  const [q, setQ] = useState('')
  const [qd, setQd] = useState('')
  const [choix, setChoix] = useState<Set<number>>(new Set())
  const [cloture, setCloture] = useState(false)
  const [jour, setJour] = useState(aujourdhui())
  useEffect(() => { const t = setTimeout(() => setQd(q), 250); return () => clearTimeout(t) }, [q])
  const liste = useFetch(() => api.get<CycleLigne[]>('/api/cycles', { statut, q: qd, produit_id: produit, tri, limit: 300 }), [statut, qd, produit, tri, agenceId])
  const peutClore = can('collecte:admin') && statut === 'en_cours'
  const bascule = (id: number) => setChoix((s) => { const n = new Set(s); if (n.has(id)) n.delete(id); else n.add(id); return n })
  const echus = () => {
    if (!window.confirm('Clôturer tous les cycles dont la date de fin est dépassée ?')) return
    void run(async () => {
      const r = await api.post<{ cycles_clotures: number }>('/api/collecte/cloturer-echus', {})
      window.alert(`${r.cycles_clotures} cycle(s) clôturé(s)`)
    }, undefined, liste.reload)
  }
  return (
    <Page title="Cycles de tontine" subtitle="Les cycles d'épargne journalière avec leur livret de 31 lignes par page">
      <Card flush actions={peutClore && (
        <span className="row" style={{ gap: 8 }}>
          <Button disabled={choix.size === 0} variant="danger" onClick={() => setCloture(true)}>Clôturer la sélection ({choix.size})</Button>
          <Button disabled={busy} onClick={echus}>Clôturer les cycles échus</Button>
        </span>
      )}>
        <div className="card-b row">
          <Field label="Recherche"><Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Numéro de cycle ou nom du client" /></Field>
          <Field label="Produit">
            <Select value={produit} onChange={(e) => setProduit(e.target.value)}>
              <option value="">Tous les produits</option>
              {produits.map((p) => <option key={p.id} value={p.id}>{p.code} — {p.libelle}</option>)}
            </Select>
          </Field>
          <Field label="Trier par">
            <Select value={tri} onChange={(e) => setTri(e.target.value)}>
              <option value="produit">Produit</option>
              <option value="client">Client</option>
              <option value="fin">Date de fin</option>
              <option value="recent">Plus récents</option>
            </Select>
          </Field>
          <Field label="Statut">
            <Select value={statut} onChange={(e) => { setStatut(e.target.value); setChoix(new Set()) }}>
              <option value="">Tous</option>
              <option value="en_cours">En cours</option>
              <option value="clos">Clos (retrait à faire)</option>
              <option value="retire">Retirés</option>
            </Select>
          </Field>
        </div>
        <Charge q={liste}>
          {(rows) => (
            <Table rows={rows} onRowClick={(c) => nav(`/cycles/${c.id}`)} vide="Aucun cycle" cols={[
              ...(peutClore ? [{ titre: '', render: (c: CycleLigne) => <input type="checkbox" aria-label={`Sélectionner ${c.numero}`} checked={choix.has(c.id)} onClick={(e) => e.stopPropagation()} onChange={() => bascule(c.id)} /> }] : []),
              { titre: 'Cycle', render: (c) => <strong>{c.numero}</strong> },
              { titre: 'Produit', render: (c) => c.produit },
              { titre: 'Client', render: (c) => c.client },
              { titre: 'Type', render: (c) => `Type ${c.type_cycle}` },
              { titre: 'Mise', num: true, render: (c) => xof(c.mise_finale ?? c.mise_courante) },
              { titre: 'Livret', num: true, render: (c) => `${c.nb_lignes} / ${c.nb_lignes_prevues}` },
              { titre: 'Collecté', num: true, render: (c) => xof(c.montant_collecte) },
              { titre: 'Fin', render: (c) => fdate(c.date_fin) },
              { titre: 'Statut', render: (c) => <Statut s={c.statut} /> },
            ]} />
          )}
        </Charge>
      </Card>
      {cloture && (
        <FormModal titre={`Clôturer ${choix.size} mise(s)`} onClose={() => setCloture(false)} busy={busy} valider="Clôturer"
          onSubmit={() => void run(async () => {
            const r = await api.post<{ clotures: number[]; refuses: { cycle_id: number; motif: string }[] }>('/api/cycles/cloturer-selection', { cycle_ids: [...choix], date: jour })
            if (r.refuses.length) window.alert(`${r.clotures.length} clôturé(s). Refusés : ${r.refuses.map((x) => `n°${x.cycle_id} (${x.motif})`).join(' ; ')}`)
          }, 'Clôture effectuée', () => { setCloture(false); setChoix(new Set()); liste.reload() })}>
          <Alert tone="warn">La clôture fixe la mise finale et rend le cycle disponible pour le retrait. Elle ne peut pas être annulée.</Alert>
          <Field label="Date de clôture"><Input type="date" max={aujourdhui()} value={jour} onChange={(e) => setJour(e.target.value || aujourdhui())} required /></Field>
        </FormModal>
      )}
    </Page>
  )
}
