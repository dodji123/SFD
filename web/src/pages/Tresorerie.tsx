import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, nombre, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Kpi, Page, Select, Table, Tabs, useAction, useFetch } from '../components/ui'

interface Etat { caisse_id: number; code: string; type: string; libelle: string | null; responsable: string | null; plafond: number | null; etat: string; session_id: number | null; solde: number | null; depassement_plafond: number }
interface Position { liquidites: { nature: string; code: string; libelle: string; solde: number; detail: string }[]; indicateurs: Record<string, number | null> }
interface Banque { id: number; code: string; libelle: string; banque: string | null; solde: number; non_rapproches: number }
interface MvtBanque { id: number; date_operation: string; type: string; montant: number; sens: number; libelle: string | null; rapproche: boolean }
interface Tranche { debut: string; fin: string; encaissements: number; decaissements: number; solde_projete: number }

const TYPES_CAISSE: Record<string, string> = { principale: 'Principale', guichet: 'Guichet', coffre: 'Coffre' }
const ETATS: Record<string, { t: string; tone: 'ok' | 'warn' | 'neutre' }> = { ouverte: { t: 'Ouverte', tone: 'ok' }, fermee: { t: 'Fermée', tone: 'neutre' }, non_ouverte: { t: 'Non ouverte', tone: 'warn' } }
const TYPES_MVT: Record<string, string> = { versement_caisse: 'Versement depuis la caisse', retrait_caisse: 'Retrait pour la caisse', depot_externe: 'Dépôt externe', retrait_externe: 'Retrait externe', frais: 'Frais', interets: 'Intérêts' }
const LIB_IND: Record<string, string> = {
  liquidites_caisses: 'Liquidités en caisses', liquidites_banques: 'Liquidités en banque', liquidites_totales: 'Liquidités totales',
  depassement_plafonds_caisses: 'Excédent au-delà des plafonds de caisse', echeances_en_retard: 'Échéances en retard', a_recevoir_7_jours: 'À recevoir sous 7 jours',
  a_recevoir_30_jours: 'À recevoir sous 30 jours', retraits_clients_en_attente: 'Retraits clients en attente', commissions_a_payer: 'Commissions à payer',
  epargne_classique: 'Épargne classique', tontine_a_rembourser: 'Tontine à rembourser', engagements_clients: 'Engagements envers les clients',
}

export default function Tresorerie() {
  const { agenceId } = useSession()
  const [jour, setJour] = useState(aujourdhui())
  const [onglet, setOnglet] = useState('position')
  return (
    <Page title="Trésorerie" subtitle="Caisses, banques et liquidités de l'agence" actions={<Field label="Jour"><Input type="date" value={jour} onChange={(e) => setJour(e.target.value || aujourdhui())} /></Field>}>
      <Tabs actif={onglet} onChange={setOnglet} tabs={[{ id: 'position', titre: 'Position' }, { id: 'caisses', titre: 'Caisses du jour' }, { id: 'banques', titre: 'Banques' }, { id: 'prevision', titre: 'Prévision' }]} />
      {onglet === 'position' && <PositionTab key={`${jour}${agenceId}`} jour={jour} />}
      {onglet === 'caisses' && <Caisses key={`${jour}${agenceId}`} jour={jour} />}
      {onglet === 'banques' && <Banques key={agenceId} jour={jour} />}
      {onglet === 'prevision' && <Prevision key={`${jour}${agenceId}`} jour={jour} />}
    </Page>
  )
}

function PositionTab({ jour }: { jour: string }) {
  const q = useFetch(() => api.get<Position>('/api/tresorerie/position', { date: jour }), [jour])
  return (
    <Charge q={q}>
      {(p) => {
        const i = p.indicateurs
        return (
          <div className="stack">
            {(i.depassement_plafonds_caisses ?? 0) > 0 && <Alert tone="warn">Des caisses dépassent leur plafond de {xof(i.depassement_plafonds_caisses)} au total : verser l'excédent en banque ou au coffre.</Alert>}
            <div className="grid-kpi">
              <Kpi label="Liquidités totales" value={xof(i.liquidites_totales)} />
              <Kpi label="Engagements envers les clients" value={xof(i.engagements_clients)} />
              <Kpi label="Ratio de liquidité" value={i.ratio_liquidite_pct === null ? '—' : `${nombre(i.ratio_liquidite_pct)} %`} tone={i.ratio_liquidite_pct !== null && i.ratio_liquidite_pct < 100 ? 'bad' : undefined} />
              <Kpi label="À recevoir sous 30 jours" value={xof(i.a_recevoir_30_jours)} />
            </div>
            <div className="grid-2">
              <Card title="Liquidités" flush>
                <Table rows={p.liquidites} vide="Aucune caisse ni compte bancaire" cols={[
                  { titre: 'Nature', render: (l) => (l.nature === 'caisse' ? 'Caisse' : 'Banque') },
                  { titre: 'Compte', render: (l) => <><strong>{l.code}</strong><div className="muted">{l.libelle}</div></> },
                  { titre: 'Solde', num: true, render: (l) => xof(l.solde) },
                  { titre: 'Détail', render: (l) => <span className="muted">{l.detail}</span> },
                ]} />
              </Card>
              <Card title="Indicateurs" flush>
                <table className="t"><tbody>
                  {Object.entries(LIB_IND).map(([k, lib]) => <tr key={k}><td>{lib}</td><td className="num">{xof(i[k])}</td></tr>)}
                </tbody></table>
              </Card>
            </div>
            <p className="muted" style={{ margin: 0 }}>Liquidités et échéances calculées au {fdate(jour)} ; engagements envers les clients et retraits en attente : état au moment de la lecture.</p>
          </div>
        )
      }}
    </Charge>
  )
}

function Caisses({ jour }: { jour: string }) {
  const { can } = useSession()
  const q = useFetch(() => api.get<Etat[]>('/api/caisses/etat', { date: jour }), [jour])
  const [modale, setModale] = useState<null | { type: 'ouvrir' | 'transfert' | 'regler'; e: Etat }>(null)
  const fin = () => { setModale(null); q.reload() }
  return (
    <Card flush>
      <Charge q={q}>
        {(rows) => (
          <>
            <Table rows={rows} vide="Aucune caisse : créez-en depuis la page Caisse" cols={[
              { titre: 'Caisse', render: (c) => <><strong>{c.code}</strong><div className="muted">{c.libelle ?? TYPES_CAISSE[c.type]}</div></> },
              { titre: 'Type', render: (c) => TYPES_CAISSE[c.type] },
              { titre: 'Responsable', render: (c) => c.responsable ?? '—' },
              { titre: 'Plafond', num: true, render: (c) => (c.plafond === null ? '—' : xof(c.plafond)) },
              { titre: 'Solde', num: true, render: (c) => <>{xof(c.solde)}{c.depassement_plafond > 0 && <div><Badge tone="warn">+{xof(c.depassement_plafond)} au-dessus du plafond</Badge></div>}</> },
              { titre: 'État', render: (c) => <Badge tone={ETATS[c.etat].tone}>{ETATS[c.etat].t}</Badge> },
              { titre: '', render: (c) => (
                <span className="actions">
                  {c.etat === 'non_ouverte' && can('caisse:write') && <Button small variant="primary" onClick={() => setModale({ type: 'ouvrir', e: c })}>Ouvrir</Button>}
                  {c.etat === 'ouverte' && can('caisse:write') && rows.filter((x) => x.etat === 'ouverte' && x.caisse_id !== c.caisse_id).length > 0 && <Button small onClick={() => setModale({ type: 'transfert', e: c })}>Transférer</Button>}
                  {can('tresorerie:write') && <Button small onClick={() => setModale({ type: 'regler', e: c })}>Plafond</Button>}
                </span>
              ) },
            ]} />
            {modale?.type === 'ouvrir' && <OuvrirCaisse e={modale.e} jour={jour} onClose={() => setModale(null)} onFait={fin} />}
            {modale?.type === 'transfert' && <Transfert e={modale.e} ouvertes={rows.filter((x) => x.etat === 'ouverte' && x.caisse_id !== modale.e.caisse_id)} jour={jour} onClose={() => setModale(null)} onFait={fin} />}
            {modale?.type === 'regler' && <Plafond e={modale.e} onClose={() => setModale(null)} onFait={fin} />}
          </>
        )}
      </Charge>
    </Card>
  )
}

function OuvrirCaisse({ e, jour, onClose, onFait }: { e: Etat; jour: string; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [solde, setSolde] = useState(String(e.solde ?? 0))
  const [accepter, setAccepter] = useState(false)
  return (
    <FormModal titre={`Ouvrir la caisse ${e.code}`} onClose={onClose} busy={busy} valider="Ouvrir"
      onSubmit={() => void run(() => api.post(`/api/caisses/${e.caisse_id}/sessions`, { date_session: jour, solde_ouverture: Number(solde), accepter_ecart: accepter }), 'Session ouverte', onFait)}>
      <Field label="Jour"><Input value={fdate(jour)} readOnly /></Field>
      <Field label="Solde d'ouverture compté (F)" hint={`Dernier solde compté : ${xof(e.solde)}`}><Input type="number" min={0} value={solde} onChange={(ev) => setSolde(ev.target.value)} required autoFocus /></Field>
      <label className="row" style={{ gridColumn: '1 / -1', alignItems: 'center', gap: 8 }}>
        <input type="checkbox" checked={accepter} onChange={(ev) => setAccepter(ev.target.checked)} />
        <span>Accepter un écart avec le solde compté à la fermeture précédente (l'écart sera tracé)</span>
      </label>
    </FormModal>
  )
}

function Transfert({ e, ouvertes, jour, onClose, onFait }: { e: Etat; ouvertes: Etat[]; jour: string; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ dest: String(ouvertes[0]?.session_id ?? ''), montant: '', motif: '' })
  return (
    <FormModal titre={`Transfert depuis ${e.code}`} onClose={onClose} busy={busy} valider="Transférer"
      onSubmit={() => void run(() => api.post('/api/sessions/transfert', { session_source: e.session_id, session_dest: Number(f.dest), montant: Number(f.montant), date: jour, motif: f.motif || null }), 'Transfert effectué', onFait)}>
      <Field label="Vers la caisse"><Select value={f.dest} onChange={(ev) => setF({ ...f, dest: ev.target.value })} required>{ouvertes.map((o) => <option key={o.caisse_id} value={o.session_id ?? ''}>{o.code} — {xof(o.solde)}</option>)}</Select></Field>
      <Field label="Montant (F)" hint={`Solde de ${e.code} : ${xof(e.solde)}`}><Input type="number" min={1} value={f.montant} onChange={(ev) => setF({ ...f, montant: ev.target.value })} required autoFocus /></Field>
      <Field label="Motif"><Input value={f.motif} onChange={(ev) => setF({ ...f, motif: ev.target.value })} placeholder="ex. approvisionnement du guichet" /></Field>
    </FormModal>
  )
}

function Plafond({ e, onClose, onFait }: { e: Etat; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ libelle: e.libelle ?? '', plafond: e.plafond === null ? '' : String(e.plafond) })
  return (
    <FormModal titre={`Caisse ${e.code}`} onClose={onClose} busy={busy} valider="Enregistrer"
      onSubmit={() => void run(() => api.patch(`/api/caisses/${e.caisse_id}`, { libelle: f.libelle || null, plafond: f.plafond === '' ? null : Number(f.plafond) }), 'Caisse modifiée', onFait)}>
      <Field label="Libellé"><Input value={f.libelle} onChange={(ev) => setF({ ...f, libelle: ev.target.value })} /></Field>
      <Field label="Plafond (F)" hint="Au-delà, l'excédent est à reverser en banque ou au coffre. Vide : aucun plafond."><Input type="number" min={0} value={f.plafond} onChange={(ev) => setF({ ...f, plafond: ev.target.value })} /></Field>
    </FormModal>
  )
}

function Banques({ jour }: { jour: string }) {
  const { can } = useSession()
  const q = useFetch(() => api.get<Banque[]>('/api/banques'), [])
  const [modale, setModale] = useState<null | 'nouveau' | { type: 'mouvement' | 'liste' | 'caisse'; b: Banque }>(null)
  const fin = () => { setModale(null); q.reload() }
  return (
    <Card flush actions={can('tresorerie:write') && <Button variant="primary" onClick={() => setModale('nouveau')}>Nouveau compte bancaire</Button>}>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucun compte bancaire" cols={[
            { titre: 'Compte', render: (b) => <><strong>{b.code}</strong><div className="muted">{b.libelle}{b.banque ? ` — ${b.banque}` : ''}</div></> },
            { titre: 'Solde', num: true, render: (b) => <strong>{xof(b.solde)}</strong> },
            { titre: 'Non rapprochés', num: true, render: (b) => (b.non_rapproches ? <Badge tone="warn">{b.non_rapproches}</Badge> : '0') },
            { titre: '', render: (b) => (
              <span className="actions">
                <Button small onClick={() => setModale({ type: 'liste', b })}>Mouvements</Button>
                {can('caisse:write') && <Button small onClick={() => setModale({ type: 'caisse', b })}>Versement / retrait</Button>}
                {can('tresorerie:write') && <Button small onClick={() => setModale({ type: 'mouvement', b })}>Autre mouvement</Button>}
              </span>
            ) },
          ]} />
        )}
      </Charge>
      {modale === 'nouveau' && <NouvelleBanque onClose={() => setModale(null)} onFait={fin} />}
      {modale && typeof modale === 'object' && modale.type === 'liste' && <Mouvements b={modale.b} onClose={fin} />}
      {modale && typeof modale === 'object' && modale.type === 'mouvement' && <MouvementExterne b={modale.b} jour={jour} onClose={() => setModale(null)} onFait={fin} />}
      {modale && typeof modale === 'object' && modale.type === 'caisse' && <OperationCaisse b={modale.b} jour={jour} onClose={() => setModale(null)} onFait={fin} />}
    </Card>
  )
}

function NouvelleBanque({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ code: '', libelle: '', banque: '', numero: '' })
  const maj = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  return (
    <FormModal titre="Nouveau compte bancaire" onClose={onClose} busy={busy} valider="Créer"
      onSubmit={() => void run(() => api.post('/api/banques', { code: f.code, libelle: f.libelle, banque: f.banque || null, numero_compte: f.numero || null }), 'Compte créé', onFait)}>
      <Field label="Code"><Input value={f.code} maxLength={10} onChange={maj('code')} required autoFocus /></Field>
      <Field label="Libellé"><Input value={f.libelle} onChange={maj('libelle')} required /></Field>
      <Field label="Banque"><Input value={f.banque} onChange={maj('banque')} /></Field>
      <Field label="Numéro de compte"><Input value={f.numero} onChange={maj('numero')} /></Field>
    </FormModal>
  )
}

function Mouvements({ b, onClose }: { b: Banque; onClose: () => void }) {
  const { can } = useSession()
  const q = useFetch(() => api.get<MvtBanque[]>(`/api/banques/${b.id}/mouvements`), [b.id])
  const { run, busy } = useAction()
  return (
    <FormModal titre={`Mouvements — ${b.code}`} onClose={onClose} onSubmit={onClose} valider="Fermer" large>
      <div style={{ gridColumn: '1 / -1' }}>
        <Charge q={q}>
          {(rows) => (
            <Table rows={rows} vide="Aucun mouvement" cols={[
              { titre: 'Date', render: (m) => fdate(m.date_operation) },
              { titre: 'Opération', render: (m) => <>{TYPES_MVT[m.type]}{m.libelle && <div className="muted">{m.libelle}</div>}</> },
              { titre: 'Montant', num: true, render: (m) => (m.sens > 0 ? '+ ' : '− ') + xof(m.montant) },
              { titre: 'Rapproché', render: (m) => (can('tresorerie:write')
                ? <input type="checkbox" aria-label="Rapproché" checked={m.rapproche} disabled={busy} onChange={(e) => void run(() => api.post(`/api/banques/mouvements/${m.id}/rapprocher`, { rapproche: e.target.checked }), undefined, q.reload)} />
                : m.rapproche ? 'Oui' : 'Non') },
            ]} />
          )}
        </Charge>
      </div>
    </FormModal>
  )
}

function MouvementExterne({ b, jour, onClose, onFait }: { b: Banque; jour: string; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ type: 'depot_externe', montant: '', libelle: '' })
  return (
    <FormModal titre={`Autre mouvement — ${b.code}`} onClose={onClose} busy={busy} valider="Enregistrer"
      onSubmit={() => void run(() => api.post(`/api/banques/${b.id}/mouvements`, { type: f.type, montant: Number(f.montant), date: jour, libelle: f.libelle || null }), 'Mouvement enregistré', onFait)}>
      <Field label="Nature"><Select value={f.type} onChange={(e) => setF({ ...f, type: e.target.value })}><option value="depot_externe">Dépôt externe (refinancement…)</option><option value="retrait_externe">Retrait externe</option><option value="frais">Frais bancaires</option><option value="interets">Intérêts</option></Select></Field>
      <Field label="Montant (F)" hint={`Solde : ${xof(b.solde)}`}><Input type="number" min={1} value={f.montant} onChange={(e) => setF({ ...f, montant: e.target.value })} required autoFocus /></Field>
      <Field label="Libellé"><Input value={f.libelle} onChange={(e) => setF({ ...f, libelle: e.target.value })} /></Field>
    </FormModal>
  )
}

function OperationCaisse({ b, jour, onClose, onFait }: { b: Banque; jour: string; onClose: () => void; onFait: () => void }) {
  const etat = useFetch(() => api.get<Etat[]>('/api/caisses/etat', { date: jour }), [jour])
  const { run, busy } = useAction()
  const [f, setF] = useState({ sens: 'versement', session: '', montant: '' })
  const ouvertes = (etat.data ?? []).filter((c) => c.etat === 'ouverte')
  return (
    <FormModal titre={`Caisse ↔ ${b.code}`} onClose={onClose} busy={busy} valider="Enregistrer"
      onSubmit={() => void run(() => api.post(`/api/sessions/${f.session}/${f.sens === 'versement' ? 'versement-banque' : 'retrait-banque'}`, { compte_banque_id: b.id, montant: Number(f.montant), date: jour }), 'Opération enregistrée', onFait)}>
      <Field label="Sens"><Select value={f.sens} onChange={(e) => setF({ ...f, sens: e.target.value })}><option value="versement">Versement de la caisse en banque</option><option value="retrait">Retrait en banque pour la caisse</option></Select></Field>
      <Field label="Caisse (session ouverte)"><Select value={f.session} onChange={(e) => setF({ ...f, session: e.target.value })} required><option value="">— choisir —</option>{ouvertes.map((c) => <option key={c.caisse_id} value={c.session_id ?? ''}>{c.code} — {xof(c.solde)}</option>)}</Select></Field>
      <Field label="Montant (F)" hint={f.sens === 'retrait' ? `Solde bancaire : ${xof(b.solde)}` : undefined}><Input type="number" min={1} value={f.montant} onChange={(e) => setF({ ...f, montant: e.target.value })} required autoFocus /></Field>
    </FormModal>
  )
}

function Prevision({ jour }: { jour: string }) {
  const [jours, setJours] = useState('60')
  const [pas, setPas] = useState('7')
  const q = useFetch(() => api.get<Tranche[]>('/api/tresorerie/prevision', { date: jour, jours: Number(jours), pas: Number(pas) }), [jour, jours, pas])
  return (
    <div className="stack">
      <Card><div className="row">
        <Field label="Horizon (jours)"><Select value={jours} onChange={(e) => setJours(e.target.value)}><option value="30">30</option><option value="60">60</option><option value="90">90</option></Select></Field>
        <Field label="Tranches (jours)"><Select value={pas} onChange={(e) => setPas(e.target.value)}><option value="7">7</option><option value="15">15</option><option value="30">30</option></Select></Field>
      </div></Card>
      <Card title="Solde projeté" flush>
        <Charge q={q}>
          {(rows) => (
            <Table rows={rows} cols={[
              { titre: 'Période', render: (t) => `${fdate(t.debut)} → ${fdate(t.fin)}` },
              { titre: 'Encaissements attendus', num: true, render: (t) => xof(t.encaissements) },
              { titre: 'Décaissements prévus', num: true, render: (t) => xof(t.decaissements) },
              { titre: 'Solde projeté', num: true, render: (t) => <strong>{xof(t.solde_projete)}</strong> },
            ]} />
          )}
        </Charge>
      </Card>
      <Alert tone="info">Encaissements = échéances de crédit impayées attendues dans la tranche ; décaissements = retraits clients en attente. Salaires, charges et collecte à venir ne sont pas prévus ici.</Alert>
    </div>
  )
}
