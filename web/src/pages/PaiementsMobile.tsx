import { useEffect, useState } from 'react'
import { api } from '../lib/api'
import { date as fdate, dateHeure, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Page, Select, Table, Tabs, useAction, useFetch } from '../components/ui'

interface Paiement {
  id: number; reference: string; cycle: string; client: string; client_numero: string; produit: string; operateur_libelle: string; telephone: string
  montant: number; statut: string; ref_operateur: string | null; motif: string | null; cree_le: string
}
interface Demande {
  id: number; cycle: string; client: string; client_numero: string; produit: string; canal: string; operateur: string | null; telephone: string | null; motif: string | null
  statut: string; cree_le: string; decide_par_nom: string | null; commentaire: string | null; retrait_id: number | null
}

const STATUTS_PAIEMENT: Record<string, { texte: string; tone: 'ok' | 'warn' | 'bad' | 'info' | 'neutre' }> = {
  initie: { texte: 'En attente', tone: 'warn' }, reussi: { texte: 'Réussi', tone: 'ok' }, echoue: { texte: 'Échoué', tone: 'bad' }, expire: { texte: 'Expiré', tone: 'neutre' },
  a_rembourser: { texte: 'À rembourser', tone: 'bad' }, rembourse: { texte: 'Remboursé', tone: 'info' },
}
const STATUTS_DEMANDE: Record<string, { texte: string; tone: 'ok' | 'warn' | 'bad' | 'neutre' }> = {
  en_attente: { texte: 'En attente', tone: 'warn' }, acceptee: { texte: 'Acceptée', tone: 'ok' }, refusee: { texte: 'Refusée', tone: 'bad' }, annulee: { texte: 'Annulée', tone: 'neutre' },
}

/** Suivi des paiements mobile money des clients et décision sur leurs demandes de retrait. */
export default function PaiementsMobile() {
  const [onglet, setOnglet] = useState('paiements')
  return (
    <Page title="Mobile money et demandes des clients" subtitle="Paiements reçus par l’espace client et demandes de retrait à examiner">
      <Tabs actif={onglet} onChange={setOnglet} tabs={[{ id: 'paiements', titre: 'Paiements mobile money' }, { id: 'demandes', titre: 'Demandes de retrait' }]} />
      {onglet === 'paiements' ? <Paiements /> : <Demandes />}
    </Page>
  )
}

function Paiements() {
  const { can, agenceId } = useSession()
  const [statut, setStatut] = useState('')
  const [q, setQ] = useState('')
  const [qd, setQd] = useState('')
  const [du, setDu] = useState('')
  const [au, setAu] = useState('')
  const [rembourser, setRembourser] = useState<Paiement | null>(null)
  useEffect(() => { const t = setTimeout(() => setQd(q), 250); return () => clearTimeout(t) }, [q])
  const liste = useFetch(() => api.get<Paiement[]>('/api/paiements-mobile', { statut, q: qd, du, au }), [statut, qd, du, au, agenceId])
  return (
    <Card flush>
      <div className="card-b row">
        <Field label="Recherche"><Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Référence, client, cycle, téléphone" /></Field>
        <Field label="Statut"><Select value={statut} onChange={(e) => setStatut(e.target.value)}><option value="">Tous</option>{Object.entries(STATUTS_PAIEMENT).map(([k, v]) => <option key={k} value={k}>{v.texte}</option>)}</Select></Field>
        <Field label="Du"><Input type="date" value={du} onChange={(e) => setDu(e.target.value)} /></Field>
        <Field label="Au"><Input type="date" value={au} onChange={(e) => setAu(e.target.value)} /></Field>
      </div>
      <Charge q={liste}>
        {(rows) => (
          <>
            {rows.some((p) => p.statut === 'a_rembourser') && <Alert tone="warn">Des versements ont été reçus sans pouvoir être inscrits au livret : à rembourser au client.</Alert>}
            <Table rows={rows} vide="Aucun paiement" cols={[
              { titre: 'Date', render: (p) => dateHeure(p.cree_le) }, { titre: 'Référence', render: (p) => p.reference },
              { titre: 'Client', render: (p) => `${p.client} (${p.client_numero})` }, { titre: 'Cycle', render: (p) => p.cycle },
              { titre: 'Opérateur', render: (p) => `${p.operateur_libelle} · ${p.telephone}` }, { titre: 'Montant', num: true, render: (p) => xof(p.montant) },
              { titre: 'Statut', render: (p) => <Badge tone={STATUTS_PAIEMENT[p.statut]?.tone ?? 'neutre'}>{STATUTS_PAIEMENT[p.statut]?.texte ?? p.statut}</Badge> },
              { titre: 'Détail', render: (p) => p.motif ?? '' },
              { titre: '', render: (p) => p.statut === 'a_rembourser' && can('paiement-mobile:rembourser') && <Button small onClick={() => setRembourser(p)}>Marquer remboursé</Button> },
            ]} />
          </>
        )}
      </Charge>
      {rembourser && <RemboursementModal p={rembourser} onClose={() => setRembourser(null)} onFait={() => { setRembourser(null); liste.reload() }} />}
    </Card>
  )
}

function RemboursementModal({ p, onClose, onFait }: { p: Paiement; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [ref, setRef] = useState('')
  return (
    <FormModal titre={`Rembourser ${p.reference}`} onClose={onClose} busy={busy} valider="Confirmer le remboursement"
      onSubmit={() => void run(() => api.post(`/api/paiements-mobile/${p.id}/rembourser`, { reference_remboursement: ref.trim() }), 'Remboursement enregistré', onFait)}>
      <p style={{ margin: 0 }}>{xof(p.montant)} à rendre à {p.client} sur le {p.telephone} ({p.operateur_libelle}). Effectuez d’abord le remboursement chez l’opérateur, puis saisissez sa référence.</p>
      <Field label="Référence du remboursement"><Input value={ref} onChange={(e) => setRef(e.target.value)} minLength={3} required /></Field>
    </FormModal>
  )
}

function Demandes() {
  const { can, agenceId } = useSession()
  const [statut, setStatut] = useState('en_attente')
  const [decision, setDecision] = useState<{ d: Demande; accepte: boolean } | null>(null)
  const liste = useFetch(() => api.get<Demande[]>('/api/demandes-retrait-client', { statut }), [statut, agenceId])
  return (
    <Card flush>
      <div className="card-b row"><Field label="Statut"><Select value={statut} onChange={(e) => setStatut(e.target.value)}><option value="">Tous</option>{Object.entries(STATUTS_DEMANDE).map(([k, v]) => <option key={k} value={k}>{v.texte}</option>)}</Select></Field></div>
      <Charge q={liste}>
        {(rows) => (
          <Table rows={rows} vide="Aucune demande" cols={[
            { titre: 'Date', render: (d) => fdate(d.cree_le) }, { titre: 'Client', render: (d) => `${d.client} (${d.client_numero})` }, { titre: 'Cycle', render: (d) => `${d.cycle} · ${d.produit}` },
            { titre: 'Paiement souhaité', render: (d) => (d.canal === 'mobile_money' ? `Mobile money ${d.operateur ?? ''} ${d.telephone ?? ''}` : 'En agence') }, { titre: 'Motif', render: (d) => d.motif ?? '' },
            { titre: 'Statut', render: (d) => <Badge tone={STATUTS_DEMANDE[d.statut]?.tone ?? 'neutre'}>{STATUTS_DEMANDE[d.statut]?.texte ?? d.statut}</Badge> },
            { titre: 'Décision', render: (d) => (d.decide_par_nom ? `${d.decide_par_nom}${d.commentaire ? ` — ${d.commentaire}` : ''}` : '') },
            { titre: '', render: (d) => d.statut === 'en_attente' && can('demande-retrait:decider') && (
              <span className="row"><Button small variant="primary" onClick={() => setDecision({ d, accepte: true })}>Accepter</Button><Button small variant="danger" onClick={() => setDecision({ d, accepte: false })}>Refuser</Button></span>
            ) },
          ]} />
        )}
      </Charge>
      {decision && <DecisionModal {...decision} onClose={() => setDecision(null)} onFait={() => { setDecision(null); liste.reload() }} />}
    </Card>
  )
}

function DecisionModal({ d, accepte, onClose, onFait }: { d: Demande; accepte: boolean; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [commentaire, setCommentaire] = useState('')
  return (
    <FormModal titre={accepte ? 'Accepter la demande de retrait' : 'Refuser la demande de retrait'} onClose={onClose} busy={busy} valider={accepte ? 'Accepter' : 'Refuser'}
      onSubmit={() => void run(() => api.post(`/api/demandes-retrait-client/${d.id}/decider`, { accepte, commentaire: commentaire.trim() || null }), accepte ? 'Demande acceptée : le retrait est créé' : 'Demande refusée', onFait)}>
      <p style={{ margin: 0 }}>{d.client} — cycle {d.cycle}.</p>
      {accepte && <Alert tone="warn">L’acceptation clôture le cycle s’il est encore en cours et crée le retrait (le retrait est ensuite exécuté au guichet).</Alert>}
      <Field label={accepte ? 'Commentaire (facultatif)' : 'Raison du refus (obligatoire)'}><Input value={commentaire} onChange={(e) => setCommentaire(e.target.value)} required={!accepte} minLength={accepte ? 0 : 5} /></Field>
    </FormModal>
  )
}
