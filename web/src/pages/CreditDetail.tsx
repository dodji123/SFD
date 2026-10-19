import { useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Button, Card, Charge, Field, FormModal, Input, Kpi, Page, Select, Statut, Table, useAction, useFetch } from '../components/ui'

interface Echeance {
  id: number; no_echeance: number; date_prevue: string; capital: number; interet: number; capital_paye: number; interet_paye: number
  penalite_due: number; penalite_payee: number; statut: string; jours_retard: number; du_aujourdhui: number; date_paiement: string | null
}
interface Detail {
  id: number; numero: string; client_id: number; client: string; type: string; mode_remboursement: string; methode: string
  montant_accorde: number; taux: number; frais_dossier: number; date_deblocage: string; periodicite_jours: number
  capital_restant: number; garantie_bloquee: number; statut: string; cycle_garantie_id: number | null
  echeances: Echeance[]
  garantie: { montant_bloque: number; montant_saisi: number; montant_restant: number; statut: string } | null
  paiements: { id: number; date_operation: string; capital: number; interet: number; penalite: number; source: string }[]
}
interface Session { id: number; caisse: string; date_session: string; solde_theorique: number }

const SOURCES: Record<string, string> = { tontine: 'Collecte tontine', prelevement: 'Prélèvement', especes: 'Espèces', saisie_garantie: 'Saisie de garantie' }

export default function CreditDetail() {
  const { id } = useParams()
  const { can } = useSession()
  const q = useFetch(() => api.get<Detail>(`/api/credits/${id}`), [id])
  const [rembourser, setRembourser] = useState<Echeance | null>(null)
  return (
    <Charge q={q}>
      {(c) => {
        const prochaine = c.echeances.find((e) => e.statut !== 'payee')
        return (
          <Page title={`Crédit ${c.numero}`} subtitle={`${c.type === 'sur_epargne' ? 'Sur épargne' : 'Sans épargne'} · débloqué le ${fdate(c.date_deblocage)} · taux ${Math.round(c.taux * 1000) / 10} %/an`}
            actions={<><Link className="btn" to="/credits">← Crédits</Link><Link className="btn" to={`/clients/${c.client_id}`}>{c.client}</Link><Statut s={c.statut} />
              {can('credit:repay') && c.mode_remboursement === 'especes' && prochaine && <Button variant="primary" onClick={() => setRembourser(prochaine)}>Rembourser en espèces</Button>}</>}>
            <div className="grid-kpi">
              <Kpi label="Accordé" value={xof(c.montant_accorde)} />
              <Kpi label="Capital restant" value={xof(c.capital_restant)} />
              <Kpi label="Frais de dossier" value={xof(c.frais_dossier)} />
              {c.garantie && <Kpi label={`Garantie bloquée (${xof(c.garantie.montant_bloque)} au départ)`} value={xof(c.garantie_bloquee)} />}
              {prochaine && <Kpi label={`Dû aujourd'hui (éch. ${prochaine.no_echeance})`} value={xof(prochaine.du_aujourdhui)} tone={prochaine.jours_retard > 0 || prochaine.statut === 'echue' ? 'bad' : undefined} />}
            </div>
            {c.mode_remboursement === 'tontine' && <Alert tone="info">Remboursement sur la collecte du cycle de tontine : chaque échéance se déclenche dès que le collecté atteint son montant (voir « Retraits et écarts »).</Alert>}
            {c.garantie && c.garantie.montant_saisi > 0 && <Alert tone="warn">Garantie saisie : {xof(c.garantie.montant_saisi)}.</Alert>}
            <Card title="Échéancier" flush>
              <Table rows={c.echeances} cols={[
                { titre: 'N°', render: (e) => e.no_echeance },
                { titre: 'Date prévue', render: (e) => fdate(e.date_prevue) },
                { titre: 'Capital', num: true, render: (e) => xof(e.capital) },
                { titre: 'Intérêts', num: true, render: (e) => xof(e.interet) },
                { titre: 'Pénalité', num: true, render: (e) => (e.penalite_due ? xof(e.penalite_due) : '—') },
                { titre: 'Payé', num: true, render: (e) => xof(e.capital_paye + e.interet_paye + e.penalite_payee) },
                { titre: 'Retard', num: true, render: (e) => (e.jours_retard ? `${e.jours_retard} j` : '—') },
                { titre: 'Statut', render: (e) => <Statut s={e.statut} /> },
              ]} />
            </Card>
            <Card title="Paiements" flush>
              <Table rows={c.paiements} vide="Aucun paiement" cols={[
                { titre: 'Date', render: (p) => fdate(p.date_operation) },
                { titre: 'Origine', render: (p) => SOURCES[p.source] ?? p.source },
                { titre: 'Capital', num: true, render: (p) => xof(p.capital) },
                { titre: 'Intérêts', num: true, render: (p) => xof(p.interet) },
                { titre: 'Pénalités', num: true, render: (p) => xof(p.penalite) },
              ]} />
            </Card>
            {rembourser && <Remboursement e={rembourser} onClose={() => setRembourser(null)} onFait={() => { setRembourser(null); q.reload() }} />}
          </Page>
        )
      }}
    </Charge>
  )
}

function Remboursement({ e, onClose, onFait }: { e: Echeance; onClose: () => void; onFait: () => void }) {
  const sessions = useFetch(() => api.get<Session[]>('/api/sessions', { statut: 'ouverte' }), [])
  const { run, busy } = useAction()
  const [f, setF] = useState({ montant: String(e.du_aujourdhui), jour: aujourdhui(), session: '' })
  const maj = (k: keyof typeof f) => (ev: { target: { value: string } }) => setF({ ...f, [k]: ev.target.value })
  return (
    <FormModal titre={`Remboursement — échéance ${e.no_echeance}`} onClose={onClose} busy={busy} valider="Encaisser"
      onSubmit={() => void run(() => api.post(`/api/echeances/${e.id}/rembourser-especes`, { montant: Number(f.montant), date: f.jour, session_id: Number(f.session) }), 'Remboursement encaissé', onFait)}>
      <Field label="Montant encaissé (F)" hint={`Dû à ce jour : ${xof(e.du_aujourdhui)} (paiement partiel accepté)`}><Input type="number" min={1} value={f.montant} onChange={maj('montant')} required autoFocus /></Field>
      <Field label="Date"><Input type="date" value={f.jour} onChange={maj('jour')} required /></Field>
      <Field label="Session de caisse">
        <Select value={f.session} onChange={maj('session')} required>
          <option value="">— choisir —</option>
          {(sessions.data ?? []).map((s) => <option key={s.id} value={s.id}>{s.caisse} · {fdate(s.date_session)}</option>)}
        </Select>
      </Field>
      <p className="muted" style={{ gridColumn: '1 / -1', margin: 0 }}>Imputation : capital, puis intérêts, puis pénalités. Les échéances se règlent dans l'ordre.</p>
    </FormModal>
  )
}
