import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, xof } from '../lib/format'
import { Alert, Card, Charge, Field, Input, Page, Table, useFetch } from '../components/ui'

interface Ligne { agent_id: number; matricule: string; nom: string; manquants: number; pertes: number; autres_debits: number; recouvre: number; reste_du: number }

// Ce que chaque agent doit encore payer, sur une période choisie : manquants et pertes de la période, sommes recouvrées, reste dû à la fin.
export default function RapportManquants() {
  const [du, setDu] = useState(() => aujourdhui().slice(0, 8) + '01')
  const [au, setAu] = useState(() => aujourdhui())
  const invalide = au < du
  const q = useFetch(() => (invalide ? Promise.resolve([] as Ligne[]) : api.get<Ligne[]>('/api/rapport-manquants', { du, au })), [du, au])
  return (
    <Page title="Manquants non payés" subtitle="Ce que chaque agent doit encore payer, sur la période choisie">
      <Card>
        <div className="grid-form">
          <Field label="Du"><Input type="date" value={du} onChange={(e) => setDu(e.target.value)} /></Field>
          <Field label="Au"><Input type="date" value={au} onChange={(e) => setAu(e.target.value)} /></Field>
        </div>
        {invalide && <Alert tone="warn">La date de fin précède la date de début.</Alert>}
      </Card>
      <Card flush>
        {!invalide && (
          <Charge q={q}>
            {(rows) => {
              const total = (k: keyof Ligne) => rows.reduce((s, l) => s + Number(l[k]), 0)
              return (
                <>
                  <Table rows={rows} vide="Aucun manquant ni reste dû sur cette période" cols={[
                    { titre: 'Agent', render: (l) => <><strong>{l.nom}</strong><div className="muted">{l.matricule}</div></> },
                    { titre: 'Manquants de la période', num: true, render: (l) => xof(l.manquants) },
                    { titre: 'Pertes de retrait', num: true, render: (l) => xof(l.pertes) },
                    { titre: 'Autres débits', num: true, render: (l) => xof(l.autres_debits) },
                    { titre: 'Recouvré', num: true, render: (l) => xof(l.recouvre) },
                    { titre: 'Reste dû à la fin', num: true, render: (l) => <strong>{xof(l.reste_du)}</strong> },
                  ]} />
                  {rows.length > 0 && (
                    <p className="muted" style={{ padding: '8px 16px' }}>
                      Total : manquants {xof(total('manquants'))} · pertes {xof(total('pertes'))} · recouvré {xof(total('recouvre'))} · reste dû {xof(total('reste_du'))}
                    </p>
                  )}
                </>
              )
            }}
          </Charge>
        )}
      </Card>
    </Page>
  )
}
