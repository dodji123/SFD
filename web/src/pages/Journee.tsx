import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, Input, Page, Table, useAction, useFetch } from '../components/ui'

interface Jour { date_journee: string; statut: 'ouverte' | 'cloturee'; ouverte_le: string; cloturee_le: string | null }
interface Etat { agence_id: number; jours: Jour[]; sessions_ouvertes: number }

/** Ouverture et clôture de la journée de l'agence : une journée ouverte à la fois ; la clôture exige les sessions fermées
 *  et les validations de collecte et d'épargne faites. */
export default function Journee() {
  const { agenceId, can } = useSession()
  const etat = useFetch(() => api.get<Etat>('/api/journee'), [agenceId])
  const { run, busy } = useAction()
  const [date, setDate] = useState(aujourdhui())
  const [motif, setMotif] = useState('')

  return (
    <Page title="Journée de l'agence" subtitle="Ouvrir la journée de travail, la clôturer après les sessions de caisse et les validations">
      <Charge q={etat}>
        {(e) => {
          const ouverte = e.jours.find((j) => j.statut === 'ouverte') ?? null
          const derniere = e.jours[0] ?? null
          return (
            <>
              {e.sessions_ouvertes > 0 && <Alert tone="warn">{e.sessions_ouvertes} session(s) de caisse encore ouverte(s) : la clôture sera refusée.</Alert>}
              <Card title={ouverte ? `Journée ouverte : ${fdate(ouverte.date_journee)}` : 'Aucune journée ouverte'}>
                {ouverte ? (
                  <div className="row">
                    <Button variant="primary" disabled={busy} onClick={() => void run(() => api.post('/api/journee/cloturer', { date: ouverte.date_journee }), 'Journée clôturée', etat.reload)}>
                      Clôturer la journée
                    </Button>
                  </div>
                ) : (
                  <div className="row">
                    <Field label="Date à ouvrir"><Input type="date" value={date} max={aujourdhui()} onChange={(ev) => setDate(ev.target.value)} /></Field>
                    <Button variant="primary" disabled={busy} onClick={() => void run(() => api.post('/api/journee/ouvrir', { date }), 'Journée ouverte', etat.reload)}>
                      Ouvrir la journée
                    </Button>
                  </div>
                )}
              </Card>
              {can('collecte:admin') && derniere?.statut === 'cloturee' && (
                <Card title={`Rouvrir la journée du ${fdate(derniere.date_journee)}`}>
                  <div className="row">
                    <Field label="Motif (obligatoire)"><Input value={motif} onChange={(ev) => setMotif(ev.target.value)} /></Field>
                    <Button disabled={busy || motif.trim() === ''}
                      onClick={() => void run(() => api.post('/api/journee/rouvrir', { date: derniere.date_journee, motif: motif.trim() }), 'Journée rouverte', () => { setMotif(''); etat.reload() })}>
                      Rouvrir
                    </Button>
                  </div>
                </Card>
              )}
              <Card title="Historique" flush>
                <Table rows={e.jours} vide="Aucune journée" cols={[
                  { titre: 'Date', render: (j) => fdate(j.date_journee) },
                  { titre: 'Statut', render: (j) => <Badge tone={j.statut === 'ouverte' ? 'warn' : 'ok'}>{j.statut === 'ouverte' ? 'Ouverte' : 'Close'}</Badge> },
                  { titre: 'Ouverte le', render: (j) => fdate(j.ouverte_le) },
                  { titre: 'Close le', render: (j) => (j.cloturee_le ? fdate(j.cloturee_le) : '—') },
                ]} />
              </Card>
            </>
          )
        }}
      </Charge>
    </Page>
  )
}
