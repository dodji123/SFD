import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Modal, Select, Table, Tabs, useAction, useFetch } from '../components/ui'

interface Formation { id: number; code: string; titre: string; organisme: string | null; duree_heures: number; cout_unitaire: number; nb_sessions: number }
interface Session { id: number; formation_id: number; titre: string; date_debut: string; date_fin: string; lieu: string | null; capacite: number; inscrits: number; statut: string }
interface Participant { employe_id: number; matricule: string; nom: string; statut: string; note: number | null; certificat_ref: string | null }
interface Emp { id: number; matricule: string; nom: string; statut: string }
interface Campagne { id: number; libelle: string; periode_debut: string; periode_fin: string; statut: string; nb: number; validees: number }
interface Evaluation { id: number; matricule: string; nom: string; evaluateur: string; statut: string; note_globale: number | null; decision: string | null; points_forts?: string | null; axes_progres?: string | null }
interface Objectif { id: number; libelle: string; poids: number; note: number | null }
interface EvaluationDetail extends Evaluation { objectifs: Objectif[]; note_calculee: number | null }

export default function GrhFormation() {
  const [vue, setVue] = useState('sessions')
  return (
    <div className="stack">
      <Tabs actif={vue} onChange={setVue} tabs={[{ id: 'sessions', titre: 'Sessions de formation' }, { id: 'catalogue', titre: 'Catalogue' }, { id: 'evaluations', titre: 'Évaluations de performance' }]} />
      {vue === 'sessions' && <Sessions />}
      {vue === 'catalogue' && <Catalogue />}
      {vue === 'evaluations' && <Evaluations />}
    </div>
  )
}

function Catalogue() {
  const { can } = useSession()
  const q = useFetch(() => api.get<Formation[]>('/api/grh/formations'), [])
  const { run, busy } = useAction()
  const [nouveau, setNouveau] = useState(false)
  const [f, setF] = useState({ code: '', titre: '', organisme: '', heures: '8', cout: '0' })
  return (
    <Card flush actions={can('grh:write') && <Button variant="primary" onClick={() => setNouveau(true)}>Nouvelle formation</Button>}>
      <Charge q={q}>
        {(rows) => <Table rows={rows} vide="Aucune formation" cols={[
          { titre: 'Code', render: (x) => <strong>{x.code}</strong> }, { titre: 'Titre', render: (x) => x.titre }, { titre: 'Organisme', render: (x) => x.organisme ?? '—' },
          { titre: 'Durée', num: true, render: (x) => `${x.duree_heures} h` }, { titre: 'Coût par participant', num: true, render: (x) => xof(x.cout_unitaire) }, { titre: 'Sessions', num: true, render: (x) => x.nb_sessions },
        ]} />}
      </Charge>
      {nouveau && (
        <FormModal titre="Nouvelle formation" onClose={() => setNouveau(false)} busy={busy}
          onSubmit={() => void run(() => api.post('/api/grh/formations', { code: f.code, titre: f.titre, organisme: f.organisme || null, duree_heures: Number(f.heures), cout_unitaire: Number(f.cout) }), 'Formation créée', () => { setNouveau(false); q.reload() })}>
          <Field label="Code"><Input value={f.code} maxLength={15} onChange={(e) => setF({ ...f, code: e.target.value })} required autoFocus /></Field>
          <Field label="Titre"><Input value={f.titre} onChange={(e) => setF({ ...f, titre: e.target.value })} required /></Field>
          <Field label="Organisme"><Input value={f.organisme} onChange={(e) => setF({ ...f, organisme: e.target.value })} /></Field>
          <Field label="Durée (heures)"><Input type="number" min={1} step="0.5" value={f.heures} onChange={(e) => setF({ ...f, heures: e.target.value })} required /></Field>
          <Field label="Coût par participant"><Input type="number" min={0} value={f.cout} onChange={(e) => setF({ ...f, cout: e.target.value })} /></Field>
        </FormModal>
      )}
    </Card>
  )
}

function Sessions() {
  const { can } = useSession()
  const q = useFetch(() => api.get<Session[]>('/api/grh/sessions-formation'), [])
  const formations = useFetch(() => api.get<Formation[]>('/api/grh/formations'), [])
  const { run, busy } = useAction()
  const [nouveau, setNouveau] = useState(false)
  const [ouvert, setOuvert] = useState<Session | null>(null)
  const [f, setF] = useState({ formation_id: '', debut: aujourdhui(), fin: aujourdhui(), lieu: '', capacite: '20' })
  return (
    <Card flush actions={can('grh:write') && <Button variant="primary" onClick={() => setNouveau(true)}>Planifier une session</Button>}>
      <Charge q={q}>
        {(rows) => <Table rows={rows} vide="Aucune session" onRowClick={(s) => setOuvert(s)} cols={[
          { titre: 'Formation', render: (s) => <strong>{s.titre}</strong> }, { titre: 'Dates', render: (s) => `${fdate(s.date_debut)} → ${fdate(s.date_fin)}` }, { titre: 'Lieu', render: (s) => s.lieu ?? '—' },
          { titre: 'Inscrits', num: true, render: (s) => `${s.inscrits} / ${s.capacite}` }, { titre: 'Statut', render: (s) => <Badge tone={s.statut === 'realisee' ? 'ok' : s.statut === 'annulee' ? 'bad' : 'info'}>{s.statut}</Badge> },
        ]} />}
      </Charge>
      {nouveau && (
        <FormModal titre="Planifier une session" onClose={() => setNouveau(false)} busy={busy}
          onSubmit={() => void run(() => api.post('/api/grh/sessions-formation', { formation_id: Number(f.formation_id), date_debut: f.debut, date_fin: f.fin, lieu: f.lieu || null, capacite: Number(f.capacite) }), 'Session planifiée', () => { setNouveau(false); q.reload() })}>
          <Field label="Formation"><Select value={f.formation_id} onChange={(e) => setF({ ...f, formation_id: e.target.value })} required><option value="">— choisir —</option>{formations.data?.map((x) => <option key={x.id} value={x.id}>{x.code} — {x.titre}</option>)}</Select></Field>
          <Field label="Début"><Input type="date" value={f.debut} onChange={(e) => setF({ ...f, debut: e.target.value })} required /></Field>
          <Field label="Fin"><Input type="date" value={f.fin} min={f.debut} onChange={(e) => setF({ ...f, fin: e.target.value })} required /></Field>
          <Field label="Lieu"><Input value={f.lieu} onChange={(e) => setF({ ...f, lieu: e.target.value })} /></Field>
          <Field label="Capacité"><Input type="number" min={1} value={f.capacite} onChange={(e) => setF({ ...f, capacite: e.target.value })} required /></Field>
        </FormModal>
      )}
      {ouvert && <Participants session={ouvert} onClose={() => { setOuvert(null); q.reload() }} />}
    </Card>
  )
}

function Participants({ session, onClose }: { session: Session; onClose: () => void }) {
  const { can } = useSession()
  const q = useFetch(() => api.get<Participant[]>(`/api/grh/sessions-formation/${session.id}/participants`), [session.id])
  const emps = useFetch(() => api.get<Emp[]>('/api/employes'), [])
  const { run, busy } = useAction()
  const [choix, setChoix] = useState('')
  const maj = (p: Participant, statut: string) => {
    let certificat: string | null = null
    if (statut === 'valide') { certificat = window.prompt('Référence du certificat (obligatoire) :'); if (!certificat) return }
    void run(() => api.patch(`/api/grh/sessions-formation/${session.id}/participants/${p.employe_id}`, { statut, certificat_ref: certificat }), 'Mis à jour', q.reload)
  }
  return (
    <Modal titre={session.titre} onClose={onClose} large footer={<>
      {can('grh:write') && session.statut === 'planifiee' && <Button disabled={busy} onClick={() => void run(() => api.post(`/api/grh/sessions-formation/${session.id}/cloturer`), 'Session clôturée', onClose)}>Clôturer la session</Button>}
      <Button onClick={onClose}>Fermer</Button></>}>
      <div className="stack">
        {can('grh:write') && session.statut === 'planifiee' && (
          <div className="row" style={{ gap: 8 }}>
            <Select value={choix} onChange={(e) => setChoix(e.target.value)} aria-label="Employé"><option value="">Inscrire un employé…</option>{emps.data?.filter((e) => e.statut === 'actif').map((e) => <option key={e.id} value={e.id}>{e.nom} ({e.matricule})</option>)}</Select>
            <Button variant="primary" disabled={busy || !choix} onClick={() => void run(() => api.post(`/api/grh/sessions-formation/${session.id}/inscrire`, { employe_id: Number(choix) }), 'Inscrit', () => { setChoix(''); q.reload() })}>Inscrire</Button>
          </div>
        )}
        <Charge q={q}>
          {(rows) => <Table rows={rows} vide="Aucun participant" cols={[
            { titre: 'Employé', render: (p) => <span><strong>{p.nom}</strong> <span className="muted">{p.matricule}</span></span> },
            { titre: 'Statut', render: (p) => <Badge tone={p.statut === 'valide' ? 'ok' : p.statut === 'absent' ? 'bad' : 'neutre'}>{p.statut}</Badge> },
            { titre: 'Certificat', render: (p) => p.certificat_ref ?? '' },
            { titre: '', render: (p) => can('grh:write') && p.statut !== 'valide' && (
              <span className="actions"><Button small disabled={busy} onClick={() => maj(p, 'present')}>Présent</Button><Button small disabled={busy} onClick={() => maj(p, 'absent')}>Absent</Button>{p.statut === 'present' && <Button small variant="primary" disabled={busy} onClick={() => maj(p, 'valide')}>Valider</Button>}</span>
            ) },
          ]} />}
        </Charge>
      </div>
    </Modal>
  )
}

/* ------------------------------------------------------------------ évaluations */
function Evaluations() {
  const { can } = useSession()
  const q = useFetch(() => api.get<Campagne[]>('/api/grh/campagnes-evaluation'), [])
  const { run, busy } = useAction()
  const [nouvelle, setNouvelle] = useState(false)
  const [ouverte, setOuverte] = useState<Campagne | null>(null)
  const [f, setF] = useState({ libelle: '', debut: aujourdhui().slice(0, 4) + '-01-01', fin: aujourdhui().slice(0, 4) + '-12-31' })
  return (
    <Card flush actions={can('evaluation:valider') && <Button variant="primary" onClick={() => setNouvelle(true)}>Nouvelle campagne</Button>}>
      <Charge q={q}>
        {(rows) => <Table rows={rows} vide="Aucune campagne" onRowClick={(c) => setOuverte(c)} cols={[
          { titre: 'Campagne', render: (c) => <strong>{c.libelle}</strong> }, { titre: 'Période', render: (c) => `${fdate(c.periode_debut)} → ${fdate(c.periode_fin)}` },
          { titre: 'Évaluations', num: true, render: (c) => `${c.validees} validée(s) / ${c.nb}` }, { titre: 'Statut', render: (c) => <Badge tone={c.statut === 'ouverte' ? 'info' : 'neutre'}>{c.statut}</Badge> },
        ]} />}
      </Charge>
      {nouvelle && (
        <FormModal titre="Nouvelle campagne d'évaluation" onClose={() => setNouvelle(false)} busy={busy}
          onSubmit={() => void run(() => api.post('/api/grh/campagnes-evaluation', { libelle: f.libelle, periode_debut: f.debut, periode_fin: f.fin }), 'Campagne créée', () => { setNouvelle(false); q.reload() })}>
          <Field label="Libellé"><Input value={f.libelle} onChange={(e) => setF({ ...f, libelle: e.target.value })} minLength={3} required autoFocus /></Field>
          <Field label="Début de période"><Input type="date" value={f.debut} onChange={(e) => setF({ ...f, debut: e.target.value })} required /></Field>
          <Field label="Fin de période"><Input type="date" value={f.fin} onChange={(e) => setF({ ...f, fin: e.target.value })} required /></Field>
        </FormModal>
      )}
      {ouverte && <Campagne campagne={ouverte} onClose={() => { setOuverte(null); q.reload() }} />}
    </Card>
  )
}

function Campagne({ campagne, onClose }: { campagne: Campagne; onClose: () => void }) {
  const { can } = useSession()
  const q = useFetch(() => api.get<Evaluation[]>('/api/grh/evaluations', { campagne_id: campagne.id }), [campagne.id])
  const { run, busy } = useAction()
  const [detail, setDetail] = useState<number | null>(null)
  return (
    <Modal titre={campagne.libelle} onClose={onClose} large footer={<>
      {can('evaluation:valider') && campagne.statut === 'ouverte' && <Button disabled={busy} onClick={() => void run(async () => { const r = await api.post<{ evaluations_creees: number; employes_sans_superieur: number }>(`/api/grh/campagnes-evaluation/${campagne.id}/ouvrir`); window.alert(`${r.evaluations_creees} évaluation(s) créée(s). ${r.employes_sans_superieur} employé(s) sans supérieur direct (à renseigner dans les dossiers).`) }, undefined, q.reload)}>Ouvrir les évaluations</Button>}
      {can('evaluation:valider') && campagne.statut === 'ouverte' && <Button variant="danger" disabled={busy} onClick={() => void run(() => api.post(`/api/grh/campagnes-evaluation/${campagne.id}/cloturer`), 'Campagne close', onClose)}>Clôturer la campagne</Button>}
      <Button onClick={onClose}>Fermer</Button></>}>
      <Charge q={q}>
        {(rows) => <Table rows={rows} vide="Aucune évaluation : ouvrez la campagne" onRowClick={(e) => setDetail(e.id)} cols={[
          { titre: 'Employé', render: (e) => <span><strong>{e.nom}</strong> <span className="muted">{e.matricule}</span></span> }, { titre: 'Évaluateur', render: (e) => e.evaluateur },
          { titre: 'Statut', render: (e) => <Badge tone={e.statut === 'validee' ? 'ok' : 'info'}>{e.statut.replace('_', ' ')}</Badge> }, { titre: 'Note', num: true, render: (e) => (e.note_globale !== null ? `${e.note_globale}/10` : '—') }, { titre: 'Décision', render: (e) => e.decision ?? '' },
        ]} />}
      </Charge>
      {detail !== null && <EvaluationModal id={detail} onClose={() => { setDetail(null); q.reload() }} />}
    </Modal>
  )
}

function EvaluationModal({ id, onClose }: { id: number; onClose: () => void }) {
  const { can } = useSession()
  const q = useFetch(() => api.get<EvaluationDetail>(`/api/grh/evaluations/${id}`), [id])
  const { run, busy } = useAction()
  const [obj, setObj] = useState({ libelle: '', poids: '' })
  const [concl, setConcl] = useState({ forts: '', axes: '' })
  const [decision, setDecision] = useState('maintien')
  return (
    <Modal titre="Évaluation de performance" onClose={onClose} large footer={<Button onClick={onClose}>Fermer</Button>}>
      <Charge q={q}>
        {(e) => {
          const total = e.objectifs.reduce((s, o) => s + Number(o.poids), 0)
          const fige = e.statut === 'validee'
          return (
            <div className="stack">
              <div><strong>{e.nom}</strong> <span className="muted">{e.matricule} — évaluateur : {e.evaluateur}</span> <Badge tone={fige ? 'ok' : 'info'}>{e.statut.replace('_', ' ')}</Badge> {e.note_globale !== null && <strong>{e.note_globale}/10</strong>}</div>
              <Table rows={e.objectifs} vide="Aucun objectif : ajoutez-en (poids totalisant 100)" cols={[
                { titre: 'Objectif', render: (o) => o.libelle }, { titre: 'Poids', num: true, render: (o) => `${o.poids} %` },
                { titre: 'Note /10', render: (o) => (fige || !can('evaluation:ecrire') ? (o.note ?? '—') : (
                  <Input type="number" min={0} max={10} step="0.5" defaultValue={o.note ?? ''} style={{ width: 80 }} aria-label={`Note ${o.libelle}`}
                    onBlur={(ev) => { if (ev.target.value !== '') void run(() => api.patch(`/api/grh/objectifs-evaluation/${o.id}`, { note: Number(ev.target.value) }), undefined, q.reload) }} />
                )) },
              ]} />
              {!fige && <p className="muted">Total des poids : {total} % (doit être 100).</p>}
              {!fige && can('evaluation:ecrire') && (
                <div className="row" style={{ gap: 8, flexWrap: 'wrap' }}>
                  <Input placeholder="Nouvel objectif" value={obj.libelle} onChange={(x) => setObj({ ...obj, libelle: x.target.value })} style={{ minWidth: 220 }} />
                  <Input type="number" placeholder="Poids %" min={1} max={100} value={obj.poids} onChange={(x) => setObj({ ...obj, poids: x.target.value })} style={{ width: 100 }} />
                  <Button disabled={busy || !obj.libelle || !obj.poids} onClick={() => void run(() => api.post(`/api/grh/evaluations/${id}/objectifs`, { libelle: obj.libelle, poids: Number(obj.poids) }), 'Objectif ajouté', () => { setObj({ libelle: '', poids: '' }); q.reload() })}>Ajouter</Button>
                </div>
              )}
              {!fige && e.statut !== 'evalue' && can('evaluation:ecrire') && (
                <>
                  <Field label="Points forts"><Input value={concl.forts} onChange={(x) => setConcl({ ...concl, forts: x.target.value })} /></Field>
                  <Field label="Axes de progrès"><Input value={concl.axes} onChange={(x) => setConcl({ ...concl, axes: x.target.value })} /></Field>
                  <div><Button variant="primary" disabled={busy} onClick={() => void run(() => api.post(`/api/grh/evaluations/${id}/evaluer`, { points_forts: concl.forts || null, axes_progres: concl.axes || null }), 'Évaluation terminée : à valider par une autre personne', q.reload)}>Terminer l'évaluation</Button></div>
                </>
              )}
              {e.statut === 'evalue' && can('evaluation:valider') && (
                <div className="row" style={{ gap: 8 }}>
                  <Select value={decision} onChange={(x) => setDecision(x.target.value)} aria-label="Décision">{['maintien', 'augmentation', 'promotion', 'formation', 'alerte'].map((d) => <option key={d} value={d}>{d}</option>)}</Select>
                  <Button variant="primary" disabled={busy} onClick={() => void run(() => api.post(`/api/grh/evaluations/${id}/valider`, { decision }), 'Évaluation validée', q.reload)}>Valider</Button>
                </div>
              )}
              {fige && <Alert tone="info">Évaluation validée : décision « {e.decision} ». Elle est figée.</Alert>}
            </div>
          )
        }}
      </Charge>
    </Modal>
  )
}
