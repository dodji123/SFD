import { useState } from 'react'
import { api } from '../lib/api'
import { date as fdate, dateHeure, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Modal, Money, Page, Select, Table, Tabs, useAction, useFetch } from '../components/ui'

/* ------------------------------------------------------------------ types */
interface Comite { id: number; code: string; libelle: string; agence_id: number | null; reseau_id: number | null; agence?: string | null; reseau?: string | null; montant_min: number; montant_max: number | null; quorum: number; actif: boolean; nb_membres?: number }
interface Membre { id: number; utilisateur_id: number; login: string; nom: string; role: string; fonction: 'president' | 'secretaire' | 'membre'; avec_voix: boolean; depuis: string; jusqua: string | null }
interface Personne { id: number; login: string; nom: string; role: string }
interface SeanceLigne { id: number; numero: string; comite: string; date_seance: string; lieu: string | null; statut: string; nb_dossiers: number; total_demande: number; total_accorde: number; nb_acceptes: number; nb_ajournes: number; nb_rejetes: number }
interface Vote { utilisateur_id: number; nom: string; vote: string; motif: string | null }
interface Dossier {
  id: number; demande_id: number; demande_numero: string; client: string; produit: string; montant_demande: number; nb_echeances: number; taux: number
  rapporteur: string | null; rapporteur_id: number | null; analyse_individuelle: string | null; analyse_conforme: boolean | null; taux_endettement: number | null; couverture: number | null
  visite_le: string | null; visite_par: number | null; contre_visite_le: string | null; contre_visite_par: number | null
  decision: 'acceptation' | 'ajournement' | 'rejet' | null; motif: string | null; montant_accorde: number | null; conditions: string | null
  nb_votes: number; votes: Vote[]; recusations: { utilisateur_id: number; nom: string; motif: string }[]
}
interface Seance {
  id: number; numero: string; comite_id: number; comite: Comite; date_seance: string; lieu: string | null; ordre_du_jour: string | null; statut: string
  membres: { utilisateur_id: number; login: string; nom: string; fonction: string; avec_voix: boolean; present: boolean | null; motif_absence: string | null }[]
  quorum_atteint: boolean; dossiers: Dossier[]
  analyse_globale: { nb_dossiers: number; total_demande: number; total_accorde: number; nb_acceptes: number; nb_ajournes: number; nb_rejetes: number; nb_en_attente: number; encours_agences_concernees: number }
  signataires: { president: string | null; secretaire: string | null }
  pv_signe_president: string | null; pv_signe_secretaire: string | null
}
interface Pv extends Seance {
  institution: { raison_sociale: string; sigle: string | null; agrement: string | null; adresse: string | null; ville: string | null; telephone: string | null; email: string | null; logo: string | null; pied_de_page: string | null }
  agence: { code: string; libelle: string; adresse: string | null; ville: string | null; telephone: string | null } | null
}
interface Delegation { id: number; utilisateur_id: number; login: string; nom: string; montant_max_credit: number; montant_max_periode: number | null; periode: string; debut: string; fin: string | null; motif: string; accordee_par_login: string; active: boolean }
interface DemandeAExaminer { id: number; numero: string; agence: string; montant: number; nb_echeances: number; client: string; produit: string; analyse_conforme: boolean | null }

const STATUT: Record<string, { texte: string; tone: 'ok' | 'warn' | 'bad' | 'info' | 'neutre' }> = {
  preparee: { texte: 'En préparation', tone: 'neutre' }, convoquee: { texte: 'Convoquée', tone: 'info' }, ouverte: { texte: 'En séance', tone: 'warn' },
  close: { texte: 'Close', tone: 'ok' }, annulee: { texte: 'Annulée', tone: 'bad' },
}
const DECISION: Record<string, { texte: string; tone: 'ok' | 'warn' | 'bad' }> = {
  acceptation: { texte: 'Accepté', tone: 'ok' }, ajournement: { texte: 'Ajourné', tone: 'warn' }, rejet: { texte: 'Rejeté', tone: 'bad' },
}
const FONCTION: Record<string, string> = { president: 'Président', secretaire: 'Secrétaire', membre: 'Membre' }
const VOTES = [['acceptation', 'Accepter'], ['ajournement', 'Ajourner'], ['rejet', 'Rejeter'], ['abstention', 'M\'abstenir']]

export default function Comites() {
  const { can } = useSession()
  const [vue, setVue] = useState('seances')
  const [seanceId, setSeanceId] = useState<number | null>(null)
  const onglets = [
    { id: 'seances', titre: 'Séances' }, { id: 'comites', titre: 'Comités et membres' }, { id: 'delegations', titre: 'Délégations' },
  ]
  if (seanceId !== null) return <Page title="Séance du comité de crédit"><SeanceVue id={seanceId} retour={() => setSeanceId(null)} /></Page>
  return (
    <Page title="Comité de gestion du crédit" subtitle="Composition, séances, votes motivés, décisions et procès-verbaux">
      <Tabs actif={vue} onChange={setVue} tabs={onglets} />
      {vue === 'seances' && <Seances ouvrir={setSeanceId} />}
      {vue === 'comites' && <ComitesListe peutGerer={can('comite:manage')} />}
      {vue === 'delegations' && <Delegations peutAccorder={can('delegation:write')} />}
    </Page>
  )
}

/* ------------------------------------------------------------------ séances */
function Seances({ ouvrir }: { ouvrir: (id: number) => void }) {
  const [statut, setStatut] = useState('')
  const q = useFetch(() => api.get<SeanceLigne[]>('/api/comites/seances/liste', { statut }), [statut])
  const comites = useFetch(() => api.get<Comite[]>('/api/comites'), [])
  const { run, busy } = useAction()
  const [nouvelle, setNouvelle] = useState(false)
  const [f, setF] = useState({ comite_id: '', date_seance: '', lieu: '', ordre_du_jour: '' })
  return (
    <Card flush actions={
      <span className="row" style={{ gap: 8 }}>
        <Select value={statut} onChange={(e) => setStatut(e.target.value)} aria-label="Statut">
          <option value="">Toutes</option>{Object.entries(STATUT).map(([k, v]) => <option key={k} value={k}>{v.texte}</option>)}
        </Select>
        <Button variant="primary" onClick={() => { setF({ comite_id: String(comites.data?.find((c) => c.actif)?.id ?? ''), date_seance: '', lieu: '', ordre_du_jour: '' }); setNouvelle(true) }}>Nouvelle séance</Button>
      </span>
    }>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucune séance" onRowClick={(s) => ouvrir(s.id)} cols={[
            { titre: 'N°', render: (s) => <strong>{s.numero}</strong> },
            { titre: 'Comité', render: (s) => s.comite },
            { titre: 'Date', render: (s) => dateHeure(s.date_seance) },
            { titre: 'Statut', render: (s) => <Badge tone={STATUT[s.statut]?.tone}>{STATUT[s.statut]?.texte ?? s.statut}</Badge> },
            { titre: 'Dossiers', render: (s) => s.nb_dossiers },
            { titre: 'Demandé', render: (s) => <Money v={s.total_demande} /> },
            { titre: 'Accordé', render: (s) => <Money v={s.total_accorde} /> },
            { titre: 'Décisions', render: (s) => `${s.nb_acceptes} acc. · ${s.nb_ajournes} ajourn. · ${s.nb_rejetes} rej.` },
          ]} />
        )}
      </Charge>
      {nouvelle && (
        <FormModal titre="Nouvelle séance" onClose={() => setNouvelle(false)} busy={busy} valider="Créer la séance"
          onSubmit={() => void run(() => api.post<{ id: number }>('/api/comites/seances', { comite_id: Number(f.comite_id), date_seance: new Date(f.date_seance).toISOString(), lieu: f.lieu || null, ordre_du_jour: f.ordre_du_jour || null }), 'Séance créée', () => { setNouvelle(false); q.reload() })}>
          <Field label="Comité"><Select value={f.comite_id} onChange={(e) => setF({ ...f, comite_id: e.target.value })} required><option value="">— choisir —</option>{comites.data?.filter((c) => c.actif).map((c) => <option key={c.id} value={c.id}>{c.code} — {c.libelle}</option>)}</Select></Field>
          <Field label="Date et heure" hint="La convocation doit précéder la séance d'au moins 24 heures"><Input type="datetime-local" value={f.date_seance} onChange={(e) => setF({ ...f, date_seance: e.target.value })} required /></Field>
          <Field label="Lieu"><Input value={f.lieu} onChange={(e) => setF({ ...f, lieu: e.target.value })} /></Field>
          <Field label="Ordre du jour"><textarea className="input" rows={3} value={f.ordre_du_jour} onChange={(e) => setF({ ...f, ordre_du_jour: e.target.value })} /></Field>
        </FormModal>
      )}
    </Card>
  )
}

function SeanceVue({ id, retour }: { id: number; retour: () => void }) {
  const { user, can } = useSession()
  const q = useFetch(() => api.get<Seance>(`/api/comites/seances/${id}`), [id])
  const { run, busy } = useAction()
  const [modal, setModal] = useState<null | 'inscrire' | 'ordre' | 'pv' | 'annuler'>(null)
  const [dossierEdit, setDossierEdit] = useState<Dossier | null>(null)
  const [decision, setDecision] = useState<Dossier | null>(null)
  const act = (chemin: string, ok: string, corps?: unknown) => void run(() => api.post(`/api/comites/seances/${id}/${chemin}`, corps), ok, q.reload)
  return (
    <Charge q={q}>
      {(s) => {
        const moi = s.membres.find((m) => m.utilisateur_id === user?.id)
        const anime = can('comite:manage') || moi?.fonction === 'president' || moi?.fonction === 'secretaire'
        const dossiersLibres = s.statut === 'preparee' || s.statut === 'convoquee'
        const signe = moi?.fonction === 'president' ? s.pv_signe_president : moi?.fonction === 'secretaire' ? s.pv_signe_secretaire : null
        return (
          <div className="stack">
            <div className="row" style={{ gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
              <Button small onClick={retour}>← Séances</Button>
              <strong>{s.numero}</strong> <Badge tone={STATUT[s.statut]?.tone}>{STATUT[s.statut]?.texte}</Badge>
              <span className="muted">{s.comite.code} · {dateHeure(s.date_seance)}{s.lieu ? ` · ${s.lieu}` : ''}</span>
              <span className="spacer" />
              {anime && s.statut === 'preparee' && <Button small onClick={() => setModal('ordre')}>Ordre du jour</Button>}
              {anime && s.statut === 'preparee' && <Button small variant="primary" disabled={busy} onClick={() => act('convoquer', 'Séance convoquée : liste de présence créée')}>Convoquer</Button>}
              {anime && s.statut === 'convoquee' && <Button small variant="primary" disabled={busy} onClick={() => act('ouvrir', 'Séance ouverte')}>Ouvrir la séance</Button>}
              {s.statut === 'ouverte' && moi && (moi.fonction === 'president' || moi.fonction === 'secretaire') && !signe && <Button small disabled={busy} onClick={() => act('signer', 'Procès-verbal signé')}>Signer le PV</Button>}
              {anime && s.statut === 'ouverte' && <Button small variant="primary" disabled={busy} onClick={() => act('cloturer', 'Séance clôturée')}>Clôturer</Button>}
              {anime && ['preparee', 'convoquee', 'ouverte'].includes(s.statut) && <Button small variant="danger" onClick={() => setModal('annuler')}>Annuler</Button>}
              {(s.statut === 'ouverte' || s.statut === 'close') && <Button small onClick={() => setModal('pv')}>Procès-verbal</Button>}
            </div>
            {s.ordre_du_jour && <Alert tone="info"><span style={{ whiteSpace: 'pre-wrap' }}>{s.ordre_du_jour}</span></Alert>}

            <Card title={`Présences — quorum ${s.comite.quorum} membre(s) avec voix et majorité`} actions={s.statut !== 'preparee' && <Badge tone={s.quorum_atteint ? 'ok' : 'bad'}>{s.quorum_atteint ? 'Quorum atteint' : 'Quorum non atteint'}</Badge>}>
              <Table rows={s.membres} cols={[
                { titre: 'Membre', render: (m) => m.nom },
                { titre: 'Fonction', render: (m) => FONCTION[m.fonction] + (m.avec_voix ? '' : ' (voix consultative)') },
                { titre: 'Présence', render: (m) => (s.statut === 'preparee' ? <span className="muted">à la convocation</span> : s.statut === 'convoquee' && anime ? (
                  <span className="actions">
                    <Button small variant={m.present === true ? 'primary' : undefined} disabled={busy} onClick={() => act('presences', 'Présence pointée', { utilisateur_id: m.utilisateur_id, present: true })}>Présent</Button>
                    <Button small variant={m.present === false ? 'danger' : undefined} disabled={busy} onClick={() => act('presences', 'Absence pointée', { utilisateur_id: m.utilisateur_id, present: false, motif_absence: 'Absent' })}>Absent</Button>
                  </span>
                ) : m.present === null ? '—' : m.present ? <Badge tone="ok">Présent</Badge> : <Badge tone="bad">Absent{m.motif_absence ? ` — ${m.motif_absence}` : ''}</Badge>) },
              ]} />
            </Card>

            <Card title={`Dossiers examinés (${s.dossiers.length})`} actions={anime && dossiersLibres && <Button small variant="primary" onClick={() => setModal('inscrire')}>Inscrire un dossier</Button>}>
              {s.dossiers.length === 0 && <p className="muted">Aucun dossier inscrit.</p>}
              <div className="stack">
                {s.dossiers.map((d) => (
                  <DossierCarte key={d.id} d={d} s={s} moi={moi} anime={anime} busy={busy}
                    onVote={(vote, motif) => void run(() => api.post(`/api/comites/dossiers/${d.id}/vote`, { vote, motif: motif || null }), 'Vote enregistré', q.reload)}
                    onRecuser={(motif) => void run(() => api.post(`/api/comites/dossiers/${d.id}/recusation`, { motif }), 'Récusation enregistrée', q.reload)}
                    onEdit={() => setDossierEdit(d)} onDecider={() => setDecision(d)}
                    onRetirer={() => void run(() => api.del(`/api/comites/dossiers/${d.id}`), 'Dossier retiré', q.reload)} />
                ))}
              </div>
            </Card>

            <Card title="Analyse globale de la séance">
              <div className="row" style={{ gap: 24, flexWrap: 'wrap' }}>
                <span>Total demandé : <strong>{xof(s.analyse_globale.total_demande)}</strong></span>
                <span>Total accordé : <strong>{xof(s.analyse_globale.total_accorde)}</strong></span>
                <span>Encours actuel des agences concernées : <strong>{xof(s.analyse_globale.encours_agences_concernees)}</strong></span>
                <span>{s.analyse_globale.nb_acceptes} accepté(s) · {s.analyse_globale.nb_ajournes} ajourné(s) · {s.analyse_globale.nb_rejetes} rejeté(s) · {s.analyse_globale.nb_en_attente} en attente</span>
              </div>
            </Card>

            {modal === 'inscrire' && <Inscription seance={s} onClose={() => setModal(null)} onFait={() => { setModal(null); q.reload() }} />}
            {modal === 'ordre' && <OrdreDuJour seance={s} onClose={() => setModal(null)} onFait={() => { setModal(null); q.reload() }} />}
            {modal === 'pv' && <ProcesVerbal id={s.id} onClose={() => setModal(null)} />}
            {modal === 'annuler' && <Annulation id={s.id} onClose={() => setModal(null)} onFait={() => { setModal(null); q.reload() }} />}
            {dossierEdit && <EditionDossier d={dossierEdit} membres={s.membres} onClose={() => setDossierEdit(null)} onFait={() => { setDossierEdit(null); q.reload() }} />}
            {decision && <Decision d={decision} onClose={() => setDecision(null)} onFait={() => { setDecision(null); q.reload() }} />}
          </div>
        )
      }}
    </Charge>
  )
}

function DossierCarte({ d, s, moi, anime, busy, onVote, onRecuser, onEdit, onDecider, onRetirer }: {
  d: Dossier; s: Seance; moi: Seance['membres'][number] | undefined; anime: boolean; busy: boolean
  onVote: (vote: string, motif: string) => void; onRecuser: (motif: string) => void; onEdit: () => void; onDecider: () => void; onRetirer: () => void
}) {
  const { user } = useSession()
  const [vote, setVote] = useState('acceptation')
  const [motif, setMotif] = useState('')
  const monVote = d.votes.find((v) => v.utilisateur_id === user?.id)
  const recuse = d.recusations.some((r) => r.utilisateur_id === user?.id)
  const peutVoter = s.statut === 'ouverte' && !d.decision && moi?.avec_voix && moi.present && !recuse
  const decideur = moi?.fonction === 'president' || moi?.fonction === 'secretaire'
  return (
    <div style={{ border: '1px solid var(--line, #d1d5db)', borderRadius: 8, padding: 12 }} className="stack">
      <div className="row" style={{ gap: 12, alignItems: 'center', flexWrap: 'wrap' }}>
        <strong>{d.demande_numero}</strong><span>{d.client}</span><span className="muted">{d.produit} · {d.nb_echeances} échéances</span>
        <strong><Money v={d.montant_demande} /></strong>
        {d.decision && <Badge tone={DECISION[d.decision].tone}>{DECISION[d.decision].texte}{d.montant_accorde ? ` — ${xof(d.montant_accorde)}` : ''}</Badge>}
        <span className="spacer" />
        {anime && !d.decision && <Button small onClick={onEdit}>Instruction</Button>}
        {anime && (s.statut === 'preparee' || s.statut === 'convoquee') && <Button small variant="danger" disabled={busy} onClick={onRetirer}>Retirer</Button>}
      </div>
      <div className="muted" style={{ whiteSpace: 'pre-wrap' }}>
        {d.rapporteur ? `Rapporteur : ${d.rapporteur}. ` : ''}{d.analyse_individuelle || 'Analyse individuelle non renseignée.'}
      </div>
      <div className="row" style={{ gap: 16, flexWrap: 'wrap' }}>
        {d.analyse_conforme !== null && <Badge tone={d.analyse_conforme ? 'ok' : 'warn'}>Capacité {d.analyse_conforme ? 'conforme' : 'non conforme'}{d.taux_endettement !== null ? ` · endettement ${(d.taux_endettement * 100).toFixed(1)} %` : ''}</Badge>}
        <span>Visite : {d.visite_le ? fdate(d.visite_le) : <span className="muted">non faite</span>}</span>
        <span>Contre-visite : {d.contre_visite_le ? fdate(d.contre_visite_le) : <span className="muted">non faite</span>}</span>
      </div>
      {d.recusations.length > 0 && <div className="muted">Récusé(s) : {d.recusations.map((r) => `${r.nom} (${r.motif})`).join(' ; ')}</div>}
      {d.decision && (
        <>
          <div><strong>Décision motivée :</strong> {d.motif}{d.conditions ? <> — <em>Conditions : {d.conditions}</em></> : null}</div>
          <div className="muted">Votes : {d.votes.map((v) => `${v.nom} : ${v.vote}`).join(' · ')}</div>
        </>
      )}
      {!d.decision && s.statut === 'ouverte' && (
        <div className="stack">
          <div className="muted">{d.nb_votes} vote(s) exprimé(s) — le détail reste secret jusqu'à la décision.{monVote ? ` Votre vote : ${monVote.vote}.` : ''}</div>
          {peutVoter && (
            <div className="row" style={{ gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
              <Select value={vote} onChange={(e) => setVote(e.target.value)} aria-label="Vote">{VOTES.map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select>
              <Input placeholder="Motif (obligatoire sauf abstention)" value={motif} onChange={(e) => setMotif(e.target.value)} style={{ flex: 1, minWidth: 220 }} />
              <Button small variant="primary" disabled={busy || (vote !== 'abstention' && motif.trim().length < 5)} onClick={() => onVote(vote, motif)}>{monVote ? 'Modifier mon vote' : 'Voter'}</Button>
              <Button small disabled={busy} onClick={() => { const m = window.prompt('Motif du conflit d\'intérêts (vous ne voterez pas sur ce dossier)'); if (m && m.trim().length >= 5) onRecuser(m.trim()) }}>Me récuser</Button>
            </div>
          )}
          {decideur && <div><Button small variant="primary" disabled={busy} onClick={onDecider}>Constater la décision</Button></div>}
        </div>
      )}
    </div>
  )
}

function Inscription({ seance, onClose, onFait }: { seance: Seance; onClose: () => void; onFait: () => void }) {
  const q = useFetch(() => api.get<DemandeAExaminer[]>('/api/comites/demandes/a-examiner', { comite_id: seance.comite_id }), [seance.comite_id])
  const { run, busy } = useAction()
  const [f, setF] = useState({ demande_id: '', rapporteur_id: '', analyse: '' })
  return (
    <FormModal titre="Inscrire un dossier à l'ordre du jour" onClose={onClose} busy={busy} valider="Inscrire"
      onSubmit={() => void run(() => api.post(`/api/comites/seances/${seance.id}/dossiers`, { demande_id: Number(f.demande_id), rapporteur_id: f.rapporteur_id ? Number(f.rapporteur_id) : null, analyse_individuelle: f.analyse || null }), 'Dossier inscrit', onFait)}>
      <Charge q={q}>
        {(rows) => (
          <Field label="Demande de crédit" hint="Demandes en attente relevant de la compétence du comité">
            <Select value={f.demande_id} onChange={(e) => setF({ ...f, demande_id: e.target.value })} required>
              <option value="">— choisir —</option>
              {rows.map((d) => <option key={d.id} value={d.id}>{d.numero} · {d.client} · {xof(d.montant)}{d.analyse_conforme === false ? ' · capacité non conforme' : ''}</option>)}
            </Select>
          </Field>
        )}
      </Charge>
      <Field label="Rapporteur"><Select value={f.rapporteur_id} onChange={(e) => setF({ ...f, rapporteur_id: e.target.value })}><option value="">—</option>{seance.membres.map((m) => <option key={m.utilisateur_id} value={m.utilisateur_id}>{m.nom}</option>)}</Select></Field>
      <Field label="Analyse individuelle" hint="Synthèse de l'instruction présentée au comité"><textarea className="input" rows={4} value={f.analyse} onChange={(e) => setF({ ...f, analyse: e.target.value })} /></Field>
    </FormModal>
  )
}

function OrdreDuJour({ seance, onClose, onFait }: { seance: Seance; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [txt, setTxt] = useState(seance.ordre_du_jour ?? '')
  const [lieu, setLieu] = useState(seance.lieu ?? '')
  return (
    <FormModal titre="Ordre du jour" onClose={onClose} busy={busy} onSubmit={() => void run(() => api.patch(`/api/comites/seances/${seance.id}`, { ordre_du_jour: txt, lieu: lieu || null }), 'Ordre du jour enregistré', onFait)}>
      <Field label="Lieu"><Input value={lieu} onChange={(e) => setLieu(e.target.value)} /></Field>
      <Field label="Ordre du jour"><textarea className="input" rows={5} value={txt} onChange={(e) => setTxt(e.target.value)} required /></Field>
    </FormModal>
  )
}

function Annulation({ id, onClose, onFait }: { id: number; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [motif, setMotif] = useState('')
  return (
    <FormModal titre="Annuler la séance" onClose={onClose} busy={busy} valider="Annuler la séance" onSubmit={() => void run(() => api.post(`/api/comites/seances/${id}/annuler`, { motif }), 'Séance annulée', onFait)}>
      <Field label="Motif" hint="5 caractères au moins"><Input value={motif} onChange={(e) => setMotif(e.target.value)} minLength={5} required autoFocus /></Field>
    </FormModal>
  )
}

function EditionDossier({ d, membres, onClose, onFait }: { d: Dossier; membres: Seance['membres']; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({
    analyse: d.analyse_individuelle ?? '', rapporteur: d.rapporteur_id ? String(d.rapporteur_id) : '',
    visite_le: d.visite_le ?? '', visite_par: d.visite_par ? String(d.visite_par) : '', cv_le: d.contre_visite_le ?? '', cv_par: d.contre_visite_par ? String(d.contre_visite_par) : '',
  })
  const corps = () => ({
    analyse_individuelle: f.analyse, rapporteur_id: f.rapporteur ? Number(f.rapporteur) : null,
    ...(f.visite_le && f.visite_par ? { visite_le: f.visite_le, visite_par: Number(f.visite_par) } : {}),
    ...(f.cv_le && f.cv_par ? { contre_visite_le: f.cv_le, contre_visite_par: Number(f.cv_par) } : {}),
  })
  const pers = (v: string, set: (x: string) => void) => <Select value={v} onChange={(e) => set(e.target.value)}><option value="">—</option>{membres.map((m) => <option key={m.utilisateur_id} value={m.utilisateur_id}>{m.nom}</option>)}</Select>
  return (
    <FormModal titre={`Instruction — ${d.demande_numero}`} onClose={onClose} busy={busy} large onSubmit={() => void run(() => api.patch(`/api/comites/dossiers/${d.id}`, corps()), 'Instruction enregistrée', onFait)}>
      <Field label="Rapporteur">{pers(f.rapporteur, (x) => setF({ ...f, rapporteur: x }))}</Field>
      <Field label="Analyse individuelle"><textarea className="input" rows={4} value={f.analyse} onChange={(e) => setF({ ...f, analyse: e.target.value })} /></Field>
      <Field label="Visite du client" hint="Obligatoire à partir du seuil de montant paramétré"><span className="row" style={{ gap: 8 }}><Input type="date" value={f.visite_le} onChange={(e) => setF({ ...f, visite_le: e.target.value })} />{pers(f.visite_par, (x) => setF({ ...f, visite_par: x }))}</span></Field>
      <Field label="Contre-visite" hint="Par une autre personne que celle de la visite"><span className="row" style={{ gap: 8 }}><Input type="date" value={f.cv_le} onChange={(e) => setF({ ...f, cv_le: e.target.value })} />{pers(f.cv_par, (x) => setF({ ...f, cv_par: x }))}</span></Field>
    </FormModal>
  )
}

function Decision({ d, onClose, onFait }: { d: Dossier; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ motif: '', montant: '', conditions: '' })
  return (
    <FormModal titre={`Décision — ${d.demande_numero}`} onClose={onClose} busy={busy} valider="Constater la décision"
      onSubmit={() => void run(() => api.post(`/api/comites/dossiers/${d.id}/decider`, { motif: f.motif, montant_accorde: f.montant ? Number(f.montant) : null, conditions: f.conditions || null }), 'Décision constatée et appliquée à la demande', onFait)}>
      <Alert tone="info">La décision résulte des votes (acceptation ou rejet à la majorité absolue des suffrages exprimés, voix prépondérante du président en cas d'égalité, sinon ajournement). Tous les membres éligibles doivent avoir voté.</Alert>
      <Field label="Motif de la décision" hint="10 caractères au moins"><textarea className="input" rows={3} value={f.motif} onChange={(e) => setF({ ...f, motif: e.target.value })} minLength={10} required /></Field>
      <Field label="Montant accordé en cas d'acceptation" hint={`Vide : montant demandé (${xof(d.montant_demande)}). Ne peut pas le dépasser.`}><Input type="number" min={1} max={d.montant_demande} value={f.montant} onChange={(e) => setF({ ...f, montant: e.target.value })} /></Field>
      <Field label="Conditions suspensives"><Input value={f.conditions} onChange={(e) => setF({ ...f, conditions: e.target.value })} /></Field>
    </FormModal>
  )
}

/* ------------------------------------------------------------------ procès-verbal */
function ProcesVerbal({ id, onClose }: { id: number; onClose: () => void }) {
  const q = useFetch(() => api.get<Pv>(`/api/comites/seances/${id}/pv`), [id])
  return (
    <Modal titre="Procès-verbal du comité de crédit" onClose={onClose} large footer={<><Button onClick={onClose}>Fermer</Button><Button variant="primary" onClick={() => window.print()}>Imprimer</Button></>}>
      <Charge q={q}>
        {(p) => {
          const i = p.institution
          return (
            <div className="piece-doc" style={{ padding: 16, border: '1px solid var(--line, #d1d5db)', borderRadius: 8, background: '#fff', color: '#111' }}>
              <div style={{ display: 'flex', gap: 12, alignItems: 'center', borderBottom: '2px solid #111', paddingBottom: 8 }}>
                {i.logo && <img src={i.logo} alt="Logo" style={{ maxHeight: 64, maxWidth: 120, objectFit: 'contain' }} />}
                <div style={{ flex: 1 }}>
                  <div style={{ fontSize: 18, fontWeight: 700 }}>{i.raison_sociale}{i.sigle ? ` (${i.sigle})` : ''}</div>
                  {i.agrement && <div style={{ fontSize: 12 }}>{i.agrement}</div>}
                  <div style={{ fontSize: 12 }}>{[i.adresse, i.ville].filter(Boolean).join(', ')}{i.telephone ? ` — Tél. ${i.telephone}` : ''}</div>
                </div>
              </div>
              <h2 style={{ textAlign: 'center', margin: '12px 0 4px' }}>PROCÈS-VERBAL DU COMITÉ DE CRÉDIT</h2>
              <div style={{ textAlign: 'center' }}>Séance n° {p.numero} du {dateHeure(p.date_seance)}{p.lieu ? `, ${p.lieu}` : ''}</div>
              <div style={{ textAlign: 'center', fontSize: 12 }}>{p.comite.libelle}{p.agence ? ` — agence ${p.agence.libelle}` : ''} · quorum {p.comite.quorum}</div>
              <h3>Présences</h3>
              <table className="t" style={{ width: '100%' }}>
                <thead><tr><th>Nom</th><th>Fonction</th><th>Présence</th></tr></thead>
                <tbody>{p.membres.map((m) => <tr key={m.utilisateur_id}><td>{m.nom}</td><td>{FONCTION[m.fonction]}{m.avec_voix ? '' : ' (consultatif)'}</td><td>{m.present ? 'Présent' : `Absent${m.motif_absence ? ` — ${m.motif_absence}` : ''}`}</td></tr>)}</tbody>
              </table>
              <p>Le quorum {p.quorum_atteint ? 'est atteint' : "n'est pas atteint"}.</p>
              {p.ordre_du_jour && <><h3>Ordre du jour</h3><div style={{ whiteSpace: 'pre-wrap' }}>{p.ordre_du_jour}</div></>}
              <h3>Délibérations</h3>
              {p.dossiers.map((d, n) => (
                <div key={d.id} style={{ marginBottom: 12, breakInside: 'avoid' }}>
                  <strong>{n + 1}. {d.demande_numero} — {d.client}</strong> ({d.produit}, {xof(d.montant_demande)} sur {d.nb_echeances} échéances)
                  <div style={{ fontSize: 13 }}>Rapporteur : {d.rapporteur ?? '—'}. Analyse : {d.analyse_individuelle ?? '—'}</div>
                  <div style={{ fontSize: 13 }}>Visite : {d.visite_le ? fdate(d.visite_le) : 'non faite'} · Contre-visite : {d.contre_visite_le ? fdate(d.contre_visite_le) : 'non faite'}</div>
                  {d.recusations.length > 0 && <div style={{ fontSize: 13 }}>Récusations : {d.recusations.map((r) => `${r.nom} (${r.motif})`).join(' ; ')}</div>}
                  <div style={{ fontSize: 13 }}>Votes : {d.votes.map((v) => `${v.nom} — ${v.vote}${v.motif ? ` (${v.motif})` : ''}`).join(' ; ') || '—'}</div>
                  <div><strong>Décision : {d.decision ? DECISION[d.decision].texte : 'non décidé'}</strong>{d.montant_accorde ? ` — montant accordé ${xof(d.montant_accorde)}` : ''}. {d.motif}{d.conditions ? ` Conditions suspensives : ${d.conditions}.` : ''}</div>
                </div>
              ))}
              <p>Total demandé : {xof(p.analyse_globale.total_demande)} — total accordé : {xof(p.analyse_globale.total_accorde)} — {p.analyse_globale.nb_acceptes} accepté(s), {p.analyse_globale.nb_ajournes} ajourné(s), {p.analyse_globale.nb_rejetes} rejeté(s).</p>
              <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 32 }}>
                <div>Le Président<br />{p.signataires.president}<div style={{ height: 48 }} />{p.pv_signe_president ? `Signé le ${dateHeure(p.pv_signe_president)}` : ''}</div>
                <div style={{ textAlign: 'right' }}>Le Secrétaire<br />{p.signataires.secretaire}<div style={{ height: 48 }} />{p.pv_signe_secretaire ? `Signé le ${dateHeure(p.pv_signe_secretaire)}` : ''}</div>
              </div>
              {i.pied_de_page && <div style={{ marginTop: 16, borderTop: '1px solid #999', paddingTop: 6, fontSize: 11, textAlign: 'center' }}>{i.pied_de_page}</div>}
            </div>
          )
        }}
      </Charge>
    </Modal>
  )
}

/* ------------------------------------------------------------------ comités et membres */
function ComitesListe({ peutGerer }: { peutGerer: boolean }) {
  const q = useFetch(() => api.get<Comite[]>('/api/comites'), [])
  const { agences } = useSession()
  const { run, busy } = useAction()
  const [nouveau, setNouveau] = useState(false)
  const [voir, setVoir] = useState<number | null>(null)
  const [f, setF] = useState({ code: '', libelle: '', agence_id: '', montant_min: '0', montant_max: '', quorum: '3' })
  return (
    <Card flush actions={peutGerer ? <Button variant="primary" onClick={() => setNouveau(true)}>Nouveau comité</Button> : undefined}>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucun comité" onRowClick={(c) => setVoir(c.id)} cols={[
            { titre: 'Code', render: (c) => <strong>{c.code}</strong> },
            { titre: 'Libellé', render: (c) => c.libelle },
            { titre: 'Niveau', render: (c) => (c.agence ? `Agence ${c.agence}` : c.reseau ? `Réseau ${c.reseau}` : 'Central') },
            { titre: 'Compétence', render: (c) => `${xof(c.montant_min)} → ${c.montant_max ? xof(c.montant_max) : 'sans plafond'}` },
            { titre: 'Quorum', render: (c) => c.quorum },
            { titre: 'Membres', render: (c) => c.nb_membres },
            { titre: 'État', render: (c) => (c.actif ? <Badge tone="ok">Actif</Badge> : <Badge tone="bad">Inactif</Badge>) },
          ]} />
        )}
      </Charge>
      {nouveau && (
        <FormModal titre="Nouveau comité de crédit" onClose={() => setNouveau(false)} busy={busy} valider="Créer"
          onSubmit={() => void run(() => api.post('/api/comites', { code: f.code, libelle: f.libelle, agence_id: f.agence_id ? Number(f.agence_id) : null, montant_min: Number(f.montant_min), montant_max: f.montant_max ? Number(f.montant_max) : null, quorum: Number(f.quorum) }), 'Comité créé', () => { setNouveau(false); q.reload() })}>
          <Field label="Code"><Input value={f.code} onChange={(e) => setF({ ...f, code: e.target.value })} maxLength={10} required autoFocus /></Field>
          <Field label="Libellé"><Input value={f.libelle} onChange={(e) => setF({ ...f, libelle: e.target.value })} required /></Field>
          <Field label="Agence" hint="Vide : comité central (siège uniquement)"><Select value={f.agence_id} onChange={(e) => setF({ ...f, agence_id: e.target.value })}><option value="">— central —</option>{agences.map((a) => <option key={a.id} value={a.id}>{a.code} — {a.libelle}</option>)}</Select></Field>
          <Field label="Montant minimum"><Input type="number" min={0} value={f.montant_min} onChange={(e) => setF({ ...f, montant_min: e.target.value })} /></Field>
          <Field label="Montant maximum" hint="Vide : sans plafond. Au-delà, le dossier relève d'un comité supérieur."><Input type="number" min={1} value={f.montant_max} onChange={(e) => setF({ ...f, montant_max: e.target.value })} /></Field>
          <Field label="Quorum" hint="Nombre minimal de membres avec voix présents (et majorité des membres)"><Input type="number" min={1} max={20} value={f.quorum} onChange={(e) => setF({ ...f, quorum: e.target.value })} required /></Field>
        </FormModal>
      )}
      {voir !== null && <ComiteMembres id={voir} peutGerer={peutGerer} onClose={() => { setVoir(null); q.reload() }} />}
    </Card>
  )
}

function ComiteMembres({ id, peutGerer, onClose }: { id: number; peutGerer: boolean; onClose: () => void }) {
  const q = useFetch(() => api.get<Comite & { membres: Membre[] }>(`/api/comites/${id}`), [id])
  const personnes = useFetch(() => api.get<Personne[]>('/api/comites/utilisateurs/liste'), [])
  const { run, busy } = useAction()
  const [f, setF] = useState({ utilisateur_id: '', fonction: 'membre', avec_voix: true })
  return (
    <Modal titre="Membres du comité" onClose={onClose} large footer={<Button onClick={onClose}>Fermer</Button>}>
      <Charge q={q}>
        {(c) => (
          <div className="stack">
            <div><strong>{c.code}</strong> — {c.libelle} · quorum {c.quorum}</div>
            <Table rows={c.membres} vide="Aucun membre" cols={[
              { titre: 'Nom', render: (m) => <span style={{ textDecoration: m.jusqua ? 'line-through' : undefined }}>{m.nom}</span> },
              { titre: 'Fonction', render: (m) => FONCTION[m.fonction] },
              { titre: 'Voix', render: (m) => (m.avec_voix ? 'Délibérative' : 'Consultative') },
              { titre: 'Depuis', render: (m) => fdate(m.depuis) },
              { titre: '', render: (m) => (m.jusqua ? <span className="muted">retiré le {fdate(m.jusqua)}</span> : peutGerer ? <Button small variant="danger" disabled={busy} onClick={() => void run(() => api.post(`/api/comites/${id}/membres/${m.id}/retirer`), 'Membre retiré', q.reload)}>Retirer</Button> : null) },
            ]} />
            {peutGerer && (
              <div className="row" style={{ gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
                <Select value={f.utilisateur_id} onChange={(e) => setF({ ...f, utilisateur_id: e.target.value })} aria-label="Utilisateur"><option value="">Ajouter…</option>{personnes.data?.map((p) => <option key={p.id} value={p.id}>{p.nom} ({p.login})</option>)}</Select>
                <Select value={f.fonction} onChange={(e) => setF({ ...f, fonction: e.target.value })} aria-label="Fonction"><option value="membre">Membre</option><option value="secretaire">Secrétaire</option><option value="president">Président</option></Select>
                <label className="row" style={{ gap: 4 }}><input type="checkbox" checked={f.avec_voix} onChange={(e) => setF({ ...f, avec_voix: e.target.checked })} /> Voix délibérative</label>
                <Button variant="primary" disabled={busy || !f.utilisateur_id} onClick={() => void run(() => api.post(`/api/comites/${id}/membres`, { utilisateur_id: Number(f.utilisateur_id), fonction: f.fonction, avec_voix: f.avec_voix }), 'Membre ajouté', () => { setF({ ...f, utilisateur_id: '' }); q.reload() })}>Ajouter</Button>
              </div>
            )}
          </div>
        )}
      </Charge>
    </Modal>
  )
}

/* ------------------------------------------------------------------ délégations */
function Delegations({ peutAccorder }: { peutAccorder: boolean }) {
  const q = useFetch(() => api.get<Delegation[]>('/api/comites/delegations/liste'), [])
  const personnes = useFetch(() => api.get<Personne[]>('/api/comites/utilisateurs/liste'), [])
  const { run, busy } = useAction()
  const [nouvelle, setNouvelle] = useState(false)
  const [f, setF] = useState({ utilisateur_id: '', credit: '', periode_max: '', periode: 'mois', fin: '', motif: '' })
  return (
    <Card flush actions={peutAccorder ? <Button variant="primary" onClick={() => setNouvelle(true)}>Accorder une délégation</Button> : undefined}>
      <Alert tone="info">Une délégation permet à son bénéficiaire de décider seul un crédit, dans la limite d'un montant par crédit et d'un cumul par période, quand le paramètre « comité de crédit obligatoire » est actif.</Alert>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucune délégation" cols={[
            { titre: 'Bénéficiaire', render: (d) => <strong>{d.nom}</strong> },
            { titre: 'Par crédit', render: (d) => <Money v={d.montant_max_credit} /> },
            { titre: 'Cumul', render: (d) => (d.montant_max_periode ? <span><Money v={d.montant_max_periode} /> / {d.periode}</span> : 'sans plafond') },
            { titre: 'Période', render: (d) => `${fdate(d.debut)} → ${d.fin ? fdate(d.fin) : '…'}` },
            { titre: 'Motif', render: (d) => d.motif },
            { titre: 'Accordée par', render: (d) => d.accordee_par_login },
            { titre: 'État', render: (d) => (d.active ? <Badge tone="ok">Active</Badge> : <Badge tone="neutre">Terminée</Badge>) },
            { titre: '', render: (d) => (peutAccorder && d.active ? <Button small variant="danger" disabled={busy} onClick={() => void run(() => api.post(`/api/comites/delegations/${d.id}/terminer`), 'Délégation terminée', q.reload)}>Terminer</Button> : null) },
          ]} />
        )}
      </Charge>
      {nouvelle && (
        <FormModal titre="Accorder une délégation" onClose={() => setNouvelle(false)} busy={busy} valider="Accorder"
          onSubmit={() => void run(() => api.post('/api/comites/delegations', { utilisateur_id: Number(f.utilisateur_id), montant_max_credit: Number(f.credit), montant_max_periode: f.periode_max ? Number(f.periode_max) : null, periode: f.periode, fin: f.fin || null, motif: f.motif }), 'Délégation accordée', () => { setNouvelle(false); q.reload() })}>
          <Field label="Bénéficiaire"><Select value={f.utilisateur_id} onChange={(e) => setF({ ...f, utilisateur_id: e.target.value })} required><option value="">— choisir —</option>{personnes.data?.map((p) => <option key={p.id} value={p.id}>{p.nom} ({p.login})</option>)}</Select></Field>
          <Field label="Montant maximum par crédit"><Input type="number" min={1} value={f.credit} onChange={(e) => setF({ ...f, credit: e.target.value })} required /></Field>
          <Field label="Cumul maximum sur la période" hint="Vide : sans plafond de cumul"><Input type="number" min={1} value={f.periode_max} onChange={(e) => setF({ ...f, periode_max: e.target.value })} /></Field>
          <Field label="Période du cumul"><Select value={f.periode} onChange={(e) => setF({ ...f, periode: e.target.value })}><option value="mois">Mois</option><option value="trimestre">Trimestre</option><option value="annee">Année</option></Select></Field>
          <Field label="Fin de la délégation" hint="Vide : jusqu'à retrait"><Input type="date" value={f.fin} onChange={(e) => setF({ ...f, fin: e.target.value })} /></Field>
          <Field label="Motif"><Input value={f.motif} onChange={(e) => setF({ ...f, motif: e.target.value })} minLength={5} required /></Field>
        </FormModal>
      )}
    </Card>
  )
}
