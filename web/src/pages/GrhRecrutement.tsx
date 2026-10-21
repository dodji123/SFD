import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Modal, Select, Table, useAction, useFetch } from '../components/ui'

interface Besoin { besoin_id: number; poste: string; nb_postes: number; statut: string; candidatures: number; retenues: number; embauches: number; motif: string; date_souhaitee: string | null; commentaire: string | null }
interface Poste { id: number; code: string; libelle: string }
interface Candidature { id: number; nom: string; telephone: string | null; email: string | null; statut: string; meilleure_note: number | null; nb_entretiens: number; motif_refus: string | null }
interface Candidat { id: number; nom: string; telephone: string | null; email: string | null }

const TONE: Record<string, 'ok' | 'warn' | 'bad' | 'info' | 'neutre'> = { soumis: 'warn', approuve: 'info', refuse: 'bad', pourvu: 'ok', annule: 'neutre', retenue: 'ok', embauchee: 'ok', refusee: 'bad' }

export default function GrhRecrutement() {
  const { can } = useSession()
  const q = useFetch(() => api.get<Besoin[]>('/api/grh/besoins'), [])
  const postes = useFetch(() => api.get<Poste[]>('/api/grh/postes'), [])
  const { run, busy } = useAction()
  const [nouveau, setNouveau] = useState(false)
  const [ouvert, setOuvert] = useState<Besoin | null>(null)
  const [f, setF] = useState({ poste_id: '', motif: '', nb: '1' })
  const decider = (b: Besoin, approuve: boolean) => {
    const commentaire = approuve ? null : window.prompt('Motif du refus (obligatoire) :')
    if (!approuve && !commentaire) return
    void run(() => api.post(`/api/grh/besoins/${b.besoin_id}/decider`, { approuve, commentaire }), approuve ? 'Besoin approuvé' : 'Besoin refusé', q.reload)
  }
  return (
    <Card flush actions={can('grh:write') && <Button variant="primary" onClick={() => setNouveau(true)}>Nouveau besoin</Button>}>
      <Alert tone="info">Un besoin est décidé par une autre personne que son demandeur. Les candidatures ne s'ouvrent que sur un besoin approuvé ; un candidat n'est retenu qu'après un entretien favorable.</Alert>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucun besoin de recrutement" onRowClick={(b) => setOuvert(b)} cols={[
            { titre: 'Poste', render: (b) => <strong>{b.poste}</strong> },
            { titre: 'Postes', num: true, render: (b) => b.nb_postes },
            { titre: 'Motif', render: (b) => b.motif },
            { titre: 'Candidatures', num: true, render: (b) => `${b.candidatures} (${b.retenues} retenue(s), ${b.embauches} embauchée(s))` },
            { titre: 'Statut', render: (b) => <Badge tone={TONE[b.statut]}>{b.statut}</Badge> },
            { titre: '', render: (b) => b.statut === 'soumis' && can('recrutement:decider') && (
              <span className="actions" onClick={(e) => e.stopPropagation()}>
                <Button small variant="primary" disabled={busy} onClick={() => decider(b, true)}>Approuver</Button><Button small variant="danger" disabled={busy} onClick={() => decider(b, false)}>Refuser</Button>
              </span>
            ) },
          ]} />
        )}
      </Charge>
      {nouveau && (
        <FormModal titre="Besoin de recrutement" onClose={() => setNouveau(false)} busy={busy} valider="Soumettre"
          onSubmit={() => void run(() => api.post('/api/grh/besoins', { poste_id: Number(f.poste_id), motif: f.motif, nb_postes: Number(f.nb) }), 'Besoin soumis à décision', () => { setNouveau(false); q.reload() })}>
          <Field label="Poste"><Select value={f.poste_id} onChange={(e) => setF({ ...f, poste_id: e.target.value })} required><option value="">— choisir —</option>{postes.data?.map((p) => <option key={p.id} value={p.id}>{p.code} — {p.libelle}</option>)}</Select></Field>
          <Field label="Motif" hint="Remplacement, création de poste, croissance…"><Input value={f.motif} onChange={(e) => setF({ ...f, motif: e.target.value })} minLength={5} required /></Field>
          <Field label="Nombre de postes"><Input type="number" min={1} max={50} value={f.nb} onChange={(e) => setF({ ...f, nb: e.target.value })} required /></Field>
        </FormModal>
      )}
      {ouvert && <Candidatures besoin={ouvert} onClose={() => { setOuvert(null); q.reload() }} />}
    </Card>
  )
}

function Candidatures({ besoin, onClose }: { besoin: Besoin; onClose: () => void }) {
  const { can } = useSession()
  const q = useFetch(() => api.get<Candidature[]>(`/api/grh/besoins/${besoin.besoin_id}/candidatures`), [besoin.besoin_id])
  const candidats = useFetch(() => api.get<Candidat[]>('/api/grh/candidats'), [])
  const { run, busy } = useAction()
  const [vue, setVue] = useState<null | 'candidat' | { type: 'entretien' | 'embauche'; c: Candidature }>(null)
  const [cand, setCand] = useState({ choix: '', nom: '', tel: '' })
  const [ent, setEnt] = useState({ date: aujourdhui(), type: 'rh', note: '', decision: 'favorable', avis: '' })
  const [emb, setEmb] = useState({ matricule: '', date: aujourdhui(), salaire: '', type: 'cdi', fin: '', essai: '' })
  const ouvert = besoin.statut === 'approuve'
  const statut = (c: Candidature, s: string) => {
    const motif = s === 'refusee' ? window.prompt('Motif du refus (obligatoire) :') : null
    if (s === 'refusee' && !motif) return
    void run(() => api.post(`/api/grh/candidatures/${c.id}/statut`, { statut: s, motif_refus: motif }), 'Candidature mise à jour', q.reload)
  }
  return (
    <Modal titre={`Candidatures — ${besoin.poste}`} onClose={onClose} large footer={<Button onClick={onClose}>Fermer</Button>}>
      <div className="stack">
        {!ouvert && <Alert tone="warn">Ce besoin est « {besoin.statut} » : plus de nouvelle candidature.</Alert>}
        {ouvert && can('grh:write') && <div><Button variant="primary" onClick={() => setVue('candidat')}>Ajouter une candidature</Button></div>}
        <Charge q={q}>
          {(rows) => (
            <Table rows={rows} vide="Aucune candidature" cols={[
              { titre: 'Candidat', render: (c) => <span><strong>{c.nom}</strong> <span className="muted">{c.telephone ?? c.email}</span></span> },
              { titre: 'Statut', render: (c) => <Badge tone={TONE[c.statut]}>{c.statut}</Badge> },
              { titre: 'Entretiens', render: (c) => `${c.nb_entretiens}${c.meilleure_note !== null ? ` — meilleure note ${c.meilleure_note}/10` : ''}` },
              { titre: '', render: (c) => can('grh:write') && !['embauchee', 'refusee', 'desistement'].includes(c.statut) && (
                <span className="actions">
                  <Button small onClick={() => setVue({ type: 'entretien', c })}>Entretien</Button>
                  {c.statut !== 'retenue' && <Button small disabled={busy} onClick={() => statut(c, 'retenue')}>Retenir</Button>}
                  {c.statut === 'retenue' && <Button small variant="primary" onClick={() => setVue({ type: 'embauche', c })}>Embaucher</Button>}
                  <Button small variant="danger" disabled={busy} onClick={() => statut(c, 'refusee')}>Refuser</Button>
                </span>
              ) },
            ]} />
          )}
        </Charge>
        {vue === 'candidat' && (
          <FormModal titre="Ajouter une candidature" onClose={() => setVue(null)} busy={busy}
            onSubmit={() => void run(async () => {
              let id = Number(cand.choix)
              if (!id) { const c = await api.post<{ id: number }>('/api/grh/candidats', { nom: cand.nom, telephone: cand.tel || null }); id = c.id }
              await api.post(`/api/grh/besoins/${besoin.besoin_id}/candidatures`, { candidat_id: id })
            }, 'Candidature enregistrée', () => { setVue(null); setCand({ choix: '', nom: '', tel: '' }); q.reload(); candidats.reload() })}>
            <Field label="Candidat déjà connu"><Select value={cand.choix} onChange={(e) => setCand({ ...cand, choix: e.target.value })}><option value="">— nouveau candidat —</option>{candidats.data?.map((c) => <option key={c.id} value={c.id}>{c.nom}</option>)}</Select></Field>
            {!cand.choix && <><Field label="Nom"><Input value={cand.nom} onChange={(e) => setCand({ ...cand, nom: e.target.value })} required /></Field><Field label="Téléphone"><Input value={cand.tel} onChange={(e) => setCand({ ...cand, tel: e.target.value })} required /></Field></>}
          </FormModal>
        )}
        {vue && typeof vue === 'object' && vue.type === 'entretien' && (
          <FormModal titre={`Entretien — ${vue.c.nom}`} onClose={() => setVue(null)} busy={busy}
            onSubmit={() => void run(() => api.post(`/api/grh/candidatures/${(vue as { c: Candidature }).c.id}/entretiens`, { date_entretien: ent.date, type: ent.type, note: Number(ent.note), decision: ent.decision, avis: ent.avis || null }), 'Entretien enregistré', () => { setVue(null); q.reload() })}>
            <Field label="Date"><Input type="date" value={ent.date} max={aujourdhui()} onChange={(e) => setEnt({ ...ent, date: e.target.value })} required /></Field>
            <Field label="Type"><Select value={ent.type} onChange={(e) => setEnt({ ...ent, type: e.target.value })}>{['telephone', 'technique', 'rh', 'direction'].map((t) => <option key={t} value={t}>{t}</option>)}</Select></Field>
            <Field label="Note sur 10" hint="6 au moins avec un avis favorable pour pouvoir retenir le candidat"><Input type="number" min={0} max={10} step="0.5" value={ent.note} onChange={(e) => setEnt({ ...ent, note: e.target.value })} required /></Field>
            <Field label="Avis"><Select value={ent.decision} onChange={(e) => setEnt({ ...ent, decision: e.target.value })}><option value="favorable">Favorable</option><option value="reserve">Réservé</option><option value="defavorable">Défavorable</option></Select></Field>
            <Field label="Commentaire"><Input value={ent.avis} onChange={(e) => setEnt({ ...ent, avis: e.target.value })} /></Field>
          </FormModal>
        )}
        {vue && typeof vue === 'object' && vue.type === 'embauche' && (
          <FormModal titre={`Embauche — ${vue.c.nom}`} onClose={() => setVue(null)} busy={busy} valider="Embaucher"
            onSubmit={() => void run(() => api.post(`/api/grh/candidatures/${(vue as { c: Candidature }).c.id}/embaucher`, { matricule: emb.matricule, date_embauche: emb.date, salaire_base: Number(emb.salaire), type_contrat: emb.type, date_fin: emb.fin || null, periode_essai_fin: emb.essai || null }), 'Employé créé avec son contrat', () => { setVue(null); q.reload() })}>
            <Alert tone="info">Le salaire doit rester dans la fourchette du poste.</Alert>
            <Field label="Matricule"><Input value={emb.matricule} onChange={(e) => setEmb({ ...emb, matricule: e.target.value })} required maxLength={20} /></Field>
            <Field label="Date d'embauche"><Input type="date" value={emb.date} onChange={(e) => setEmb({ ...emb, date: e.target.value })} required /></Field>
            <Field label="Type de contrat"><Select value={emb.type} onChange={(e) => setEmb({ ...emb, type: e.target.value })}><option value="cdi">CDI</option><option value="cdd">CDD</option><option value="stage">Stage</option><option value="journalier">Journalier</option></Select></Field>
            <Field label="Salaire de base"><Input type="number" min={0} value={emb.salaire} onChange={(e) => setEmb({ ...emb, salaire: e.target.value })} required /></Field>
            <Field label="Fin du contrat" hint="CDD, stage"><Input type="date" value={emb.fin} onChange={(e) => setEmb({ ...emb, fin: e.target.value })} /></Field>
            <Field label="Fin de la période d'essai"><Input type="date" value={emb.essai} onChange={(e) => setEmb({ ...emb, essai: e.target.value })} /></Field>
          </FormModal>
        )}
        <p className="muted">Demande ouverte le {besoin.date_souhaitee ? fdate(besoin.date_souhaitee) : '—'}.</p>
      </div>
    </Modal>
  )
}
