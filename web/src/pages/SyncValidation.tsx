// Synchronisations à valider : opérations envoyées par les téléphones des agents (client, cycle, collecte, clôture).
// Rien n'entre dans les données vives avant validation ; une validation rejoue le lot dans l'ordre client → cycle → collecte → clôture.
import { useMemo, useState } from 'react'
import { api } from '../lib/api'
import { dateHeure } from '../lib/format'
import { useSession } from '../lib/session'
import { Badge, Button, Card, Charge, Field, FormModal, Input, Page, Table, Tabs, useAction, useFetch, useToast } from '../components/ui'

interface Op {
  cle: string; type: 'client' | 'cycle' | 'collecte' | 'cloture'; statut: 'en_attente' | 'validee' | 'rejetee'; code: string | null; motif: string | null
  agent_id: number; agent: string; matricule: string; recu_le: string; jour: string; resume: string; decide_par: string | null
}
interface Resultat { cle: string; statut: 'validee' | 'rejetee' | 'differee' | 'ignoree'; code: string | null; motif: string | null }

const TYPES: Record<string, string> = { client: 'Nouveau client', cycle: 'Ouverture de cycle', collecte: 'Collecte', cloture: 'Clôture' }
const TON = { en_attente: 'warn', validee: 'ok', rejetee: 'bad' } as const
const LIB = { en_attente: 'En attente', validee: 'Validée', rejetee: 'Rejetée' } as const

export default function SyncValidation() {
  const { agenceId } = useSession()
  const toast = useToast()
  const { run, busy } = useAction()
  const [statut, setStatut] = useState<Op['statut']>('en_attente')
  const [jour, setJour] = useState('')
  const q = useFetch(() => api.get<Op[]>('/api/collecte/validations', { statut, date: jour || undefined }), [agenceId, statut, jour])
  const [rejet, setRejet] = useState<string[] | null>(null)
  const [motif, setMotif] = useState('')

  const lots = useMemo(() => {
    const m = new Map<string, Op[]>()
    for (const o of q.data ?? []) m.set(`${o.agent_id}|${o.jour}`, [...(m.get(`${o.agent_id}|${o.jour}`) ?? []), o])
    return [...m.values()]
  }, [q.data])

  async function valider(cles: string[]) {
    await run(async () => {
      const r = await api.post<{ resultats: Resultat[] }>('/api/collecte/validations/valider', { cles })
      const n = (s: string) => r.resultats.filter((x) => x.statut === s).length
      const premier = r.resultats.find((x) => x.statut === 'rejetee')
      const msg = `${n('validee')} validée(s)` + (n('rejetee') ? `, ${n('rejetee')} rejetée(s) par le contrôle (${premier?.motif})` : '') + (n('differee') ? `, ${n('differee')} différée(s)` : '')
      if (n('rejetee') || n('differee')) toast.err(msg); else toast.ok(msg)
    }, undefined, q.reload)
  }

  return (
    <Page title="Synchronisations à valider" subtitle="Opérations saisies sur le terrain par les agents : à contrôler avant d'entrer dans les données">
      <Tabs actif={statut} onChange={(id) => setStatut(id as Op['statut'])} tabs={[{ id: 'en_attente', titre: 'En attente' }, { id: 'validee', titre: 'Validées' }, { id: 'rejetee', titre: 'Rejetées' }]} />
      <div style={{ maxWidth: 220 }}><Field label="Jour de réception"><Input type="date" value={jour} onChange={(e) => setJour(e.target.value)} /></Field></div>
      <Charge q={q}>
        {() => lots.length === 0 ? <div className="empty">Aucune opération {LIB[statut].toLowerCase()}.</div> : (
          <>
            {lots.map((lot) => {
              const attente = lot.filter((o) => o.statut === 'en_attente').map((o) => o.cle)
              return (
                <Card key={`${lot[0].agent_id}|${lot[0].jour}`} flush
                  title={<>{lot[0].agent} <span className="muted">({lot[0].matricule}) · reçu le {dateHeure(lot[0].jour).slice(0, 10)} · {lot.length} opération(s)</span></>}
                  actions={attente.length > 0 && (
                    <>
                      <Button small variant="primary" disabled={busy} onClick={() => void valider(attente)}>Valider le lot ({attente.length})</Button>
                      <Button small variant="danger" disabled={busy} onClick={() => { setMotif(''); setRejet(attente) }}>Rejeter le lot</Button>
                    </>
                  )}>
                  <Table rows={lot} cols={[
                    { titre: 'Type', render: (o) => <Badge tone="info">{TYPES[o.type]}</Badge> },
                    { titre: 'Opération', render: (o) => <>{o.resume}{o.motif && <div className="muted">{o.motif}</div>}</> },
                    { titre: 'Reçue', render: (o) => dateHeure(o.recu_le) },
                    { titre: 'Statut', render: (o) => <Badge tone={TON[o.statut]}>{LIB[o.statut]}</Badge> },
                    { titre: '', render: (o) => o.statut === 'en_attente' && (
                      <span style={{ display: 'flex', gap: 6 }}>
                        <Button small disabled={busy} onClick={() => void valider([o.cle])}>Valider</Button>
                        <Button small variant="danger" disabled={busy} onClick={() => { setMotif(''); setRejet([o.cle]) }}>Rejeter</Button>
                      </span>) },
                  ]} />
                </Card>
              )
            })}
          </>
        )}
      </Charge>
      {rejet && (
        <FormModal titre={`Rejeter ${rejet.length} opération(s)`} valider="Rejeter" busy={busy} onClose={() => setRejet(null)}
          onSubmit={() => void run(() => api.post('/api/collecte/validations/rejeter', { cles: rejet, motif }), 'Rejetée(s) : l\'agent verra le motif', () => { setRejet(null); q.reload() })}>
          <Field label="Motif du rejet" hint="Affiché à l'agent sur son téléphone (5 caractères minimum)">
            <Input value={motif} onChange={(e) => setMotif(e.target.value)} minLength={5} maxLength={300} required autoFocus />
          </Field>
        </FormModal>
      )}
    </Page>
  )
}
