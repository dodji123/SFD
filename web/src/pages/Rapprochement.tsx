import { api } from '../lib/api'
import { telechargerCsv } from '../lib/csv'
import { date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Kpi, Table, useAction, useFetch } from '../components/ui'

interface Ligne { code: string; libelle: string; inventaire: number; comptabilite: number; ecart: number; conforme: boolean; note: string }
interface EtatAgence { agence_id: number; agence: string; validee: boolean; statut: string | null; ecart_total: number | null; valide_le: string | null }
interface Reponse { lignes: Ligne[]; tolerance: string; ecart_total: number; tous_conformes: boolean; validation: EtatAgence | null; agences: EtatAgence[] | null }
interface Historique { date_arrete: string; statut: string; ecart_total: number; justification: string | null; valide_par: string | null; agence: string }

export default function Rapprochement({ au, consolide }: { au: string; consolide: boolean }) {
  const { can } = useSession()
  const q = useFetch(() => api.get<Reponse>('/api/rapprochement', { date: au, consolide }), [au, consolide])
  const h = useFetch(() => api.get<Historique[]>('/api/rapprochement/historique', { consolide }), [consolide])
  const { run, busy } = useAction()
  const valider = (d: Reponse) => {
    let justification: string | null = null
    if (!d.tous_conformes) {
      justification = window.prompt(`Écart total de ${xof(d.ecart_total)} entre les fiches et la comptabilité. Justification de la validation (obligatoire) :`)
      if (!justification) return
    }
    void run(() => api.post('/api/rapprochement/valider', { date: au, justification }), 'Rapprochement validé', () => { q.reload(); h.reload() })
  }
  return (
    <div className="stack">
      <Alert tone="info">Rapprochement de l'inventaire des fiches (crédits, épargne) avec la comptabilité à la date d'arrêté. Un écart signale une opération non comptabilisée ou une erreur ; le comptable le justifie avant de s'appuyer sur les états consolidés. Les intérêts courus non échus, la tontine et les comptes d'attente ne sont pas rapprochés.</Alert>
      <Charge q={q}>
        {(d) => (
          <>
            <div className="grid-kpi">
              <Kpi label="Écart total (valeur absolue)" value={xof(d.ecart_total)} tone={d.tous_conformes ? undefined : 'bad'} />
              <Kpi label="Rubriques conformes" value={`${d.lignes.filter((l) => l.conforme).length} / ${d.lignes.length}`} />
              <Kpi label="Tolérance" value={`${d.tolerance} F`} />
              {d.validation && <Kpi label="Validation du jour" value={d.validation.validee ? (d.validation.statut === 'conforme' ? 'Conforme' : 'Écart justifié') : 'Non validé'} tone={d.validation.validee ? undefined : 'warn'} />}
            </div>
            <Card title={`Situation au ${fdate(au)}`} flush actions={<>
              {can('rapprochement:valider') && !consolide && <Button small variant="primary" disabled={busy} onClick={() => valider(d)}>Valider le rapprochement</Button>}
              <Button small onClick={() => telechargerCsv(`rapprochement-${au}`, ['Rubrique', 'Fiches', 'Comptabilité', 'Écart', 'Conforme'],
                d.lignes.map((l) => [l.libelle, l.inventaire, l.comptabilite, l.ecart, l.conforme ? 'oui' : 'non']))}>Exporter en CSV</Button></>}>
              <Table rows={d.lignes} cols={[
                { titre: 'Rubrique', render: (l) => <><strong>{l.libelle}</strong><div className="muted">{l.note}</div></> },
                { titre: 'Fiches', num: true, render: (l) => xof(l.inventaire) },
                { titre: 'Comptabilité', num: true, render: (l) => xof(l.comptabilite) },
                { titre: 'Écart', num: true, render: (l) => xof(l.ecart) },
                { titre: '', render: (l) => (l.conforme ? <Badge tone="ok">Conforme</Badge> : <Badge tone="bad">Écart</Badge>) },
              ]} />
            </Card>
            {d.agences && (
              <Card title="Validation par agence" flush>
                <Table rows={d.agences} cols={[
                  { titre: 'Agence', render: (a) => <strong>{a.agence}</strong> },
                  { titre: 'Situation', render: (a) => (!a.validee ? <Badge tone="warn">Non validé</Badge> : a.statut === 'conforme' ? <Badge tone="ok">Conforme</Badge> : <Badge tone="warn">Écart justifié</Badge>) },
                  { titre: 'Écart validé', num: true, render: (a) => (a.ecart_total === null ? '—' : xof(a.ecart_total)) },
                ]} />
              </Card>
            )}
          </>
        )}
      </Charge>
      <Card title="Historique des validations" flush>
        <Charge q={h}>
          {(rows) => (
            <Table rows={rows} vide="Aucune validation enregistrée" cols={[
              { titre: 'Arrêté', render: (x) => fdate(x.date_arrete) },
              { titre: 'Agence', render: (x) => x.agence },
              { titre: 'Statut', render: (x) => (x.statut === 'conforme' ? <Badge tone="ok">Conforme</Badge> : <Badge tone="warn">Écart justifié</Badge>) },
              { titre: 'Écart', num: true, render: (x) => xof(x.ecart_total) },
              { titre: 'Justification', render: (x) => x.justification ?? '' },
              { titre: 'Validé par', render: (x) => x.valide_par ?? '—' },
            ]} />
          )}
        </Charge>
      </Card>
    </div>
  )
}
