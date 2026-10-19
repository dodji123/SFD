import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Button, Card, Charge, Field, FormModal, Input, Kpi, Modal, Page, Select, Statut, Table, useAction, useFetch } from '../components/ui'

interface Caisse { id: number; code: string; type: string }
interface SessionC {
  id: number; caisse_id: number; caisse: string; date_session: string; statut: string; solde_ouverture: number
  encaissements: number; decaissements: number; solde_theorique: number; solde_compte: number | null; ecart_fermeture: number | null
}
interface Operation { id: number; type: string; motif: string; montant: number; date_operation: string; libelle: string | null }
interface SessionDetail extends SessionC { operations: Operation[] }

export default function Caisse() {
  const { can, agenceId } = useSession()
  const sessions = useFetch(() => api.get<SessionC[]>('/api/sessions'), [agenceId])
  const caisses = useFetch(() => api.get<Caisse[]>('/api/caisses'), [agenceId])
  const [modale, setModale] = useState<null | 'ouvrir' | 'caisse'>(null)
  const [ouverte, setOuverte] = useState<number | null>(null)
  return (
    <Page title="Caisse" subtitle="Sessions journalières : ouverture, opérations, fermeture avec écart"
      actions={can('caisse:write') && <><Button onClick={() => setModale('caisse')}>Nouvelle caisse</Button><Button variant="primary" onClick={() => setModale('ouvrir')}>Ouvrir une session</Button></>}>
      <Card flush>
        <Charge q={sessions}>
          {(rows) => (
            <Table rows={rows} onRowClick={(s) => setOuverte(s.id)} vide="Aucune session de caisse" cols={[
              { titre: 'Jour', render: (s) => fdate(s.date_session) },
              { titre: 'Caisse', render: (s) => s.caisse },
              { titre: 'Ouverture', num: true, render: (s) => xof(s.solde_ouverture) },
              { titre: 'Encaissements', num: true, render: (s) => xof(s.encaissements) },
              { titre: 'Décaissements', num: true, render: (s) => xof(s.decaissements) },
              { titre: 'Solde théorique', num: true, render: (s) => <strong>{xof(s.solde_theorique)}</strong> },
              { titre: 'Écart', num: true, render: (s) => (s.ecart_fermeture === null ? '—' : s.ecart_fermeture === 0 ? 'Aucun' : xof(s.ecart_fermeture)) },
              { titre: 'Statut', render: (s) => <Statut s={s.statut} /> },
            ]} />
          )}
        </Charge>
      </Card>
      {modale === 'caisse' && <NouvelleCaisse onClose={() => setModale(null)} onFait={() => { setModale(null); caisses.reload() }} />}
      {modale === 'ouvrir' && <Ouvrir caisses={caisses.data ?? []} onClose={() => setModale(null)} onFait={() => { setModale(null); sessions.reload() }} />}
      {ouverte !== null && <DetailSession id={ouverte} onClose={() => { setOuverte(null); sessions.reload() }} />}
    </Page>
  )
}

function NouvelleCaisse({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ code: '', type: 'principale' })
  return (
    <FormModal titre="Nouvelle caisse" onClose={onClose} busy={busy} valider="Créer"
      onSubmit={() => void run(() => api.post('/api/caisses', f), 'Caisse créée', onFait)}>
      <Field label="Code"><Input value={f.code} maxLength={10} onChange={(e) => setF({ ...f, code: e.target.value })} required autoFocus /></Field>
      <Field label="Type"><Select value={f.type} onChange={(e) => setF({ ...f, type: e.target.value })}><option value="principale">Principale</option><option value="guichet">Guichet</option><option value="coffre">Coffre</option></Select></Field>
    </FormModal>
  )
}

function Ouvrir({ caisses, onClose, onFait }: { caisses: Caisse[]; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ caisse: caisses[0] ? String(caisses[0].id) : '', jour: aujourdhui(), solde: '' })
  return (
    <FormModal titre="Ouvrir une session de caisse" onClose={onClose} busy={busy} valider="Ouvrir"
      onSubmit={() => void run(() => api.post(`/api/caisses/${f.caisse}/sessions`, { date_session: f.jour, solde_ouverture: Number(f.solde) }), 'Session ouverte', onFait)}>
      <Field label="Caisse">
        <Select value={f.caisse} onChange={(e) => setF({ ...f, caisse: e.target.value })} required>
          <option value="">— choisir —</option>{caisses.map((c) => <option key={c.id} value={c.id}>{c.code}</option>)}
        </Select>
      </Field>
      <Field label="Jour"><Input type="date" value={f.jour} onChange={(e) => setF({ ...f, jour: e.target.value })} required /></Field>
      <Field label="Solde d'ouverture compté (F)"><Input type="number" min={0} value={f.solde} onChange={(e) => setF({ ...f, solde: e.target.value })} required /></Field>
    </FormModal>
  )
}

function DetailSession({ id, onClose }: { id: number; onClose: () => void }) {
  const { can } = useSession()
  const q = useFetch(() => api.get<SessionDetail>(`/api/sessions/${id}`), [id])
  const { run, busy } = useAction()
  const [op, setOp] = useState({ type: 'encaissement', motif: '', montant: '', libelle: '' })
  const [compte, setCompte] = useState('')
  return (
    <Modal titre="Session de caisse" onClose={onClose} large>
      <Charge q={q}>
        {(s) => {
          const theo = s.solde_theorique
          const ecart = compte === '' ? null : Number(compte) - theo
          return (
            <div className="stack">
              <div className="grid-kpi">
                <Kpi label={`Ouverture du ${fdate(s.date_session)}`} value={xof(s.solde_ouverture)} />
                <Kpi label="Encaissements" value={xof(s.encaissements)} />
                <Kpi label="Décaissements" value={xof(s.decaissements)} />
                <Kpi label="Solde théorique" value={xof(theo)} />
              </div>
              <Table rows={s.operations} vide="Aucune opération" cols={[
                { titre: 'Date', render: (o) => fdate(o.date_operation) },
                { titre: 'Sens', render: (o) => (o.type === 'encaissement' ? 'Encaissement' : 'Décaissement') },
                { titre: 'Motif', render: (o) => <>{o.motif}{o.libelle && <div className="muted">{o.libelle}</div>}</> },
                { titre: 'Montant', num: true, render: (o) => (o.type === 'encaissement' ? '+ ' : '− ') + xof(o.montant) },
              ]} />
              {s.statut === 'ouverte' && can('caisse:write') && (
                <>
                  <Card title="Opération manuelle">
                    <div className="row">
                      <Field label="Sens"><Select value={op.type} onChange={(e) => setOp({ ...op, type: e.target.value })}><option value="encaissement">Encaissement</option><option value="decaissement">Décaissement</option></Select></Field>
                      <Field label="Motif"><Input value={op.motif} onChange={(e) => setOp({ ...op, motif: e.target.value })} placeholder="ex. approvisionnement" /></Field>
                      <Field label="Montant (F)"><Input type="number" min={1} value={op.montant} onChange={(e) => setOp({ ...op, montant: e.target.value })} /></Field>
                      <Button disabled={busy || !op.motif || !op.montant} onClick={() => void run(async () => {
                        await api.post(`/api/sessions/${id}/operations`, { type: op.type, motif: op.motif, montant: Number(op.montant), libelle: op.libelle || null })
                        setOp({ type: 'encaissement', motif: '', montant: '', libelle: '' })
                        q.reload()
                      }, 'Opération enregistrée')}>Enregistrer</Button>
                    </div>
                  </Card>
                  <Card title="Fermeture">
                    <div className="row">
                      <Field label="Solde compté (F)"><Input type="number" min={0} value={compte} onChange={(e) => setCompte(e.target.value)} /></Field>
                      <Field label="Écart avec le théorique"><Input readOnly value={ecart === null ? '—' : ecart === 0 ? 'Aucun écart' : `${ecart > 0 ? 'Excédent' : 'Manquant'} ${xof(Math.abs(ecart))}`} /></Field>
                      <Button variant="primary" disabled={busy || compte === ''} onClick={() => void run(() => api.post(`/api/sessions/${id}/fermer`, { solde_compte: Number(compte) }), 'Session fermée', q.reload)}>Fermer la session</Button>
                    </div>
                  </Card>
                </>
              )}
              {s.statut === 'fermee' && <Alert tone={s.ecart_fermeture ? 'warn' : 'info'}>Session fermée : compté {xof(s.solde_compte)} · {s.ecart_fermeture ? `écart de ${xof(s.ecart_fermeture)}` : 'aucun écart'}.</Alert>}
            </div>
          )
        }}
      </Charge>
    </Modal>
  )
}
