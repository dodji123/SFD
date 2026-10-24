import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, xof } from '../lib/format'
import { useProduitsEpargne } from '../lib/hooks'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, Input, Page, Select, Table, useAction, useFetch } from '../components/ui'
import type { CycleLigne } from './Cycles'

interface CompteEpargne { id: number; numero: string; produit: string; disponible: number }

/**
 * Retrait de tontine au guichet. Le carnet a déjà été contrôlé (Contrôle des livrets) avant la caisse.
 * Le caissier choisit le produit, saisit le numéro ou le nom, voit les cycles avec un solde supérieur à 0,
 * coche un ou plusieurs cycles et crée les demandes de retrait.
 */
export default function DemandeRetraitTontine() {
  const { agenceId } = useSession()
  const produits = useProduitsEpargne('collecte')
  const { run, busy } = useAction()
  const [produit, setProduit] = useState('')
  const [recherche, setRecherche] = useState('')
  const [coches, setCoches] = useState<Set<number>>(new Set())
  const [destination, setDestination] = useState('retrait_client')
  const [date, setDate] = useState(aujourdhui())
  const [compte, setCompte] = useState('')
  const [fait, setFait] = useState<string | null>(null)

  const actif = produit !== '' && recherche.trim().length >= 2
  const cycles = useFetch(
    () => (actif ? api.get<CycleLigne[]>('/api/cycles', { q: recherche.trim(), produit_id: produit, limit: 100 }) : Promise.resolve([] as CycleLigne[])),
    [produit, recherche, agenceId],
  )
  const avecSolde = (cycles.data ?? []).filter((c) => c.net > 0 && c.statut !== 'retire')
  const choisis = avecSolde.filter((c) => coches.has(c.id))
  const total = choisis.reduce((s, c) => s + c.net, 0)
  const client = choisis[0]?.client_id
  const memeClient = choisis.every((c) => c.client_id === client)

  const comptes = useFetch(
    () => (client && destination === 'virement_vers_epargne' ? api.get<CompteEpargne[]>('/api/comptes-epargne', { client_id: client }) : Promise.resolve([] as CompteEpargne[])),
    [client, destination],
  )

  const basculer = (id: number) => setCoches((s) => { const n = new Set(s); if (n.has(id)) n.delete(id); else n.add(id); return n })
  const toutCocher = () => setCoches(coches.size === avecSolde.length ? new Set() : new Set(avecSolde.map((c) => c.id)))

  const reinitialiser = () => { setCoches(new Set()); setDestination('retrait_client'); setCompte(''); setDate(aujourdhui()) }

  const envoyer = () => {
    const liste = choisis
    void run(async () => {
      const echecs: string[] = []
      for (const c of liste) {
        try {
          await api.post(`/api/cycles/${c.id}/retrait`, { nature: destination, compte_id: compte ? Number(compte) : null, date })
        } catch (e) {
          echecs.push(`${c.numero} : ${e instanceof Error ? e.message : 'erreur'}`)
        }
      }
      if (echecs.length) throw new Error(echecs.join(' · '))
    }, `${liste.length} demande(s) de retrait créée(s)`, () => {
      setFait(`${liste.length} cycle(s) pour ${xof(total)} : demande créée. Le traitement se fait dans « Retraits et écarts ».`)
      reinitialiser()
      cycles.reload()
    })
  }

  return (
    <Page title="Retrait de tontine au guichet" subtitle="Produit, puis numéro ou nom du client : cochez les cycles à retirer">
      <Card>
        <div className="form-grid">
          <Field label="Produit">
            <Select value={produit} onChange={(e) => { setProduit(e.target.value); reinitialiser() }}>
              <option value="">— choisir un produit —</option>
              {produits.map((p) => <option key={p.id} value={p.id}>{p.code} — {p.libelle}</option>)}
            </Select>
          </Field>
          <Field label="Numéro ou nom du client" hint="Au moins 2 caractères">
            <Input value={recherche} onChange={(e) => { setRecherche(e.target.value); reinitialiser() }} placeholder="Numéro de cycle, numéro ou nom du client" disabled={produit === ''} />
          </Field>
        </div>
      </Card>

      {actif && (
        <Card title={`Cycles avec un solde (${avecSolde.length})`} flush actions={avecSolde.length > 0 && <Button small onClick={toutCocher}>{coches.size === avecSolde.length ? 'Tout décocher' : 'Tout cocher'}</Button>}>
          <Charge q={cycles}>
            {() => (
              <Table rows={avecSolde} vide="Aucun cycle avec un solde pour cette recherche" onRowClick={(c) => window.open(`/cycles/${c.id}`, '_blank')} cols={[
                { titre: '', render: (c) => <input type="checkbox" aria-label={`Choisir ${c.numero}`} checked={coches.has(c.id)} onClick={(e) => e.stopPropagation()} onChange={() => basculer(c.id)} /> },
                { titre: 'Cycle', render: (c) => <strong>{c.numero}</strong> },
                { titre: 'Client', render: (c) => c.client },
                { titre: 'Statut', render: (c) => <Badge tone="neutre">{c.statut}</Badge> },
                { titre: 'Solde à retirer', num: true, render: (c) => <strong>{xof(c.net)}</strong> },
              ]} />
            )}
          </Charge>
        </Card>
      )}

      {choisis.length > 0 && (
        <Card title={`À retirer : ${choisis.length} cycle(s) · ${xof(total)}`}>
          <div className="form-grid">
            <Field label="Destination">
              <Select value={destination} onChange={(e) => { setDestination(e.target.value); setCompte('') }}>
                <option value="retrait_client">Payer le client en espèces</option>
                <option value="virement_vers_epargne">Virer vers son compte d'épargne</option>
              </Select>
            </Field>
            {destination === 'virement_vers_epargne' && (
              <Field label="Compte d'épargne">
                <Select value={compte} onChange={(e) => setCompte(e.target.value)} required>
                  <option value="">— choisir un compte —</option>
                  {comptes.data?.map((a) => <option key={a.id} value={a.id}>{a.numero} · {a.produit}</option>)}
                </Select>
              </Field>
            )}
            <Field label="Date">
              <Input type="date" value={date} onChange={(e) => setDate(e.target.value)} required />
            </Field>
          </div>
          <div className="row" style={{ marginTop: 12 }}>
            <Button variant="primary" disabled={busy || (destination === 'virement_vers_epargne' && (!compte || !memeClient))} onClick={envoyer}>
              {busy ? 'En cours…' : `Demander le retrait de ${choisis.length} cycle(s)`}
            </Button>
            <Button onClick={reinitialiser}>Annuler</Button>
          </div>
        </Card>
      )}

      {fait && <Alert tone="info">{fait}</Alert>}
    </Page>
  )
}
