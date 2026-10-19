import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Button, Card, Charge, Field, FormModal, Input, Page, Select, Statut, Table, Tabs, useAction, useFetch } from '../components/ui'

interface Demande {
  id: number; numero: string; client: string; produit: string; montant: number; nb_echeances: number; taux: number
  garantie_montant: number; mode_remboursement: string; statut: string; date_demande: string; note: string | null
}
interface Credit { id: number; numero: string; client: string; type: string; mode_remboursement: string; montant_accorde: number; capital_restant: number; prochaine_echeance: string | null; statut: string }
interface Session { id: number; caisse: string; date_session: string; solde_theorique: number }
interface Echu { credit: string; client: string; no_echeance: number; date_prevue: string; jours_retard: number; du: number; penalite: number }
interface AVenir { credit: string; client: string; no_echeance: number; date_prevue: string; du: number; mode_remboursement: string }

const MODES: Record<string, string> = { prelevement_compte: 'Prélèvement', especes: 'Espèces', tontine: 'Tontine' }

export default function Credits() {
  const { agenceId, can } = useSession()
  const nav = useNavigate()
  const [onglet, setOnglet] = useState('demandes')
  return (
    <Page title="Crédits" subtitle="Demandes, décisions, déblocages et suivi des remboursements">
      <Tabs actif={onglet} onChange={setOnglet} tabs={[{ id: 'demandes', titre: 'Demandes' }, { id: 'credits', titre: 'Crédits' }, { id: 'echeances', titre: 'Échéances' }, ...(can('taches:run') ? [{ id: 'taches', titre: 'Traitements du jour' }] : [])]} />
      {onglet === 'demandes' && <Demandes key={agenceId} />}
      {onglet === 'credits' && <Credits_ key={agenceId} ouvrir={(id) => nav(`/credits/${id}`)} />}
      {onglet === 'echeances' && <Echeances key={agenceId} />}
      {onglet === 'taches' && <Taches key={agenceId} />}
    </Page>
  )
}

function Demandes() {
  const { can } = useSession()
  const [statut, setStatut] = useState('')
  const q = useFetch(() => api.get<Demande[]>('/api/demandes-credit', { statut }), [statut])
  const [modale, setModale] = useState<null | { type: 'decision' | 'debloquer'; d: Demande }>(null)
  const fin = () => { setModale(null); q.reload() }
  return (
    <Card flush>
      <div className="card-b row">
        <Field label="Statut">
          <Select value={statut} onChange={(e) => setStatut(e.target.value)}>
            <option value="">Toutes</option><option value="demandee">À décider</option><option value="approuvee">Approuvées (à débloquer)</option>
            <option value="debloquee">Débloquées</option><option value="refusee">Refusées</option>
          </Select>
        </Field>
        <span className="muted">Les demandes se déposent depuis la fiche du client.</span>
      </div>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucune demande" cols={[
            { titre: 'N°', render: (d) => d.numero },
            { titre: 'Client', render: (d) => <><strong>{d.client}</strong><div className="muted">{d.produit}</div></> },
            { titre: 'Montant', num: true, render: (d) => xof(d.montant) },
            { titre: 'Échéances', num: true, render: (d) => d.nb_echeances },
            { titre: 'Taux', num: true, render: (d) => `${Math.round(d.taux * 1000) / 10} %` },
            { titre: 'Garantie', num: true, render: (d) => (d.garantie_montant ? xof(d.garantie_montant) : '—') },
            { titre: 'Remb.', render: (d) => MODES[d.mode_remboursement] },
            { titre: 'Statut', render: (d) => <Statut s={d.statut} /> },
            { titre: '', render: (d) => (
              <span className="actions">
                {d.statut === 'demandee' && can('credit:approve') && <Button small variant="primary" onClick={() => setModale({ type: 'decision', d })}>Décider</Button>}
                {d.statut === 'approuvee' && can('credit:disburse') && <Button small variant="primary" onClick={() => setModale({ type: 'debloquer', d })}>Débloquer</Button>}
              </span>
            ) },
          ]} />
        )}
      </Charge>
      {modale?.type === 'decision' && <Decision d={modale.d} onClose={() => setModale(null)} onFait={fin} />}
      {modale?.type === 'debloquer' && <Deblocage d={modale.d} onClose={() => setModale(null)} onFait={fin} />}
    </Card>
  )
}

function Decision({ d, onClose, onFait }: { d: Demande; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [com, setCom] = useState('')
  const decider = (approuve: boolean) => void run(() => api.post(`/api/demandes-credit/${d.id}/decision`, { approuve, commentaire: com || null }), approuve ? 'Demande approuvée' : 'Demande refusée', onFait)
  return (
    <FormModal titre={`Décision — ${d.client}`} onClose={onClose} busy={busy} valider="Approuver" onSubmit={() => decider(true)}>
      <div style={{ gridColumn: '1 / -1' }}>
        <Alert tone="info">{xof(d.montant)} sur {d.nb_echeances} échéances à {Math.round(d.taux * 1000) / 10} % — garantie négociée : {xof(d.garantie_montant)}.</Alert>
      </div>
      <Field label="Commentaire"><Input value={com} onChange={(e) => setCom(e.target.value)} /></Field>
      <div className="actions" style={{ alignSelf: 'end' }}><Button variant="danger" disabled={busy} onClick={() => decider(false)}>Refuser la demande</Button></div>
    </FormModal>
  )
}

function Deblocage({ d, onClose, onFait }: { d: Demande; onClose: () => void; onFait: () => void }) {
  const sessions = useFetch(() => api.get<Session[]>('/api/sessions', { statut: 'ouverte' }), [])
  const { run, busy } = useAction()
  const [f, setF] = useState({ mode: d.mode_remboursement === 'prelevement_compte' ? 'compte' : 'especes', date: aujourdhui(), session: '' })
  const maj = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  return (
    <FormModal titre={`Débloquer le crédit — ${d.client}`} onClose={onClose} busy={busy} valider="Débloquer"
      onSubmit={() => void run(() => api.post(`/api/demandes-credit/${d.id}/debloquer`, { mode: f.mode, date: f.date, session_id: f.session ? Number(f.session) : null }), 'Crédit débloqué', onFait)}>
      <Field label="Décaissement">
        <Select value={f.mode} onChange={maj('mode')}><option value="compte">Sur le compte d'épargne</option><option value="especes">En espèces (caisse)</option></Select>
      </Field>
      <Field label="Date de déblocage"><Input type="date" value={f.date} onChange={maj('date')} required /></Field>
      {f.mode === 'especes' && (
        <Field label="Session de caisse">
          <Select value={f.session} onChange={maj('session')} required>
            <option value="">— choisir —</option>
            {(sessions.data ?? []).map((s) => <option key={s.id} value={s.id}>{s.caisse} · {fdate(s.date_session)} · {xof(s.solde_theorique)}</option>)}
          </Select>
        </Field>
      )}
      <div style={{ gridColumn: '1 / -1' }}><Alert tone="info">{xof(d.montant)} seront décaissés ; les frais de dossier sont prélevés selon le produit{d.garantie_montant ? ` ; ${xof(d.garantie_montant)} de garantie seront bloqués sur le compte` : ''}.</Alert></div>
    </FormModal>
  )
}

function Credits_({ ouvrir }: { ouvrir: (id: number) => void }) {
  const [statut, setStatut] = useState('')
  const q = useFetch(() => api.get<Credit[]>('/api/credits', { statut, limit: 300 }), [statut])
  return (
    <Card flush>
      <div className="card-b row">
        <Field label="Statut"><Select value={statut} onChange={(e) => setStatut(e.target.value)}><option value="">Tous</option><option value="en_cours">En cours</option><option value="en_retard">En retard</option><option value="solde">Soldés</option></Select></Field>
      </div>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} onRowClick={(c) => ouvrir(c.id)} vide="Aucun crédit" cols={[
            { titre: 'Crédit', render: (c) => <strong>{c.numero}</strong> },
            { titre: 'Client', render: (c) => c.client },
            { titre: 'Type', render: (c) => (c.type === 'sur_epargne' ? 'Sur épargne' : 'Sans épargne') },
            { titre: 'Remb.', render: (c) => MODES[c.mode_remboursement] },
            { titre: 'Accordé', num: true, render: (c) => xof(c.montant_accorde) },
            { titre: 'Capital restant', num: true, render: (c) => xof(c.capital_restant) },
            { titre: 'Prochaine échéance', render: (c) => fdate(c.prochaine_echeance) },
            { titre: 'Statut', render: (c) => <Statut s={c.statut} /> },
          ]} />
        )}
      </Charge>
    </Card>
  )
}

function Echeances() {
  const [jour, setJour] = useState(aujourdhui())
  const echus = useFetch(() => api.get<Echu[]>('/api/rapports/credits/echus', { date: jour }), [jour])
  const avenir = useFetch(() => api.get<AVenir[]>('/api/rapports/credits/a-venir', { date: jour, jours: 7 }), [jour])
  return (
    <div className="stack">
      <Card><div className="row"><Field label="Situation au"><Input type="date" value={jour} onChange={(e) => setJour(e.target.value || aujourdhui())} /></Field></div></Card>
      <Card title="Remboursements échus (impayés)" flush>
        <Charge q={echus}>
          {(rows) => (
            <Table rows={rows} vide="Aucune échéance en retard" cols={[
              { titre: 'Client', render: (r) => <><strong>{r.client}</strong><div className="muted">{r.credit} · éch. {r.no_echeance}</div></> },
              { titre: 'Échéance', render: (r) => fdate(r.date_prevue) },
              { titre: 'Retard', num: true, render: (r) => `${r.jours_retard} j` },
              { titre: 'Dû', num: true, render: (r) => xof(r.du) },
              { titre: 'Pénalité', num: true, render: (r) => xof(r.penalite) },
            ]} />
          )}
        </Charge>
      </Card>
      <Card title="À venir dans les 7 jours" flush>
        <Charge q={avenir}>
          {(rows) => (
            <Table rows={rows} vide="Aucune échéance à venir" cols={[
              { titre: 'Client', render: (r) => <><strong>{r.client}</strong><div className="muted">{r.credit} · éch. {r.no_echeance}</div></> },
              { titre: 'Échéance', render: (r) => fdate(r.date_prevue) },
              { titre: 'Mode', render: (r) => MODES[r.mode_remboursement] },
              { titre: 'Dû', num: true, render: (r) => xof(r.du) },
            ]} />
          )}
        </Charge>
      </Card>
    </div>
  )
}

function Taches() {
  const { run, busy } = useAction()
  const [jour, setJour] = useState(aujourdhui())
  const [resultat, setResultat] = useState<string | null>(null)
  const lancer = (nom: string, titre: string) => void run(async () => {
    const r = await api.post<Record<string, number>>(`/api/taches/${nom}`, { date: jour })
    setResultat(`${titre} : ${Object.entries(r).map(([k, v]) => `${v} ${k.replace(/_/g, ' ')}`).join(', ')}`)
  }, `${titre} terminé`)
  return (
    <Card title="Traitements du jour">
      <div className="stack">
        <p className="muted" style={{ margin: 0 }}>Ces traitements se lancent chaque jour pour l'agence (normalement par un planificateur). Ils sont rejouables pour une date donnée.</p>
        <div className="row"><Field label="Date de traitement"><Input type="date" value={jour} onChange={(e) => setJour(e.target.value || aujourdhui())} /></Field></div>
        <div className="actions">
          <Button disabled={busy} onClick={() => lancer('prelever-echeances', 'Prélèvements automatiques')}>Prélever les échéances</Button>
          <Button disabled={busy} onClick={() => lancer('maj-statuts-credit', 'Mise à jour des retards')}>Mettre à jour les retards et pénalités</Button>
          <Button disabled={busy} onClick={() => lancer('saisir-garanties', 'Saisie des garanties')}>Saisir les garanties</Button>
        </div>
        {resultat && <Alert tone="info">{resultat}</Alert>}
      </div>
    </Card>
  )
}
