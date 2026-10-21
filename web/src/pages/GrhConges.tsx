import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Select, Table, Tabs, useAction, useFetch } from '../components/ui'

interface Conge { id: number; employe_id: number; matricule: string; nom: string; type: string; date_debut: string; date_fin: string; jours_ouvres: number; statut: string; motif: string | null; decide_par_nom: string | null; commentaire_decision: string | null }
interface Emp { id: number; matricule: string; nom: string; statut: string }
interface PresenceLigne { employe_id: number; matricule: string; nom: string; statut: string | null; heure_arrivee: string | null; heure_depart: string | null; heures: number | null; motif: string | null }
interface Absent { employe_id: number; matricule: string; nom: string; jours_presents: number; absences_injustifiees: number; absences_justifiees: number; retards: number; jours_conge: number }
interface Ferie { id: number; date_jour: string; libelle: string; agence_id: number | null }

const TYPES = ['annuel', 'maladie', 'maternite', 'paternite', 'permission', 'deuil', 'formation', 'sans_solde', 'autre']
const TONE: Record<string, 'ok' | 'warn' | 'bad' | 'neutre'> = { demande: 'warn', approuve: 'ok', refuse: 'bad', annule: 'neutre' }

export default function GrhConges() {
  const { can } = useSession()
  const [vue, setVue] = useState(can('grh:read') ? 'demandes' : 'mes')
  const vues = [
    ...(can('grh:read') ? [{ id: 'demandes', titre: 'Demandes de congé' }, { id: 'presences', titre: 'Présences du jour' }, { id: 'absenteisme', titre: 'Absentéisme' }, { id: 'feries', titre: 'Jours fériés' }] : []),
    { id: 'mes', titre: 'Mes congés' },
  ]
  return (
    <div className="stack">
      <Tabs actif={vue} onChange={setVue} tabs={vues} />
      {vue === 'demandes' && <Demandes />}
      {vue === 'presences' && <Presences />}
      {vue === 'absenteisme' && <Absenteisme />}
      {vue === 'feries' && <Feries />}
      {vue === 'mes' && <MesConges />}
    </div>
  )
}

function Demandes() {
  const { can } = useSession()
  const [statut, setStatut] = useState('demande')
  const q = useFetch(() => api.get<Conge[]>('/api/grh/conges', { statut }), [statut])
  const emps = useFetch(() => api.get<Emp[]>('/api/employes'), [])
  const { run, busy } = useAction()
  const [nouveau, setNouveau] = useState(false)
  const [f, setF] = useState({ employe_id: '', type: 'annuel', debut: aujourdhui(), fin: aujourdhui(), motif: '' })
  const decider = (c: Conge, approuve: boolean) => {
    const commentaire = approuve ? null : window.prompt('Motif du refus (obligatoire) :')
    if (!approuve && !commentaire) return
    void run(() => api.post(`/api/grh/conges/${c.id}/decider`, { approuve, commentaire }), approuve ? 'Congé approuvé' : 'Congé refusé', q.reload)
  }
  return (
    <Card flush actions={
      <span className="row" style={{ gap: 8 }}>
        <Select value={statut} onChange={(e) => setStatut(e.target.value)} aria-label="Statut"><option value="">Tous</option><option value="demande">À décider</option><option value="approuve">Approuvés</option><option value="refuse">Refusés</option><option value="annule">Annulés</option></Select>
        {can('grh:write') && <Button variant="primary" onClick={() => setNouveau(true)}>Saisir une demande</Button>}
      </span>
    }>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucun congé" cols={[
            { titre: 'Employé', render: (c) => <span><strong>{c.nom}</strong> <span className="muted">{c.matricule}</span></span> },
            { titre: 'Type', render: (c) => c.type },
            { titre: 'Période', render: (c) => `${fdate(c.date_debut)} → ${fdate(c.date_fin)}` },
            { titre: 'Jours ouvrés', num: true, render: (c) => c.jours_ouvres },
            { titre: 'Statut', render: (c) => <Badge tone={TONE[c.statut]}>{c.statut}</Badge> },
            { titre: 'Décision', render: (c) => (c.decide_par_nom ? `${c.decide_par_nom}${c.commentaire_decision ? ` — ${c.commentaire_decision}` : ''}` : '') },
            { titre: '', render: (c) => (
              <span className="actions">
                {c.statut === 'demande' && can('conge:decider') && <><Button small variant="primary" disabled={busy} onClick={() => decider(c, true)}>Approuver</Button><Button small variant="danger" disabled={busy} onClick={() => decider(c, false)}>Refuser</Button></>}
                {['demande', 'approuve'].includes(c.statut) && can('grh:write') && <Button small disabled={busy} onClick={() => void run(() => api.post(`/api/grh/conges/${c.id}/annuler`), 'Congé annulé', q.reload)}>Annuler</Button>}
              </span>
            ) },
          ]} />
        )}
      </Charge>
      {nouveau && (
        <FormModal titre="Demande de congé" onClose={() => setNouveau(false)} busy={busy} valider="Enregistrer"
          onSubmit={() => void run(() => api.post('/api/grh/conges', { employe_id: Number(f.employe_id), type: f.type, date_debut: f.debut, date_fin: f.fin, motif: f.motif || null }), 'Demande enregistrée', () => { setNouveau(false); q.reload() })}>
          <Field label="Employé"><Select value={f.employe_id} onChange={(e) => setF({ ...f, employe_id: e.target.value })} required><option value="">— choisir —</option>{emps.data?.filter((e) => e.statut === 'actif').map((e) => <option key={e.id} value={e.id}>{e.nom} ({e.matricule})</option>)}</Select></Field>
          <Field label="Type"><Select value={f.type} onChange={(e) => setF({ ...f, type: e.target.value })}>{TYPES.map((t) => <option key={t} value={t}>{t.replace('_', ' ')}</option>)}</Select></Field>
          <Field label="Du"><Input type="date" value={f.debut} onChange={(e) => setF({ ...f, debut: e.target.value })} required /></Field>
          <Field label="Au"><Input type="date" value={f.fin} min={f.debut} onChange={(e) => setF({ ...f, fin: e.target.value })} required /></Field>
          <Field label="Motif"><Input value={f.motif} onChange={(e) => setF({ ...f, motif: e.target.value })} /></Field>
        </FormModal>
      )}
    </Card>
  )
}

function MesConges() {
  const q = useFetch(() => api.get<{ employe_id: number; solde: { acquis: number; solde: number }; conges: Conge[] }>('/api/grh/mes-conges'), [])
  const { run, busy } = useAction()
  const [nouveau, setNouveau] = useState(false)
  const [f, setF] = useState({ type: 'annuel', debut: aujourdhui(), fin: aujourdhui(), motif: '' })
  return (
    <Card flush actions={<Button variant="primary" onClick={() => setNouveau(true)}>Demander un congé</Button>}>
      <Charge q={q}>
        {(d) => (
          <>
            <Alert tone="info">Solde de congé annuel : <strong>{d.solde.solde} jour(s)</strong> sur {d.solde.acquis} acquis. Votre demande est décidée par votre responsable.</Alert>
            <Table rows={d.conges} vide="Aucun congé" cols={[
              { titre: 'Type', render: (c) => c.type }, { titre: 'Période', render: (c) => `${fdate(c.date_debut)} → ${fdate(c.date_fin)}` },
              { titre: 'Jours', num: true, render: (c) => c.jours_ouvres }, { titre: 'Statut', render: (c) => <Badge tone={TONE[c.statut]}>{c.statut}</Badge> },
            ]} />
          </>
        )}
      </Charge>
      {nouveau && (
        <FormModal titre="Demander un congé" onClose={() => setNouveau(false)} busy={busy} valider="Envoyer la demande"
          onSubmit={() => void run(() => api.post('/api/grh/mes-conges', { type: f.type, date_debut: f.debut, date_fin: f.fin, motif: f.motif || null }), 'Demande envoyée', () => { setNouveau(false); q.reload() })}>
          <Field label="Type"><Select value={f.type} onChange={(e) => setF({ ...f, type: e.target.value })}>{['annuel', 'maladie', 'permission', 'deuil', 'sans_solde', 'autre'].map((t) => <option key={t} value={t}>{t.replace('_', ' ')}</option>)}</Select></Field>
          <Field label="Du"><Input type="date" value={f.debut} onChange={(e) => setF({ ...f, debut: e.target.value })} required /></Field>
          <Field label="Au"><Input type="date" value={f.fin} min={f.debut} onChange={(e) => setF({ ...f, fin: e.target.value })} required /></Field>
          <Field label="Motif"><Input value={f.motif} onChange={(e) => setF({ ...f, motif: e.target.value })} /></Field>
        </FormModal>
      )}
    </Card>
  )
}

function Presences() {
  const { can } = useSession()
  const [jour, setJour] = useState(aujourdhui())
  const q = useFetch(() => api.get<PresenceLigne[]>('/api/grh/presences', { date: jour }), [jour])
  const { run, busy } = useAction()
  const marquer = (e: PresenceLigne, statut: string) => void run(() => api.post('/api/grh/presences', { employe_id: e.employe_id, date_jour: jour, statut }), 'Pointage enregistré', q.reload)
  return (
    <Card flush actions={<Input type="date" max={aujourdhui()} value={jour} onChange={(e) => setJour(e.target.value || aujourdhui())} aria-label="Jour" />}>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucun employé" cols={[
            { titre: 'Employé', render: (e) => <span><strong>{e.nom}</strong> <span className="muted">{e.matricule}</span></span> },
            { titre: 'Pointage', render: (e) => (e.statut ? <Badge tone={e.statut === 'present' ? 'ok' : e.statut === 'absent' ? 'bad' : 'warn'}>{e.statut.replace('_', ' ')}</Badge> : <span className="muted">non pointé</span>) },
            { titre: 'Heures', num: true, render: (e) => e.heures ?? '' },
            { titre: '', render: (e) => can('conge:decider') && (
              <span className="actions">
                {[['present', 'Présent'], ['retard', 'Retard'], ['absent', 'Absent'], ['absent_justifie', 'Justifié']].map(([s, l]) => <Button key={s} small disabled={busy || e.statut === 'conge'} onClick={() => marquer(e, s)}>{l}</Button>)}
              </span>
            ) },
          ]} />
        )}
      </Charge>
    </Card>
  )
}

function Absenteisme() {
  const [mois, setMois] = useState(aujourdhui().slice(0, 7) + '-01')
  const q = useFetch(() => api.get<Absent[]>('/api/grh/absenteisme', { mois }), [mois])
  return (
    <Card flush actions={<Input type="month" value={mois.slice(0, 7)} onChange={(e) => setMois((e.target.value || aujourdhui().slice(0, 7)) + '-01')} aria-label="Mois" />}>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucun pointage ce mois" cols={[
            { titre: 'Employé', render: (e) => <span><strong>{e.nom}</strong> <span className="muted">{e.matricule}</span></span> },
            { titre: 'Jours présents', num: true, render: (e) => e.jours_presents }, { titre: 'Retards', num: true, render: (e) => e.retards },
            { titre: 'Absences justifiées', num: true, render: (e) => e.absences_justifiees }, { titre: 'Absences injustifiées', num: true, render: (e) => e.absences_injustifiees },
            { titre: 'Jours de congé', num: true, render: (e) => e.jours_conge },
          ]} />
        )}
      </Charge>
    </Card>
  )
}

function Feries() {
  const { can } = useSession()
  const q = useFetch(() => api.get<Ferie[]>('/api/grh/jours-feries'), [])
  const { run, busy } = useAction()
  const [nouveau, setNouveau] = useState(false)
  const [f, setF] = useState({ date_jour: aujourdhui(), libelle: '' })
  return (
    <Card flush actions={can('grh:write') && <Button variant="primary" onClick={() => setNouveau(true)}>Ajouter un jour férié</Button>}>
      <Alert tone="info">Les jours fériés ne comptent pas dans les jours de congé. Les samedis et dimanches non plus.</Alert>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucun jour férié enregistré" cols={[
            { titre: 'Date', render: (x) => fdate(x.date_jour) }, { titre: 'Libellé', render: (x) => x.libelle },
            { titre: '', render: (x) => can('grh:write') && <Button small variant="danger" disabled={busy} onClick={() => void run(() => api.del(`/api/grh/jours-feries/${x.id}`), 'Supprimé', q.reload)}>Supprimer</Button> },
          ]} />
        )}
      </Charge>
      {nouveau && (
        <FormModal titre="Jour férié" onClose={() => setNouveau(false)} busy={busy} onSubmit={() => void run(() => api.post('/api/grh/jours-feries', f), 'Jour férié ajouté', () => { setNouveau(false); q.reload() })}>
          <Field label="Date"><Input type="date" value={f.date_jour} onChange={(e) => setF({ ...f, date_jour: e.target.value })} required /></Field>
          <Field label="Libellé"><Input value={f.libelle} onChange={(e) => setF({ ...f, libelle: e.target.value })} required minLength={2} /></Field>
        </FormModal>
      )}
    </Card>
  )
}
