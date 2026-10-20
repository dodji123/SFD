import { useState } from 'react'
import { api } from '../lib/api'
import { date as fdate, dateHeure, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Money, Page, Select, Table, Tabs, useAction, useFetch } from '../components/ui'

interface Procuration { id: number; compte: string; client: string; mandataire_nom: string; mandataire_piece: string; debut: string; fin: string | null; plafond: number | null; statut: string }
interface Cheque { id: number; numero_cheque: string; beneficiaire: string; objet: string; montant: number; trois_signatures: boolean; statut: string; prepare_par: string | null; signatures: { fonction: string; nom: string; signe_le: string }[] }
interface CompteLigne { id: number; numero: string; client: string }
interface Banque { id: number; code: string; libelle: string }

const FONCTION: Record<string, string> = { directeur: 'Directeur', comptable: 'Comptable', president_ca: 'Président du conseil' }

/** Procurations sur les comptes d'épargne et chèques à signatures multiples. */
export default function ProcurationsCheques() {
  const { can } = useSession()
  const [vue, setVue] = useState(can('cheque:read') ? 'cheques' : 'procurations')
  const onglets = [...(can('cheque:read') ? [{ id: 'cheques', titre: 'Chèques' }] : []), { id: 'procurations', titre: 'Procurations' }]
  return (
    <Page title="Procurations et chèques" subtitle="Mandataires validés par une autre personne ; chèques signés par les personnes habilitées">
      <Tabs actif={vue} onChange={setVue} tabs={onglets} />
      {vue === 'cheques' && <Cheques />}
      {vue === 'procurations' && <Procurations />}
    </Page>
  )
}

function Procurations() {
  const { can } = useSession()
  const q = useFetch(() => api.get<Procuration[]>('/api/procurations'), [])
  const comptes = useFetch(() => api.get<CompteLigne[]>('/api/comptes-epargne'), [])
  const { run, busy } = useAction()
  const [nouvelle, setNouvelle] = useState(false)
  const [f, setF] = useState({ compte_id: '', nom: '', piece: '', tel: '', fin: '', plafond: '' })
  return (
    <Card flush actions={can('procuration:write') ? <Button variant="primary" onClick={() => setNouvelle(true)}>Nouvelle procuration</Button> : undefined}>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucune procuration" cols={[
            { titre: 'Compte', render: (p) => <span><strong>{p.compte}</strong> <span className="muted">{p.client}</span></span> },
            { titre: 'Mandataire', render: (p) => `${p.mandataire_nom} (${p.mandataire_piece})` },
            { titre: 'Validité', render: (p) => `${fdate(p.debut)} → ${p.fin ? fdate(p.fin) : '…'}` },
            { titre: 'Plafond', render: (p) => (p.plafond ? <Money v={p.plafond} /> : 'aucun') },
            { titre: 'Statut', render: (p) => <Badge tone={p.statut === 'validee' ? 'ok' : p.statut === 'revoquee' ? 'bad' : 'warn'}>{p.statut === 'en_attente' ? 'À valider' : p.statut}</Badge> },
            { titre: '', render: (p) => (can('procuration:valider') ? (
              <span className="actions">
                {p.statut === 'en_attente' && <Button small variant="primary" disabled={busy} onClick={() => void run(() => api.post(`/api/procurations/${p.id}/valider`), 'Procuration validée', q.reload)}>Valider</Button>}
                {p.statut !== 'revoquee' && <Button small variant="danger" disabled={busy} onClick={() => void run(() => api.post(`/api/procurations/${p.id}/revoquer`), 'Procuration révoquée', q.reload)}>Révoquer</Button>}
              </span>) : null) },
          ]} />
        )}
      </Charge>
      {nouvelle && (
        <FormModal titre="Nouvelle procuration" onClose={() => setNouvelle(false)} busy={busy} valider="Enregistrer"
          onSubmit={() => void run(() => api.post('/api/procurations', { compte_id: Number(f.compte_id), mandataire_nom: f.nom, mandataire_piece: f.piece, mandataire_tel: f.tel || null, fin: f.fin || null, plafond: f.plafond ? Number(f.plafond) : null }), 'Procuration enregistrée : à faire valider par une autre personne', () => { setNouvelle(false); q.reload() })}>
          <Field label="Compte d'épargne"><Select value={f.compte_id} onChange={(e) => setF({ ...f, compte_id: e.target.value })} required><option value="">— choisir —</option>{comptes.data?.map((c) => <option key={c.id} value={c.id}>{c.numero} · {c.client}</option>)}</Select></Field>
          <Field label="Nom du mandataire"><Input value={f.nom} onChange={(e) => setF({ ...f, nom: e.target.value })} required /></Field>
          <Field label="Pièce d'identité contrôlée" hint="Type et numéro"><Input value={f.piece} onChange={(e) => setF({ ...f, piece: e.target.value })} required minLength={3} /></Field>
          <Field label="Téléphone"><Input value={f.tel} onChange={(e) => setF({ ...f, tel: e.target.value })} /></Field>
          <Field label="Fin de validité" hint="Vide : jusqu'à révocation"><Input type="date" value={f.fin} onChange={(e) => setF({ ...f, fin: e.target.value })} /></Field>
          <Field label="Plafond par retrait" hint="Vide : aucun plafond"><Input type="number" min={1} value={f.plafond} onChange={(e) => setF({ ...f, plafond: e.target.value })} /></Field>
        </FormModal>
      )}
    </Card>
  )
}

function Cheques() {
  const { can, user } = useSession()
  const q = useFetch(() => api.get<Cheque[]>('/api/cheques'), [])
  const banques = useFetch(() => api.get<Banque[]>('/api/banques'), [])
  const { run, busy } = useAction()
  const [nouveau, setNouveau] = useState(false)
  const [f, setF] = useState({ banque: '', numero: '', beneficiaire: '', objet: '', montant: '' })
  const peutSigner = can('cheque:sign') && ['directeur', 'comptable', 'admin'].includes(user?.role ?? '')
  return (
    <Card flush actions={can('cheque:prepare') ? <Button variant="primary" onClick={() => setNouveau(true)}>Préparer un chèque</Button> : undefined}>
      <Alert tone="info">Directeur et comptable signent ; au-delà du plafond paramétré, le président du conseil (administrateur) signe aussi. Celui qui prépare le chèque ne le signe pas.</Alert>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucun chèque" cols={[
            { titre: 'N°', render: (c) => <strong>{c.numero_cheque}</strong> },
            { titre: 'Bénéficiaire', render: (c) => `${c.beneficiaire} — ${c.objet}` },
            { titre: 'Montant', render: (c) => <Money v={c.montant} /> },
            { titre: 'Signatures', render: (c) => `${c.signatures.length}/${c.trois_signatures ? 3 : 2} : ${c.signatures.map((s) => `${FONCTION[s.fonction]} (${dateHeure(s.signe_le)})`).join(', ') || 'aucune'}` },
            { titre: 'Statut', render: (c) => <Badge tone={c.statut === 'emis' ? 'ok' : c.statut === 'annule' ? 'bad' : 'warn'}>{c.statut}</Badge> },
            { titre: '', render: (c) => (c.statut === 'prepare' ? (
              <span className="actions">
                {peutSigner && <Button small disabled={busy} onClick={() => void run(() => api.post(`/api/cheques/${c.id}/signer`), 'Chèque signé', q.reload)}>Signer</Button>}
                {can('cheque:prepare') && <Button small variant="primary" disabled={busy} onClick={() => void run(() => api.post(`/api/cheques/${c.id}/emettre`), 'Chèque émis', q.reload)}>Émettre</Button>}
                {can('cheque:prepare') && <Button small variant="danger" disabled={busy} onClick={() => void run(() => api.post(`/api/cheques/${c.id}/annuler`), 'Chèque annulé', q.reload)}>Annuler</Button>}
              </span>) : null) },
          ]} />
        )}
      </Charge>
      {nouveau && (
        <FormModal titre="Préparer un chèque" onClose={() => setNouveau(false)} busy={busy} valider="Préparer"
          onSubmit={() => void run(() => api.post('/api/cheques', { compte_banque_id: Number(f.banque), numero_cheque: f.numero, beneficiaire: f.beneficiaire, objet: f.objet, montant: Number(f.montant) }), 'Chèque préparé', () => { setNouveau(false); q.reload() })}>
          <Field label="Compte bancaire"><Select value={f.banque} onChange={(e) => setF({ ...f, banque: e.target.value })} required><option value="">— choisir —</option>{banques.data?.map((b) => <option key={b.id} value={b.id}>{b.code} — {b.libelle}</option>)}</Select></Field>
          <Field label="Numéro du chèque"><Input value={f.numero} onChange={(e) => setF({ ...f, numero: e.target.value })} required autoFocus /></Field>
          <Field label="Bénéficiaire"><Input value={f.beneficiaire} onChange={(e) => setF({ ...f, beneficiaire: e.target.value })} required /></Field>
          <Field label="Objet" hint="Joindre l'original de la facture au classement"><Input value={f.objet} onChange={(e) => setF({ ...f, objet: e.target.value })} required minLength={3} /></Field>
          <Field label={`Montant (${xof(0).replace('0', '').trim() || 'F'})`}><Input type="number" min={1} value={f.montant} onChange={(e) => setF({ ...f, montant: e.target.value })} required /></Field>
        </FormModal>
      )}
    </Card>
  )
}
