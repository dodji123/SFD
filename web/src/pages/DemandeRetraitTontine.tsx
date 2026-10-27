import { useState } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { api } from '../lib/api'
import { aujourdhui, xof } from '../lib/format'
import { useProduitsEpargne } from '../lib/hooks'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, Input, Page, Select, Table, useAction, useFetch } from '../components/ui'
import type { CycleLigne } from './Cycles'

interface CompteEpargne { id: number; numero: string; produit: string; disponible: number }
interface RetraitL {
  id: number; cycle: string; client: string; zone: string | null; caissiere: string | null; nature: string
  montant: number; montant_paye: number | null; statut: string; date_demande: string; date_operation: string | null
}
interface SessionC { id: number; caisse: string; statut: string }

const NATURE: Record<string, string> = {
  retrait_client: 'Espèces', virement_vers_epargne: 'Virement épargne', remboursement: 'Remboursement', regularisation: 'Régularisation',
}
const STATUT: Record<string, { texte: string; tone: 'ok' | 'warn' | 'bad' | 'neutre' }> = {
  demande: { texte: 'Demandé', tone: 'warn' }, ecart_en_traitement: { texte: 'Écart à traiter', tone: 'bad' },
  fonds_disponibles: { texte: 'À payer', tone: 'ok' }, execute: { texte: 'Payé', tone: 'neutre' }, annule: { texte: 'Annulé', tone: 'neutre' },
}

const jour = (d: string | null | undefined) => (d ?? '').slice(0, 10)
const montantRetrait = (r: RetraitL) => r.montant_paye ?? r.montant

/** Regroupe les retraits par une clé (zone ou type) : nombre et total. */
function regrouper(rows: RetraitL[], cle: (r: RetraitL) => string) {
  const m = new Map<string, { nb: number; total: number }>()
  for (const r of rows) {
    const k = cle(r)
    const e = m.get(k) ?? { nb: 0, total: 0 }
    e.nb += 1
    e.total += montantRetrait(r)
    m.set(k, e)
  }
  return [...m.entries()].map(([k, v]) => ({ k, ...v })).sort((a, b) => a.k.localeCompare(b.k))
}

/**
 * Guichet des retraits de tontine. Le constat des écarts est fait par les responsables ;
 * la caissière paie les retraits « à payer », demande un retrait et suit les paiements du jour.
 */
export default function DemandeRetraitTontine() {
  const { agenceId } = useSession()
  const { run, busy } = useAction()
  const retraits = useFetch(() => api.get<RetraitL[]>('/api/retraits', { limit: 500 }), [agenceId])
  const sessions = useFetch(() => api.get<SessionC[]>('/api/sessions'), [agenceId])
  const sessionOuverte = (sessions.data ?? []).find((s) => s.statut === 'ouverte') ?? null
  const tous = retraits.data ?? []
  const duJour = tous.filter((r) => jour(r.date_operation) === aujourdhui() || jour(r.date_demande) === aujourdhui())
  const payesDuJour = tous.filter((r) => r.statut === 'execute' && jour(r.date_operation) === aujourdhui())
  const totalJour = payesDuJour.reduce((s, r) => s + montantRetrait(r), 0)

  // ----- demande de retrait : produit, numéro ou nom, cycles à solde, cases à cocher
  const produits = useProduitsEpargne('collecte')
  // produit et recherche dans l'adresse : ils sont retrouvés au retour depuis la fiche d'un cycle
  const nav = useNavigate()
  const [params, setParams] = useSearchParams()
  const produit = params.get('produit') ?? ''
  const recherche = params.get('q') ?? ''
  const majFiltre = (p: string, q: string) => setParams({ produit: p, q }, { replace: true })
  const [coches, setCoches] = useState<Set<number>>(new Set())
  const [destination, setDestination] = useState('retrait_client')
  const [date, setDate] = useState(aujourdhui())
  const [compte, setCompte] = useState('')
  const [fait, setFait] = useState<string | null>(null)
  const [montants, setMontants] = useState<Record<number, string>>({})
  const [clotures, setClotures] = useState<Record<number, boolean>>({})
  const soldeDe = (c: CycleLigne) => c.solde_disponible ?? c.net
  const montantDe = (c: CycleLigne) => Number(montants[c.id] ?? soldeDe(c))
  const partielDe = (c: CycleLigne) => montantDe(c) < soldeDe(c)
  const valideDe = (c: CycleLigne) => montantDe(c) > 0 && montantDe(c) <= soldeDe(c) && (destination === 'retrait_client' || !partielDe(c))
  const effetDe = (c: CycleLigne) => {
    const m = montantDe(c)
    if (!valideDe(c)) return destination === 'virement_vers_epargne' && partielDe(c) ? 'Partiel non disponible pour un virement' : 'Montant invalide'
    if (!partielDe(c)) return c.statut === 'en_cours' ? 'Retrait total : cycle clôturé puis retiré' : 'Retrait normal : cycle retiré'
    if (c.statut === 'en_cours') return clotures[c.id] ? 'Retrait partiel : cycle clôturé' : "Retrait partiel d'urgence : cycle non clôturé"
    return `Retrait partiel : cycle reste clôturé, solde restant ${xof(soldeDe(c) - m)}`
  }

  const actif = produit !== '' && recherche.trim().length >= 2
  const cycles = useFetch(
    () => (actif ? api.get<CycleLigne[]>('/api/cycles', { q: recherche.trim(), produit_id: produit, limit: 100 }) : Promise.resolve([] as CycleLigne[])),
    [produit, recherche, agenceId],
  )
  const avecSolde = (cycles.data ?? []).filter((c) => soldeDe(c) > 0 && c.statut !== 'retire')
  const choisis = avecSolde.filter((c) => coches.has(c.id))
  const total = choisis.reduce((s, c) => s + montantDe(c), 0)
  const toutValide = choisis.length > 0 && choisis.every(valideDe)
  const client = choisis[0]?.client_id
  const memeClient = choisis.every((c) => c.client_id === client)

  const comptes = useFetch(
    () => (client && destination === 'virement_vers_epargne' ? api.get<CompteEpargne[]>('/api/comptes-epargne', { client_id: client }) : Promise.resolve([] as CompteEpargne[])),
    [client, destination],
  )

  const basculer = (id: number) => setCoches((s) => { const n = new Set(s); if (n.has(id)) n.delete(id); else n.add(id); return n })
  const toutCocher = () => setCoches(coches.size === avecSolde.length ? new Set() : new Set(avecSolde.map((c) => c.id)))
  const reinitialiser = () => { setCoches(new Set()); setDestination('retrait_client'); setCompte(''); setDate(aujourdhui()) }

  const demander = () => {
    const liste = choisis
    void run(async () => {
      const echecs: string[] = []
      for (const c of liste) {
        try {
          const partiel = partielDe(c)
          await api.post(`/api/cycles/${c.id}/retrait-direct`, {
            nature: destination, compte_id: compte ? Number(compte) : null, date,
            montant: partiel ? montantDe(c) : null,
            cloturer: partiel && c.statut === 'en_cours' ? !!clotures[c.id] : null,
            session_id: destination === 'retrait_client' ? sessionOuverte?.id ?? null : null,
          })
        } catch (e) {
          echecs.push(`${c.numero} : ${e instanceof Error ? e.message : 'erreur'}`)
        }
      }
      if (echecs.length) throw new Error(echecs.join(' · '))
    }, `${liste.length} demande(s) de retrait créée(s)`, () => {
      setFait(`${liste.length} retrait(s) effectué(s) pour ${xof(total)}.`)
      reinitialiser()
      cycles.reload()
      retraits.reload()
    })
  }

  const parZone = regrouper(payesDuJour, (r) => r.zone ?? 'Sans zone')
  const parType = regrouper(payesDuJour, (r) => NATURE[r.nature] ?? r.nature)

  return (
    <Page title="Retrait tontine" subtitle="Payer les retraits dont le constat est fait, demander un retrait, suivre la journée">
      {!sessionOuverte && <Alert tone="warn">Aucune session de caisse ouverte : ouvrez-la pour payer en espèces.</Alert>}

      <Card>
        <div className="form-grid">
          <Field label="Produit">
            <Select value={produit} onChange={(e) => { majFiltre(e.target.value, recherche); reinitialiser() }}>
              <option value="">— choisir un produit —</option>
              {produits.map((p) => <option key={p.id} value={p.id}>{p.code} — {p.libelle}</option>)}
            </Select>
          </Field>
          <Field label="Numéro ou nom du client" hint="Au moins 2 caractères">
            <Input value={recherche} onChange={(e) => { majFiltre(produit, e.target.value); reinitialiser() }} placeholder="Numéro de cycle, numéro ou nom du client" disabled={produit === ''} />
          </Field>
        </div>
      </Card>

      {actif && (
        <Card title={`Cycles avec un solde (${avecSolde.length})`} flush actions={avecSolde.length > 0 && <Button small onClick={toutCocher}>{coches.size === avecSolde.length ? 'Tout décocher' : 'Tout cocher'}</Button>}>
          <Charge q={cycles}>
            {() => (
              <Table rows={avecSolde} vide="Aucun cycle avec un solde pour cette recherche" onRowClick={(c) => nav(`/cycles/${c.id}`)} cols={[
                { titre: '', render: (c) => <input type="checkbox" aria-label={`Choisir ${c.numero}`} checked={coches.has(c.id)} onClick={(e) => e.stopPropagation()} onChange={() => basculer(c.id)} /> },
                { titre: 'Cycle', render: (c) => <strong>{c.numero}</strong> },
                { titre: 'Client', render: (c) => c.client },
                { titre: 'Statut', render: (c) => <Badge tone="neutre">{c.statut}</Badge> },
                { titre: 'Solde disponible', num: true, render: (c) => <strong>{xof(soldeDe(c))}</strong> },
              ]} />
            )}
          </Charge>
        </Card>
      )}

      {choisis.length > 0 && (
        <Card title={`Demande : ${choisis.length} cycle(s) · ${xof(total)}`}>
          <Table rows={choisis} cols={[
            { titre: 'Cycle', render: (c) => <strong>{c.numero}</strong> },
            { titre: 'Client', render: (c) => c.client },
            { titre: 'Statut', render: (c) => <Badge tone="neutre">{c.statut}</Badge> },
            { titre: 'Solde disponible', num: true, render: (c) => xof(soldeDe(c)) },
            { titre: 'Montant à retirer', num: true, render: (c) => (
              <Input type="number" min={1} max={soldeDe(c)} aria-label={`Montant ${c.numero}`} style={{ width: 130 }}
                value={montants[c.id] ?? String(soldeDe(c))}
                onChange={(e) => setMontants({ ...montants, [c.id]: e.target.value })} />
            ) },
            { titre: 'Clôturer le cycle', render: (c) => (c.statut === 'en_cours' && partielDe(c)
              ? <input type="checkbox" aria-label={`Clôturer ${c.numero}`} checked={!!clotures[c.id]} onChange={(e) => setClotures({ ...clotures, [c.id]: e.target.checked })} />
              : <span className="muted">—</span>) },
            { titre: 'Effet', render: (c) => <Badge tone={valideDe(c) ? 'ok' : 'bad'}>{effetDe(c)}</Badge> },
          ]} />
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
            <Button variant="primary" disabled={busy || !toutValide || (destination === 'virement_vers_epargne' && (!compte || !memeClient))} onClick={demander}>
              {busy ? 'En cours…' : `Retirer : ${choisis.length} cycle(s) · ${xof(total)}`}
            </Button>
            <Button onClick={reinitialiser}>Annuler</Button>
          </div>
        </Card>
      )}
      {fait && <Alert tone="info">{fait}</Alert>}

      <Card title={`Retraits du jour (${duJour.length})`} flush>
        <Table rows={duJour} vide="Aucun retrait aujourd'hui" cols={[
          { titre: 'Cycle', render: (r) => r.cycle },
          { titre: 'Client', render: (r) => r.client },
          { titre: 'Zone', render: (r) => r.zone ?? '—' },
          { titre: 'Destination', render: (r) => NATURE[r.nature] ?? r.nature },
          { titre: 'Montant', num: true, render: (r) => xof(montantRetrait(r)) },
          { titre: 'Statut', render: (r) => <Badge tone={STATUT[r.statut]?.tone ?? 'neutre'}>{STATUT[r.statut]?.texte ?? r.statut}</Badge> },
          { titre: 'Caissière', render: (r) => r.caissiere ?? '—' },
        ]} />
      </Card>

      <Card title={`Récapitulatif du jour : ${payesDuJour.length} paiement(s) · ${xof(totalJour)}`}>
        <div className="form-grid">
          <Table rows={parZone} vide="Aucun paiement aujourd'hui" cols={[
            { titre: 'Zone', render: (z) => z.k },
            { titre: 'Paiements', num: true, render: (z) => z.nb },
            { titre: 'Total', num: true, render: (z) => <strong>{xof(z.total)}</strong> },
          ]} />
          <Table rows={parType} vide="Aucun paiement aujourd'hui" cols={[
            { titre: 'Type de retrait', render: (t) => t.k },
            { titre: 'Paiements', num: true, render: (t) => t.nb },
            { titre: 'Total', num: true, render: (t) => <strong>{xof(t.total)}</strong> },
          ]} />
        </div>
      </Card>
    </Page>
  )
}
