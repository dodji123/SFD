import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate } from '../lib/format'
import { Badge, Button, Card, Charge, Field, Input, Page, Table, useAction, useFetch } from '../components/ui'

interface Jour { date_operation: string; statut: 'ouverte' | 'cloturee'; ouverte_le: string; cloturee_le: string | null }
interface Etat { date_operation_ouverte: string | null; jours: Jour[] }

/** Date d'opération : la journée comptable unique de l'institution. Elle s'ouvre avant toute opération, la clôture
 *  vaut pour tout le monde, une date ne peut être future ni recréée. */
export default function Journee() {
  const etat = useFetch(() => api.get<Etat>('/api/journee'), [])
  const { run, busy } = useAction()
  const [date, setDate] = useState(aujourdhui())

  return (
    <Page title="Date d'opération" subtitle="Ouvrir la journée comptable avant toute opération, la clôturer pour tout le monde">
      <Charge q={etat}>
        {(e) => (
          <>
            <Card title={e.date_operation_ouverte ? `Date d'opération ouverte : ${fdate(e.date_operation_ouverte)}` : "Aucune date d'opération ouverte"}>
              {e.date_operation_ouverte ? (
                <div className="row">
                  <Button variant="primary" disabled={busy} onClick={() => void run(() => api.post('/api/journee/cloturer'), 'Date clôturée pour tout le monde', etat.reload)}>
                    Clôturer la date d'opération
                  </Button>
                </div>
              ) : (
                <div className="row">
                  <Field label="Date d'opération à ouvrir" hint="Ni future, ni une date déjà ouverte ou dépassée.">
                    <Input type="date" value={date} max={aujourdhui()} onChange={(ev) => setDate(ev.target.value)} />
                  </Field>
                  <Button variant="primary" disabled={busy} onClick={() => void run(() => api.post('/api/journee/ouvrir', { date }), "Date d'opération ouverte", etat.reload)}>
                    Ouvrir la date d'opération
                  </Button>
                </div>
              )}
            </Card>
            <Card title="Historique" flush>
              <Table rows={e.jours} vide="Aucune date d'opération" cols={[
                { titre: 'Date', render: (j) => fdate(j.date_operation) },
                { titre: 'Statut', render: (j) => <Badge tone={j.statut === 'ouverte' ? 'warn' : 'ok'}>{j.statut === 'ouverte' ? 'Ouverte' : 'Close'}</Badge> },
                { titre: 'Ouverte le', render: (j) => fdate(j.ouverte_le) },
                { titre: 'Close le', render: (j) => (j.cloturee_le ? fdate(j.cloturee_le) : '—') },
              ]} />
            </Card>
          </>
        )}
      </Charge>
    </Page>
  )
}
