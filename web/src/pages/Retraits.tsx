import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { FiltreTableau, filtrer } from '../components/ChampClient'
import { useAffichagePiece } from '../components/Piece'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Modal, Page, Select, Statut, Table, Tabs, useAction, useFetch } from '../components/ui'

interface Ecart { id: number; sens: string; montant: number; statut: string; montant_livret: number; montant_machine: number; details: { date_ecart: string; montant: number; agent_id: number; surplus_utilise: number; perte: number }[] | null }
interface Retrait {
  id: number; cycle_id: number; cycle: string; client: string; nature: string; montant: number; montant_livret: number | null; montant_paye: number | null
  ecart: number; statut: string; decaissement: boolean; date_demande: string; date_operation: string | null; date_atteinte: string | null
  ecarts?: Ecart[]; virement?: { compte: string; statut: string; montant_credite: number | null } | null
}
interface Session { id: number; caisse: string; date_session: string; statut: string; solde_theorique: number }
interface CycleDet { montant_collecte: number; lignes: { date_collecte: string; origine: string; agent_id: number | null; agent: string | null }[] }

const NATURES: Record<string, string> = { retrait_client: 'Retrait client', virement_vers_epargne: 'Virement vers épargne', remboursement: 'Remboursement de crédit', regularisation: 'Régularisation' }
const A_TRAITER = ['demande', 'ecart_en_traitement', 'fonds_disponibles']

export default function Retraits() {
  const { agenceId, can } = useSession()
  const [filtreNom, setFiltreNom] = useState('')
  const [selection, setSelection] = useState<number[]>([])
  const piece = useAffichagePiece()
  const { run: runPiece, busy: busyPiece } = useAction()
  const [onglet, setOnglet] = useState('a_traiter')
  const q = useFetch(() => api.get<Retrait[]>('/api/retraits', { limit: 300 }), [agenceId])
  const [detail, setDetail] = useState<Retrait | null>(null)
  const [action, setAction] = useState<null | { type: 'ecart' | 'executer'; r: Retrait }>(null)
  const fin = () => { setAction(null); setDetail(null); q.reload() }
  return (
    <Page title="Retraits et écarts" subtitle="Constat, traitement des écarts livret / machine, puis exécution">
      <Tabs actif={onglet} onChange={(id) => { setOnglet(id); setSelection([]) }} tabs={[{ id: 'a_traiter', titre: 'À traiter' }, { id: 'executes', titre: 'Exécutés' }]} />
      <Card flush actions={onglet === 'executes' && can('retrait:execute') && (
        <Button small variant="primary" disabled={busyPiece || selection.length === 0}
          onClick={() => void runPiece(async () => { const r = await api.post<{ id: number }>('/api/pieces/retraits-tontine', { retrait_ids: selection }); piece.ouvrir(r.id); setSelection([]) }, 'Pièce de retrait générée')}>
          Pièce de retrait ({selection.length} cycle{selection.length > 1 ? 's' : ''})</Button>
      )}>
        <FiltreTableau valeur={filtreNom} onChange={setFiltreNom} />
        <Charge q={q}>
          {(rows) => {
            const filtre = filtrer(rows.filter((r) => r.nature !== 'regularisation' && (onglet === 'a_traiter' ? A_TRAITER.includes(r.statut) : r.statut === 'execute')), filtreNom, (r) => [r.client, r.cycle])
            return (
              <Table rows={filtre} onRowClick={(r) => api.get<Retrait>(`/api/retraits/${r.id}`).then(setDetail)} vide={onglet === 'a_traiter' ? 'Aucun retrait en attente' : 'Aucun retrait exécuté'} cols={[
                ...(onglet === 'executes' && can('retrait:execute') ? [{ titre: '', render: (r: Retrait) => (['retrait_client', 'virement_vers_epargne'].includes(r.nature)
                  ? <input type="checkbox" aria-label={`Retenir ${r.client} ${r.cycle}`} checked={selection.includes(r.id)} onClick={(e) => e.stopPropagation()} onChange={(e) => setSelection(e.target.checked ? [...selection, r.id] : selection.filter((x) => x !== r.id))} />
                  : null) }] : []),
                { titre: 'Client', render: (r) => <><strong>{r.client}</strong><div className="muted">{r.cycle}</div></> },
                { titre: 'Nature', render: (r) => NATURES[r.nature] ?? r.nature },
                { titre: 'Net machine', num: true, render: (r) => xof(r.montant) },
                { titre: 'Écart', num: true, render: (r) => (r.ecart ? <Badge tone={r.ecart > 0 ? 'bad' : 'warn'}>{r.ecart > 0 ? '+' : ''}{xof(r.ecart)}</Badge> : '—') },
                { titre: 'Payé / crédité', num: true, render: (r) => (r.montant_paye !== null ? xof(r.montant_paye) : '—') },
                { titre: 'Date', render: (r) => fdate(r.date_operation ?? r.date_demande) },
                { titre: 'Statut', render: (r) => <Statut s={r.statut} /> },
                { titre: '', render: (r) => <Actions r={r} onAction={(type) => setAction({ type, r })} onFait={q.reload} /> },
              ]} />
            )
          }}
        </Charge>
      </Card>
      {piece.modal}
      {detail && !action && <Detail r={detail} onClose={() => setDetail(null)} />}
      {action?.type === 'ecart' && <DeclarerEcart r={action.r} onClose={() => setAction(null)} onFait={fin} />}
      {action?.type === 'executer' && <Executer r={action.r} onClose={() => setAction(null)} onFait={fin} />}
    </Page>
  )
}

function Actions({ r, onAction, onFait }: { r: Retrait; onAction: (t: 'ecart' | 'executer') => void; onFait: () => void }) {
  const { can } = useSession()
  const { run, busy } = useAction()
  const stop = (e: React.MouseEvent) => e.stopPropagation()
  return (
    <span className="actions" onClick={stop}>
      {r.statut === 'demande' && can('retrait:ecart') && (
        <>
          <Button small disabled={busy} onClick={() => void run(() => api.post(`/api/retraits/${r.id}/constat-sans-ecart`), 'Constaté sans écart', onFait)}>Sans écart</Button>
          <Button small onClick={() => onAction('ecart')}>Déclarer un écart</Button>
        </>
      )}
      {r.statut === 'ecart_en_traitement' && can('retrait:ecart') && (
        <Button small variant="primary" disabled={busy} onClick={() => void run(async () => {
          const d = await api.get<Retrait>(`/api/retraits/${r.id}`)
          const e = d.ecarts?.find((x) => x.statut === 'a_traiter')
          if (!e) throw new Error('Aucun écart à traiter')
          await api.post(`/api/ecarts/${e.id}/traiter`, {})
        }, 'Écart traité : surplus utilisé, perte imputée à l’agent', onFait)}>Traiter l'écart</Button>
      )}
      {r.statut === 'fonds_disponibles' && can('retrait:execute') && <Button small variant="primary" onClick={() => onAction('executer')}>Exécuter</Button>}
    </span>
  )
}

function Detail({ r, onClose }: { r: Retrait; onClose: () => void }) {
  return (
    <Modal titre={`${NATURES[r.nature] ?? r.nature} — ${r.client}`} onClose={onClose} large>
      <div className="stack">
        <div className="grid-kpi">
          <div className="card kpi"><div className="v">{xof(r.montant)}</div><div className="l">Net machine</div></div>
          <div className="card kpi"><div className="v">{r.montant_livret !== null ? xof(r.montant_livret) : '—'}</div><div className="l">Net selon le livret</div></div>
          <div className="card kpi"><div className="v">{r.montant_paye !== null ? xof(r.montant_paye) : '—'}</div><div className="l">Payé / crédité</div></div>
        </div>
        <p style={{ margin: 0 }}>Cycle {r.cycle} · demandé le {fdate(r.date_demande)} · <Statut s={r.statut} />{r.date_atteinte && <> · seuil atteint le {fdate(r.date_atteinte)}</>}</p>
        {r.virement && <Alert tone="info">Virement vers le compte {r.virement.compte} : {r.virement.statut === 'execute' ? `crédité de ${xof(r.virement.montant_credite)}` : 'en attente'}.</Alert>}
        {r.ecarts?.map((e) => (
          <Card key={e.id} title={e.sens === 'livret_sup' ? `Écart : le livret dépasse la machine de ${xof(e.montant)}` : `Écart : la machine dépasse le livret de ${xof(e.montant)}`}>
            <p className="muted" style={{ marginTop: 0 }}>Livret {xof(e.montant_livret)} · machine {xof(e.montant_machine)} · {e.statut === 'traite' ? 'traité' : 'à traiter'}</p>
            <Table rows={e.details ?? []} cols={[
              { titre: 'Date de collecte', render: (d) => fdate(d.date_ecart) },
              { titre: 'Montant', num: true, render: (d) => xof(d.montant) },
              { titre: 'Surplus utilisé', num: true, render: (d) => xof(d.surplus_utilise) },
              { titre: 'Perte imputée', num: true, render: (d) => xof(d.perte) },
            ]} />
          </Card>
        ))}
      </div>
    </Modal>
  )
}

function DeclarerEcart({ r, onClose, onFait }: { r: Retrait; onClose: () => void; onFait: () => void }) {
  const cycle = useFetch(() => api.get<CycleDet>(`/api/cycles/${r.cycle_id}`), [r.cycle_id])
  const { run, busy } = useAction()
  const [livret, setLivret] = useState('')
  const [lignes, setLignes] = useState<{ cle: string; montant: string }[]>([{ cle: '', montant: '' }])
  const collecte = cycle.data?.montant_collecte ?? 0
  const ecart = livret === '' ? null : Number(livret) - collecte
  // couples date / agent proposés : ceux qui ont réellement collecté sur ce cycle
  const options = Array.from(new Map((cycle.data?.lignes ?? []).filter((l) => l.origine === 'collecte' && l.agent_id)
    .map((l) => [`${l.date_collecte}|${l.agent_id}`, `${fdate(l.date_collecte)} — ${l.agent}`])).entries())
  const somme = lignes.reduce((s, l) => s + (Number(l.montant) || 0), 0)
  const ok = ecart !== null && ecart !== 0 && somme === Math.abs(ecart) && lignes.every((l) => l.cle)
  const maj = (i: number, v: Partial<{ cle: string; montant: string }>) => setLignes(lignes.map((l, j) => (j === i ? { ...l, ...v } : l)))
  return (
    <FormModal titre={`Écart de retrait — ${r.client}`} onClose={onClose} busy={busy} valider="Enregistrer l'écart" large
      onSubmit={() => ok && void run(() => api.post(`/api/retraits/${r.id}/ecart`, {
        montant_livret: Number(livret), montant_machine: collecte,
        details: lignes.map((l) => { const [d, a] = l.cle.split('|'); return { date: d, montant: Number(l.montant), agent_id: Number(a) } }),
      }), 'Écart enregistré', onFait)}>
      <Field label="Collecté selon la machine" hint="Total du cycle enregistré dans le système"><Input readOnly value={xof(collecte)} /></Field>
      <Field label="Collecté selon le livret (F)" hint="Ce que montre le livret papier du client"><Input type="number" min={0} value={livret} onChange={(e) => setLivret(e.target.value)} required autoFocus /></Field>
      <div style={{ gridColumn: '1 / -1' }}>
        {ecart === null ? <Alert tone="info">Saisissez le montant du livret.</Alert>
          : ecart === 0 ? <Alert tone="warn">Aucun écart : utilisez « Sans écart ».</Alert>
          : ecart > 0 ? <Alert tone="warn">Le livret dépasse la machine de {xof(ecart)} : le client est payé selon le livret ; l'écart se règle par le surplus de la date, puis par une perte imputée à l'agent.</Alert>
          : <Alert tone="info">La machine dépasse le livret de {xof(-ecart)} : le client est payé selon le livret ; l'excédent reste « à régulariser » jusqu'à la purge de la date.</Alert>}
      </div>
      <div style={{ gridColumn: '1 / -1' }} className="stack">
        <h3>Rattacher l'écart à des dates de collecte</h3>
        {lignes.map((l, i) => (
          <div key={i} className="row">
            <Field label="Date — agent"><Select value={l.cle} onChange={(e) => maj(i, { cle: e.target.value })}><option value="">— choisir —</option>{options.map(([k, lib]) => <option key={k} value={k}>{lib}</option>)}</Select></Field>
            <Field label="Montant (F)"><Input type="number" min={1} value={l.montant} onChange={(e) => maj(i, { montant: e.target.value })} /></Field>
            {lignes.length > 1 && <Button small onClick={() => setLignes(lignes.filter((_, j) => j !== i))}>Retirer</Button>}
          </div>
        ))}
        <div className="actions"><Button small onClick={() => setLignes([...lignes, { cle: '', montant: '' }])}>Ajouter une date</Button>
          <span className={somme === Math.abs(ecart ?? 0) && somme > 0 ? '' : 'muted'}>Total des dates : {xof(somme)}{ecart ? ` / écart ${xof(Math.abs(ecart))}` : ''}</span></div>
      </div>
    </FormModal>
  )
}

function Executer({ r, onClose, onFait }: { r: Retrait; onClose: () => void; onFait: () => void }) {
  const sessions = useFetch(() => api.get<Session[]>('/api/sessions', { statut: 'ouverte' }), [])
  const { run, busy } = useAction()
  const [session, setSession] = useState('')
  const [jour, setJour] = useState(aujourdhui())
  const espece = r.nature === 'retrait_client' && r.decaissement
  const paye = r.nature === 'remboursement' ? r.montant : r.montant + r.ecart
  return (
    <FormModal titre={`Exécuter — ${r.client}`} onClose={onClose} busy={busy} valider="Exécuter"
      onSubmit={() => void run(() => api.post(`/api/retraits/${r.id}/executer`, { date: jour, session_id: session ? Number(session) : null }), 'Retrait exécuté', onFait)}>
      <div style={{ gridColumn: '1 / -1' }}><Alert tone="info">{NATURES[r.nature]} : {r.nature === 'remboursement' ? 'imputé sur l\'échéance du crédit' : `${xof(paye)} ${r.nature === 'retrait_client' ? 'à payer au client' : 'crédités sur le compte'} (selon le livret).`}</Alert></div>
      <Field label="Date d'exécution"><Input type="date" value={jour} onChange={(e) => setJour(e.target.value)} required /></Field>
      {espece && (
        <Field label="Session de caisse" hint="Le paiement est enregistré en caisse">
          <Select value={session} onChange={(e) => setSession(e.target.value)} required>
            <option value="">— choisir —</option>
            {(sessions.data ?? []).map((s) => <option key={s.id} value={s.id}>{s.caisse} · {fdate(s.date_session)} · {xof(s.solde_theorique)}</option>)}
          </Select>
        </Field>
      )}
    </FormModal>
  )
}
