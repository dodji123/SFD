import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useProduitsEpargne } from '../lib/hooks'
import { Alert, Button, Card, Charge, Field, Input, Modal, Page, Select, Table, useAction, useFetch } from '../components/ui'

interface CycleCarnet { id: number; numero: string; client_id: number; client: string; client_numero: string; produit_id: number; produit: string; type_cycle: number; mise_courante: number; date_debut: string; date_fin: string; statut: string; dernier_controle: string | null }
interface LigneCollecte { id: number; date_collecte: string; page: number; no_ligne: number; montant_collecte: number; agent_id: number | null; agent: string | null; origine: string }
interface ControleHisto { id: number; date_controle: string; controleur: string; total_collecte: number; total_carnet: number; ecart_collecte: number; commentaire: string | null; annule: boolean; lignes: { ligne_collecte_id: number; montant_carnet: number; ecart: number; impute_agent: number | null }[] }

const premierJour = () => aujourdhui().slice(0, 8) + '01'

// Contrôle au carnet : on choisit le produit, puis le client, on voit les cycles de la période ; un double-clic ouvre le tableau de collecte à contrôler.
export default function ControleCarnet() {
  const produits = useProduitsEpargne('collecte')
  const [du, setDu] = useState(premierJour)
  const [au, setAu] = useState(aujourdhui)
  const [produit, setProduit] = useState('')
  const [recherche, setRecherche] = useState('')
  const [cycle, setCycle] = useState<CycleCarnet | null>(null)
  const q = useFetch(() => api.get<CycleCarnet[]>('/api/controle-carnet/cycles', { du, au, produit_id: produit ? Number(produit) : undefined, q: recherche.trim() || undefined }), [du, au, produit, recherche])
  return (
    <Page title="Contrôle au carnet" subtitle="Vérifier chaque collecte d'un cycle avec le carnet du client, puis enregistrer les écarts">
      <Card>
        <div className="grid-form">
          <Field label="Du"><Input type="date" value={du} onChange={(e) => setDu(e.target.value)} /></Field>
          <Field label="Au"><Input type="date" value={au} onChange={(e) => setAu(e.target.value)} /></Field>
          <Field label="Produit">
            <Select value={produit} onChange={(e) => setProduit(e.target.value)}>
              <option value="">Tous les produits</option>
              {produits.map((p) => <option key={p.id} value={p.id}>{p.code} — {p.libelle}</option>)}
            </Select>
          </Field>
          <Field label="Client" hint="Numéro ou nom du client">
            <Input value={recherche} placeholder="ex. CL-LOM-2026-000005 ou Mensah" autoComplete="off" onChange={(e) => setRecherche(e.target.value)} />
          </Field>
        </div>
      </Card>
      <Card title="Cycles de la période" flush>
        <Charge q={q}>
          {(rows) => {
            const filtre = rows
            return (
              <>
                <p className="muted" style={{ padding: '8px 16px', margin: 0 }}>Double-cliquez sur un cycle pour contrôler sa collecte au carnet.</p>
                <Table rows={filtre} onRowDoubleClick={(c) => setCycle(c)} vide="Aucun cycle sur cette période"
                  cols={[
                    { titre: 'Client', render: (c) => <><strong>{c.client}</strong><div className="muted">{c.client_numero}</div></> },
                    { titre: 'Cycle', render: (c) => c.numero },
                    { titre: 'Produit', render: (c) => c.produit },
                    { titre: 'Période', render: (c) => `${fdate(c.date_debut)} → ${fdate(c.date_fin)}` },
                    { titre: 'Dernier contrôle', render: (c) => (c.dernier_controle ? fdate(c.dernier_controle) : 'Jamais') },
                  ]} />
              </>
            )
          }}
        </Charge>
      </Card>
      {cycle && <ControlerCycle cycle={cycle} onClose={() => setCycle(null)} onFait={() => { setCycle(null); q.reload() }} />}
    </Page>
  )
}

function ControlerCycle({ cycle, onClose, onFait }: { cycle: CycleCarnet; onClose: () => void; onFait: () => void }) {
  const lignes = useFetch(() => api.get<LigneCollecte[]>(`/api/controle-carnet/cycles/${cycle.id}/lignes`), [cycle.id])
  const histo = useFetch(() => api.get<ControleHisto[]>(`/api/controle-carnet/cycles/${cycle.id}/controles`), [cycle.id])
  const { run, busy } = useAction()
  const [saisie, setSaisie] = useState<Record<number, string>>({})
  const [commentaire, setCommentaire] = useState('')
  const [motif, setMotif] = useState('')
  const rows = lignes.data ?? []
  // un cycle n'est contrôlé qu'une fois : s'il l'est déjà, on affiche les valeurs enregistrées et on ne fait que les corriger
  const controle = histo.data?.find((k) => !k.annule) ?? null
  const valeur = (id: number) => saisie[id] ?? (controle?.lignes.find((x) => x.ligne_collecte_id === id)?.montant_carnet.toString() ?? '')
  const libre = cycle.type_cycle === 3
  const horsMultiple = (v: string) => !libre && v !== '' && Number(v) % cycle.mise_courante !== 0
  const nbHors = rows.filter((l) => horsMultiple(valeur(l.id))).length
  const motifOk = !controle || motif.trim().length >= 5
  const complet = rows.length > 0 && rows.every((l) => valeur(l.id) !== '') && nbHors === 0 && motifOk
  const totalColl = rows.reduce((s, l) => s + l.montant_collecte, 0)
  const totalCarnet = rows.reduce((s, l) => s + Number(valeur(l.id) || 0), 0)
  const ecartDe = (l: LigneCollecte) => (valeur(l.id) === '' ? null : Number(valeur(l.id)) - l.montant_collecte)
  return (
    <Modal titre={`Contrôle au carnet — ${cycle.client} · ${cycle.numero}`} onClose={onClose} large>
      <div className="stack">
        <Alert tone="info">Saisissez, pour chaque collecte, le montant porté sur le carnet du client. Un écart positif est un manquant de collecte ; un écart négatif est un excédent mis en réserve.</Alert>
        {controle && <Alert tone="info">Ce cycle a déjà été contrôlé le {fdate(controle.date_controle)} par {controle.controleur}. Vous pouvez seulement corriger des valeurs, avec un motif.</Alert>}
        {nbHors > 0 && <Alert tone="warn">Sur ce cycle à mise fixe, le montant porté sur le carnet doit être un multiple de la mise ({xof(cycle.mise_courante)}) : {nbHors} ligne(s) à corriger.</Alert>}
        <Table rows={rows} vide="Aucune collecte sur ce cycle" cols={[
          { titre: 'Date', render: (l) => fdate(l.date_collecte) },
          { titre: 'Case', render: (l) => `${l.page}-${l.no_ligne}` },
          { titre: 'Agent', render: (l) => l.agent ?? '—' },
          { titre: 'Collecté (système)', num: true, render: (l) => xof(l.montant_collecte) },
          { titre: 'Carnet', num: true, render: (l) => (
            <Input type="number" min={0} aria-label={`Carnet ligne ${l.page}-${l.no_ligne}`} style={{ width: 120 }}
              value={valeur(l.id)} onChange={(e) => setSaisie({ ...saisie, [l.id]: e.target.value })} />
          ) },
          { titre: 'Écart', num: true, render: (l) => { const e = ecartDe(l); return e === null ? '—' : (e > 0 ? `+${xof(e)}` : xof(e)) } },
        ]} />
        <div className="row" style={{ justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
          <span className="muted">Total collecté {xof(totalColl)} · total carnet {xof(totalCarnet)} · écart {totalCarnet - totalColl > 0 ? '+' : ''}{xof(totalCarnet - totalColl)}</span>
          <Button variant="primary" disabled={!complet || busy} onClick={() => void run(() => (controle
            ? api.put(`/api/controle-carnet/cycles/${cycle.id}/controle`, {
              motif: motif.trim(), lignes: rows.map((l) => ({ ligne_id: l.id, montant_carnet: Number(valeur(l.id)) })),
            })
            : api.post(`/api/controle-carnet/cycles/${cycle.id}/controles`, {
              date_controle: aujourdhui(), commentaire: commentaire.trim() || null,
              lignes: rows.map((l) => ({ ligne_id: l.id, montant_carnet: Number(valeur(l.id)) })),
            })), controle ? 'Valeurs corrigées' : 'Contrôle enregistré', onFait)}>{controle ? 'Enregistrer la modification' : 'Enregistrer le contrôle'}</Button>
        </div>
        {controle
          ? <Field label="Motif de la modification" hint="Au moins 5 caractères ; chaque valeur changée est conservée"><Input value={motif} onChange={(e) => setMotif(e.target.value)} /></Field>
          : <Field label="Commentaire (facultatif)"><Input value={commentaire} onChange={(e) => setCommentaire(e.target.value)} /></Field>}
        <Card title="Contrôles précédents" flush>
          <Table rows={histo.data ?? []} vide="Aucun contrôle pour ce cycle" cols={[
            { titre: 'Date', render: (k) => fdate(k.date_controle) },
            { titre: 'Contrôleur', render: (k) => k.controleur },
            { titre: 'Collecté', num: true, render: (k) => xof(k.total_collecte) },
            { titre: 'Carnet', num: true, render: (k) => xof(k.total_carnet) },
            { titre: 'Écart', num: true, render: (k) => xof(k.ecart_collecte) },
            { titre: 'Commentaire', render: (k) => k.commentaire ?? '—' },
            { titre: 'Manquants', render: (k) => (k.lignes.some((l) => l.ecart > 0 && l.impute_agent === null)
              ? <Button small disabled={busy} onClick={() => void run(() => api.post(`/api/controle-carnet/controles/${k.id}/regler-manquants`), 'Manquants réglés : surplus utilisés, reste imputé à l\'agent', () => histo.reload())}>Régler les manquants</Button>
              : 'Réglés') },
          ]} />
        </Card>
      </div>
    </Modal>
  )
}
