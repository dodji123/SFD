import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Modal, Select, Table, Tabs, useAction, useFetch } from '../components/ui'

interface Sanction { id: number; matricule: string; nom: string; date_faits: string; type: string; motif: string; statut: string; date_entretien_prealable: string | null; jours_mise_a_pied: number | null }
interface Sortie { id: number; employe_id: number; matricule: string; nom: string; type: string; date_notification: string; date_sortie: string; motif: string; indemnite_conges: number; retenue_avances: number; solde_tout_compte: number; statut: string }
interface Emp { id: number; matricule: string; nom: string; statut: string }
interface Certificat {
  type: 'certificat' | 'attestation'; date_edition: string
  employe: { matricule: string; nom: string; date_naissance: string | null; lieu_naissance: string | null; date_embauche: string; date_sortie: string | null; poste: string | null }
  institution: { raison_sociale: string; sigle: string | null; adresse: string | null; ville: string | null; telephone: string | null; pied_de_page: string | null }
  agence: { libelle: string; ville: string | null } | null
}

const TYPES_SANCTION: Record<string, string> = { avertissement_verbal: 'Avertissement verbal', avertissement_ecrit: 'Avertissement écrit', blame: 'Blâme', mise_a_pied: 'Mise à pied' }
const TYPES_SORTIE: Record<string, string> = { demission: 'Démission', licenciement: 'Licenciement', fin_cdd: 'Fin de CDD', retraite: 'Retraite', deces: 'Décès', rupture_conventionnelle: 'Rupture conventionnelle' }

export default function GrhDiscipline() {
  const { can } = useSession()
  const [vue, setVue] = useState('sanctions')
  return (
    <div className="stack">
      <Tabs actif={vue} onChange={setVue} tabs={[{ id: 'sanctions', titre: 'Sanctions' }, ...(can('sortie:write') ? [{ id: 'sorties', titre: 'Sorties et solde de tout compte' }] : [])]} />
      {vue === 'sanctions' && <Sanctions />}
      {vue === 'sorties' && <Sorties />}
    </div>
  )
}

function Sanctions() {
  const q = useFetch(() => api.get<Sanction[]>('/api/grh/sanctions'), [])
  const emps = useFetch(() => api.get<Emp[]>('/api/employes'), [])
  const { run, busy } = useAction()
  const [nouvelle, setNouvelle] = useState(false)
  const [f, setF] = useState({ employe_id: '', date_faits: aujourdhui(), type: 'avertissement_ecrit', motif: '', entretien: '', jours: '' })
  return (
    <Card flush actions={<Button variant="primary" onClick={() => setNouvelle(true)}>Proposer une sanction</Button>}>
      <Alert tone="info">Gradation : avertissement, blâme, mise à pied. Dès l'avertissement écrit, un entretien préalable est obligatoire. Les faits se prescrivent après le délai paramétré. On ne prononce pas de sanction contre soi-même ; une sanction notifiée ne se modifie pas (annulation motivée seulement).</Alert>
      <Charge q={q}>
        {(rows) => <Table rows={rows} vide="Aucune sanction" cols={[
          { titre: 'Employé', render: (s) => <span><strong>{s.nom}</strong> <span className="muted">{s.matricule}</span></span> },
          { titre: 'Sanction', render: (s) => `${TYPES_SANCTION[s.type]}${s.jours_mise_a_pied ? ` (${s.jours_mise_a_pied} j)` : ''}` },
          { titre: 'Faits du', render: (s) => fdate(s.date_faits) }, { titre: 'Motif', render: (s) => s.motif },
          { titre: 'Entretien', render: (s) => (s.date_entretien_prealable ? fdate(s.date_entretien_prealable) : '—') },
          { titre: 'Statut', render: (s) => <Badge tone={s.statut === 'notifiee' ? 'bad' : s.statut === 'annulee' ? 'neutre' : 'warn'}>{s.statut}</Badge> },
          { titre: '', render: (s) => (
            <span className="actions">
              {s.statut === 'proposee' && <Button small variant="primary" disabled={busy} onClick={() => void run(() => api.post(`/api/grh/sanctions/${s.id}/notifier`), 'Sanction notifiée', q.reload)}>Notifier</Button>}
              {s.statut !== 'annulee' && <Button small disabled={busy} onClick={() => { const m = window.prompt("Motif de l'annulation :"); if (m) void run(() => api.post(`/api/grh/sanctions/${s.id}/annuler`, { motif: m }), 'Sanction annulée', q.reload) }}>Annuler</Button>}
            </span>
          ) },
        ]} />}
      </Charge>
      {nouvelle && (
        <FormModal titre="Proposer une sanction" onClose={() => setNouvelle(false)} busy={busy} valider="Enregistrer"
          onSubmit={() => void run(() => api.post('/api/grh/sanctions', { employe_id: Number(f.employe_id), date_faits: f.date_faits, type: f.type, motif: f.motif, date_entretien_prealable: f.entretien || null, jours_mise_a_pied: f.type === 'mise_a_pied' ? Number(f.jours) : null }), 'Sanction enregistrée', () => { setNouvelle(false); q.reload() })}>
          <Field label="Employé"><Select value={f.employe_id} onChange={(e) => setF({ ...f, employe_id: e.target.value })} required><option value="">— choisir —</option>{emps.data?.filter((e) => e.statut === 'actif').map((e) => <option key={e.id} value={e.id}>{e.nom} ({e.matricule})</option>)}</Select></Field>
          <Field label="Date des faits"><Input type="date" max={aujourdhui()} value={f.date_faits} onChange={(e) => setF({ ...f, date_faits: e.target.value })} required /></Field>
          <Field label="Sanction"><Select value={f.type} onChange={(e) => setF({ ...f, type: e.target.value })}>{Object.entries(TYPES_SANCTION).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
          {f.type === 'mise_a_pied' && <Field label="Jours de mise à pied"><Input type="number" min={1} max={30} value={f.jours} onChange={(e) => setF({ ...f, jours: e.target.value })} required /></Field>}
          <Field label="Motif" hint="10 caractères au moins"><Input value={f.motif} onChange={(e) => setF({ ...f, motif: e.target.value })} minLength={10} required /></Field>
          <Field label="Entretien préalable" hint="Obligatoire dès l'avertissement écrit"><Input type="date" value={f.entretien} onChange={(e) => setF({ ...f, entretien: e.target.value })} /></Field>
        </FormModal>
      )}
    </Card>
  )
}

function Sorties() {
  const q = useFetch(() => api.get<Sortie[]>('/api/grh/sorties'), [])
  const emps = useFetch(() => api.get<Emp[]>('/api/employes'), [])
  const { run, busy } = useAction()
  const [nouvelle, setNouvelle] = useState(false)
  const [certificat, setCertificat] = useState<Certificat | null>(null)
  const [f, setF] = useState({ employe_id: '', type: 'demission', notification: aujourdhui(), sortie: aujourdhui(), motif: '' })
  return (
    <Card flush actions={<Button variant="primary" onClick={() => setNouvelle(true)}>Préparer une sortie</Button>}>
      <Alert tone="info">Démission et licenciement exigent le préavis paramétré. La finalisation (à la date de sortie) clôt le contrat, désactive le compte utilisateur et l'agent, solde les avances et annule les congés futurs. Le solde de tout compte = congés restants valorisés − avances non remboursées.</Alert>
      <Charge q={q}>
        {(rows) => <Table rows={rows} vide="Aucune sortie" cols={[
          { titre: 'Employé', render: (s) => <span><strong>{s.nom}</strong> <span className="muted">{s.matricule}</span></span> }, { titre: 'Type', render: (s) => TYPES_SORTIE[s.type] },
          { titre: 'Notifiée le', render: (s) => fdate(s.date_notification) }, { titre: 'Sortie le', render: (s) => fdate(s.date_sortie) },
          { titre: 'Congés indemnisés', num: true, render: (s) => xof(s.indemnite_conges) }, { titre: 'Avances retenues', num: true, render: (s) => xof(s.retenue_avances) },
          { titre: 'Solde de tout compte', num: true, render: (s) => <strong>{xof(s.solde_tout_compte)}</strong> },
          { titre: 'Statut', render: (s) => <Badge tone={s.statut === 'finalisee' ? 'ok' : 'warn'}>{s.statut === 'finalisee' ? 'Finalisée' : 'En cours'}</Badge> },
          { titre: '', render: (s) => (s.statut === 'en_cours'
            ? <Button small variant="primary" disabled={busy} onClick={() => { if (window.confirm(`Finaliser la sortie de ${s.nom} ? Le compte sera désactivé.`)) void run(() => api.post(`/api/grh/sorties/${s.id}/finaliser`), 'Sortie finalisée', q.reload) }}>Finaliser</Button>
            : <Button small onClick={() => void api.get<Certificat>(`/api/grh/employes/${s.employe_id}/certificat-travail`).then(setCertificat)}>Certificat de travail</Button>) },
        ]} />}
      </Charge>
      {nouvelle && (
        <FormModal titre="Préparer une sortie" onClose={() => setNouvelle(false)} busy={busy} valider="Enregistrer"
          onSubmit={() => void run(() => api.post('/api/grh/sorties', { employe_id: Number(f.employe_id), type: f.type, date_notification: f.notification, date_sortie: f.sortie, motif: f.motif }), 'Sortie préparée', () => { setNouvelle(false); q.reload() })}>
          <Field label="Employé"><Select value={f.employe_id} onChange={(e) => setF({ ...f, employe_id: e.target.value })} required><option value="">— choisir —</option>{emps.data?.filter((e) => e.statut === 'actif').map((e) => <option key={e.id} value={e.id}>{e.nom} ({e.matricule})</option>)}</Select></Field>
          <Field label="Type"><Select value={f.type} onChange={(e) => setF({ ...f, type: e.target.value })}>{Object.entries(TYPES_SORTIE).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
          <Field label="Date de notification"><Input type="date" value={f.notification} onChange={(e) => setF({ ...f, notification: e.target.value })} required /></Field>
          <Field label="Date de sortie"><Input type="date" value={f.sortie} min={f.notification} onChange={(e) => setF({ ...f, sortie: e.target.value })} required /></Field>
          <Field label="Motif"><Input value={f.motif} onChange={(e) => setF({ ...f, motif: e.target.value })} minLength={5} required /></Field>
        </FormModal>
      )}
      {certificat && <CertificatModal c={certificat} onClose={() => setCertificat(null)} />}
    </Card>
  )
}

/** Certificat de travail (employé sorti) ou attestation de travail (employé en poste), imprimable. */
export function CertificatModal({ c, onClose }: { c: Certificat; onClose: () => void }) {
  const i = c.institution
  const e = c.employe
  return (
    <Modal titre={c.type === 'certificat' ? 'Certificat de travail' : 'Attestation de travail'} onClose={onClose} large footer={<><Button onClick={onClose}>Fermer</Button><Button variant="primary" onClick={() => window.print()}>Imprimer</Button></>}>
      <div className="piece-doc" style={{ padding: 24, border: '1px solid var(--line, #d1d5db)', borderRadius: 8, background: '#fff', color: '#111' }}>
        <div style={{ borderBottom: '2px solid #111', paddingBottom: 8 }}>
          <div style={{ fontSize: 18, fontWeight: 700 }}>{i.raison_sociale}{i.sigle ? ` (${i.sigle})` : ''}</div>
          <div style={{ fontSize: 12 }}>{[i.adresse, i.ville].filter(Boolean).join(', ')}{i.telephone ? ` — Tél. ${i.telephone}` : ''}</div>
        </div>
        <h2 style={{ textAlign: 'center', margin: '20px 0' }}>{c.type === 'certificat' ? 'CERTIFICAT DE TRAVAIL' : 'ATTESTATION DE TRAVAIL'}</h2>
        <p>Je soussigné, représentant de {i.raison_sociale}, certifie que <strong>{e.nom}</strong>{e.date_naissance ? `, né(e) le ${fdate(e.date_naissance)}${e.lieu_naissance ? ` à ${e.lieu_naissance}` : ''}` : ''} (matricule {e.matricule}),
          {c.type === 'certificat'
            ? <> a été employé(e) dans notre institution du <strong>{fdate(e.date_embauche)}</strong> au <strong>{e.date_sortie ? fdate(e.date_sortie) : '—'}</strong> en qualité de <strong>{e.poste ?? '—'}</strong>.<br />Il/elle nous quitte libre de tout engagement.</>
            : <> est employé(e) dans notre institution depuis le <strong>{fdate(e.date_embauche)}</strong> en qualité de <strong>{e.poste ?? '—'}</strong>.</>}</p>
        <p>Fait à {c.agence?.ville ?? i.ville ?? '…'}, le {fdate(c.date_edition)}, pour servir et valoir ce que de droit.</p>
        <div style={{ textAlign: 'right', marginTop: 48 }}>La Direction<div style={{ height: 56 }} /></div>
        {i.pied_de_page && <div style={{ marginTop: 16, borderTop: '1px solid #999', paddingTop: 6, fontSize: 11, textAlign: 'center' }}>{i.pied_de_page}</div>}
      </div>
    </Modal>
  )
}
