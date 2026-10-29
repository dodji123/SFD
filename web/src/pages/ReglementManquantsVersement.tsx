import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Button, Card, Charge, Field, Input, Page, Select, Table, useAction, useFetch } from '../components/ui'

interface SessionOuverte { id: number; caisse: string; date_session: string }
interface Manquant { agent_id: number; matricule: string; agent: string; dette: number; dernier_manquant: string | null }
interface Operation { id: number; type: string; montant: number; sens: number; date_operation: string; libelle: string }
interface Compte { agent_id: number; solde: number; operations: Operation[] }

const TYPES: Record<string, string> = {
  manquant_versement: 'Manquant de versement', perte_retrait: 'Perte sur retrait', correction_debit: 'Correction (débit)',
  versement: 'Versement reçu', retenue_commission: 'Retenue sur commission', correction_credit: 'Correction (crédit)',
}

// Manquants de versement des agents : règlement en numéraire, ou retenue sur le salaire au bulletin.
export default function ReglementManquantsVersement() {
  const { can } = useSession()
  const liste = useFetch(() => api.get<Manquant[]>('/api/manquants-versement'), [])
  const [agentId, setAgentId] = useState<number | null>(null)
  const [montant, setMontant] = useState('')
  const [date, setDate] = useState(aujourdhui())
  const [session, setSession] = useState('')
  const sessions = useFetch(() => (can('caisse:read') ? api.get<SessionOuverte[]>('/api/sessions', { statut: 'ouverte' }) : Promise.resolve([] as SessionOuverte[])), [])
  const { run, busy } = useAction()
  const compte = useFetch(() => (agentId === null ? Promise.resolve(null) : api.get<Compte>(`/api/agents/${agentId}/compte`)), [agentId])

  return (
    <Page title="Règlement des manquants de versement" subtitle="Règlement en numéraire, ou par retenue sur le salaire">
      <Charge q={liste}>
        {(rows) => (
          <Card title={`Agents débiteurs (${rows.length})`} flush actions={<span className="muted">Total dû {xof(rows.reduce((s, r) => s + Number(r.dette), 0))}</span>}>
            <Table rows={rows} vide="Aucun manquant de versement à régler" onRowClick={(r) => setAgentId(r.agent_id)} cols={[
              { titre: 'Agent', render: (r) => <><strong>{r.agent}</strong><div className="muted">{r.matricule}</div></> },
              { titre: 'Dernier manquant', render: (r) => (r.dernier_manquant ? fdate(r.dernier_manquant) : '—') },
              { titre: 'Montant dû', num: true, render: (r) => <strong>{xof(r.dette)}</strong> },
            ]} />
          </Card>
        )}
      </Charge>

      {agentId !== null && (
        <Charge q={compte}>
          {(c) => c && (
            <Card title="Détail du compte agent" actions={<Button small onClick={() => setAgentId(null)}>Fermer</Button>}>
              <p style={{ margin: '0 0 12px' }}>Solde du compte : <strong>{xof(c.solde)}</strong>{c.solde < 0 && ' (dette de l’agent)'}</p>
              <Alert tone="info">Une dette est retenue automatiquement sur le salaire au prochain bulletin (« Retenue sur dette d’agent », plafonnée au net).</Alert>

              {c.solde < 0 && can('versement:write') && (
                <div className="grid-form" style={{ marginTop: 12 }}>
                  <Field label="Montant encaissé en numéraire">
                    <Input type="number" min={1} value={montant} onChange={(e) => setMontant(e.target.value)} />
                  </Field>
                  <Field label="Date">
                    <Input type="date" value={date} onChange={(e) => setDate(e.target.value)} />
                  </Field>
                  <Field label="Caisse qui reçoit les espèces">
                    <Select value={session} onChange={(e) => setSession(e.target.value)}>
                      <option value="">Choisir une session ouverte</option>
                      {sessions.data?.map((s) => <option key={s.id} value={s.id}>{s.caisse} — {fdate(s.date_session)}</option>)}
                    </Select>
                  </Field>
                  <div className="row" style={{ alignItems: 'flex-end' }}>
                    <Button variant="primary" disabled={busy || !Number(montant) || Number(montant) > -c.solde || !session}
                      onClick={() => void run(() => api.post(`/api/agents/${agentId}/compte/reglement`, { montant: Number(montant), date, session_id: Number(session) }), 'Règlement en numéraire enregistré en caisse', () => { setMontant(''); setSession(''); liste.reload(); compte.reload() })}>
                      Encaisser en numéraire
                    </Button>
                  </div>
                </div>
              )}

              <div style={{ marginTop: 16 }}>
                <Table rows={c.operations} vide="Aucune opération" cols={[
                  { titre: 'Date', render: (o) => fdate(o.date_operation) },
                  { titre: 'Opération', render: (o) => TYPES[o.type] ?? o.type },
                  { titre: 'Libellé', render: (o) => o.libelle },
                  { titre: 'Montant', num: true, render: (o) => <strong>{o.sens > 0 ? '+' : '−'}{xof(o.montant)}</strong> },
                ]} />
              </div>
            </Card>
          )}
        </Charge>
      )}
    </Page>
  )
}
