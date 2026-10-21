import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Kpi, Modal, Money, Page, Select, Table, Tabs, useAction, useFetch } from '../components/ui'
import GrhConges from './GrhConges'
import GrhDiscipline, { CertificatModal } from './GrhDiscipline'
import GrhFormation from './GrhFormation'
import GrhRecrutement from './GrhRecrutement'

/** Gestion des ressources humaines : une page, des onglets par domaine. */
export default function Grh() {
  const { can } = useSession()
  const [onglet, setOnglet] = useState('tableau')
  const onglets = [
    { id: 'tableau', titre: 'Tableau de bord' }, { id: 'dossiers', titre: 'Dossiers du personnel' }, { id: 'agents', titre: 'Agents commerciaux' },
    { id: 'organisation', titre: 'Organisation' }, { id: 'conges', titre: 'Congés et présences' }, { id: 'recrutement', titre: 'Recrutement' },
    { id: 'formation', titre: 'Formation et évaluations' },
    ...(can('sanction:write') ? [{ id: 'discipline', titre: 'Discipline et sorties' }] : []),
  ]
  return (
    <Page title="Gestion des ressources humaines" subtitle="Dossiers, organisation, congés, recrutement, formation, évaluations, discipline et sorties">
      <Tabs actif={onglet} onChange={setOnglet} tabs={onglets} />
      {onglet === 'tableau' && <Tableau />}
      {onglet === 'dossiers' && <Dossiers />}
      {onglet === 'agents' && <Agents />}
      {onglet === 'organisation' && <Organisation />}
      {onglet === 'conges' && <GrhConges />}
      {onglet === 'recrutement' && <GrhRecrutement />}
      {onglet === 'formation' && <GrhFormation />}
      {onglet === 'discipline' && <GrhDiscipline />}
    </Page>
  )
}

/* ------------------------------------------------------------------ tableau de bord */
interface Indic {
  agences: { agence: string; effectif: number; masse_salariale: number; anciennete_moyenne_ans: number; absences_du_mois: number; en_conge_aujourdhui: number }[]
  total: { effectif: number; femmes: number; hommes: number; masse_salariale: number; entrees_12m: number; sorties_12m: number; turnover_pct: number; en_conge_aujourdhui: number; absences_du_mois: number; besoins_ouverts: number }
  contrats: { type: string; n: number }[]
}
interface Echeance { nature: string; employe_id: number; matricule: string; nom: string; echeance: string; jours: number; detail: string }
const NATURE: Record<string, string> = { fin_contrat: 'Fin de contrat', fin_essai: "Fin de période d'essai", piece_expire: 'Pièce qui expire' }

export function Tableau() {
  const q = useFetch(() => api.get<Indic>('/api/grh/indicateurs'), [])
  const ech = useFetch(() => api.get<Echeance[]>('/api/grh/echeances'), [])
  return (
    <div className="stack">
      <Charge q={q}>
        {(d) => (
          <>
            <div className="grid-kpi">
              <Kpi label="Effectif" value={d.total.effectif} />
              <Kpi label="Femmes / hommes" value={`${d.total.femmes} / ${d.total.hommes}`} />
              <Kpi label="Masse salariale mensuelle" value={<Money v={d.total.masse_salariale} />} />
              <Kpi label="Turnover 12 mois" value={`${d.total.turnover_pct} %`} tone={d.total.turnover_pct > 20 ? 'warn' : undefined} />
              <Kpi label="En congé aujourd'hui" value={d.total.en_conge_aujourdhui} />
              <Kpi label="Absences du mois" value={d.total.absences_du_mois} />
              <Kpi label="Besoins de recrutement ouverts" value={d.total.besoins_ouverts} />
              <Kpi label="Entrées / sorties (12 mois)" value={`${d.total.entrees_12m} / ${d.total.sorties_12m}`} />
            </div>
            <Card title="Par agence" flush>
              <Table rows={d.agences} cols={[
                { titre: 'Agence', render: (a) => <strong>{a.agence}</strong> },
                { titre: 'Effectif', num: true, render: (a) => a.effectif },
                { titre: 'Masse salariale', num: true, render: (a) => xof(a.masse_salariale) },
                { titre: 'Ancienneté moyenne', num: true, render: (a) => `${a.anciennete_moyenne_ans} ans` },
                { titre: 'En congé', num: true, render: (a) => a.en_conge_aujourdhui },
                { titre: 'Absences du mois', num: true, render: (a) => a.absences_du_mois },
              ]} />
            </Card>
            <Card title="Types de contrat en cours">{d.contrats.map((c) => <Badge key={c.type}>{c.type.toUpperCase()} : {c.n}</Badge>)}</Card>
          </>
        )}
      </Charge>
      <Card title="Échéances à surveiller" flush>
        <Charge q={ech}>
          {(rows) => (
            <Table rows={rows} vide="Aucune échéance proche" cols={[
              { titre: 'Nature', render: (e) => NATURE[e.nature] ?? e.nature },
              { titre: 'Employé', render: (e) => <span><strong>{e.nom}</strong> <span className="muted">{e.matricule}</span></span> },
              { titre: 'Détail', render: (e) => e.detail },
              { titre: 'Échéance', render: (e) => `${fdate(e.echeance)} (dans ${e.jours} j)` },
            ]} />
          )}
        </Charge>
      </Card>
    </div>
  )
}

/* ------------------------------------------------------------------ dossiers */
interface Emp { id: number; matricule: string; nom: string; poste: string | null; date_embauche: string; statut: string; salaire_base: number | null }
interface Dossier {
  id: number; matricule: string; nom: string; statut: string; date_embauche: string; date_sortie: string | null; poste_libelle: string | null; service: string | null; superieur: string | null
  sexe: string | null; date_naissance: string | null; telephone: string | null; email: string | null; adresse: string | null; situation_familiale: string | null; nb_enfants: number
  urgence_nom: string | null; urgence_telephone: string | null; piece_identite: string | null; numero_cnss: string | null; banque: string | null; numero_compte: string | null
  contrats: { id: number; type: string; date_debut: string; date_fin: string | null; salaire_base: number; periode_essai_fin: string | null }[]
  documents: { id: number; type: string; libelle: string; reference: string | null; date_expiration: string | null }[]
  conges: { id: number; type: string; date_debut: string; date_fin: string; statut: string; jours_ouvres: number }[]
  solde_conges: { acquis: number; solde: number }
  sanctions: { id: number; type: string; date_faits: string; statut: string; motif: string }[]
  formations: { titre: string; date_debut: string; statut: string; certificat_ref: string | null }[]
  evaluations: { id: number; campagne: string; statut: string; note_globale: number | null; decision: string | null }[]
}

function Dossiers() {
  const q = useFetch(() => api.get<Emp[]>('/api/employes'), [])
  const [ouvert, setOuvert] = useState<number | null>(null)
  const [filtre, setFiltre] = useState('')
  return (
    <Card flush actions={<Input placeholder="Nom ou matricule" value={filtre} onChange={(e) => setFiltre(e.target.value)} style={{ width: 200 }} />}>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows.filter((e) => `${e.nom} ${e.matricule}`.toLowerCase().includes(filtre.toLowerCase()))} vide="Aucun employé" onRowClick={(e) => setOuvert(e.id)} cols={[
            { titre: 'Matricule', render: (e) => e.matricule },
            { titre: 'Nom', render: (e) => <strong>{e.nom}</strong> },
            { titre: 'Poste', render: (e) => e.poste ?? '—' },
            { titre: 'Embauche', render: (e) => fdate(e.date_embauche) },
            { titre: 'Statut', render: (e) => <Badge tone={e.statut === 'actif' ? 'ok' : 'neutre'}>{e.statut}</Badge> },
          ]} />
        )}
      </Charge>
      {ouvert !== null && <DossierModal id={ouvert} onClose={() => setOuvert(null)} />}
    </Card>
  )
}

function DossierModal({ id, onClose }: { id: number; onClose: () => void }) {
  const { can } = useSession()
  const q = useFetch(() => api.get<Dossier>(`/api/grh/employes/${id}`), [id])
  const { run, busy } = useAction()
  const [doc, setDoc] = useState(false)
  const [edition, setEdition] = useState(false)
  const [certificat, setCertificat] = useState<Parameters<typeof CertificatModal>[0]['c'] | null>(null)
  const [d, setD] = useState({ type: 'identite', libelle: '', reference: '', expiration: '' })
  const [f, setF] = useState<Record<string, string>>({})
  return (
    <Modal titre="Dossier du personnel" onClose={onClose} large footer={<Button onClick={onClose}>Fermer</Button>}>
      <Charge q={q}>
        {(e) => (
          <div className="stack">
            <div className="row" style={{ gap: 12, alignItems: 'center', flexWrap: 'wrap' }}>
              <strong style={{ fontSize: 18 }}>{e.nom}</strong><span className="muted">{e.matricule}</span>
              <Badge tone={e.statut === 'actif' ? 'ok' : 'neutre'}>{e.statut}</Badge><span>{e.poste_libelle ?? '—'}{e.service ? ` · ${e.service}` : ''}</span>
              <span className="spacer" />
              {can('grh:write') && <Button small onClick={() => { setF({ telephone: e.telephone ?? '', email: e.email ?? '', adresse: e.adresse ?? '', numero_cnss: e.numero_cnss ?? '', urgence_nom: e.urgence_nom ?? '', urgence_telephone: e.urgence_telephone ?? '', banque: e.banque ?? '', numero_compte: e.numero_compte ?? '' }); setEdition(true) }}>Modifier</Button>}
              {can('grh:write') && <Button small onClick={() => void api.get<Parameters<typeof CertificatModal>[0]['c']>(`/api/grh/employes/${id}/certificat-travail`).then(setCertificat)}>{e.statut === 'sorti' ? 'Certificat de travail' : 'Attestation de travail'}</Button>}
            </div>
            <div className="row" style={{ gap: 24, flexWrap: 'wrap' }}>
              <span>Embauche : <strong>{fdate(e.date_embauche)}</strong>{e.date_sortie ? ` · sortie ${fdate(e.date_sortie)}` : ''}</span>
              <span>Supérieur : <strong>{e.superieur ?? '—'}</strong></span>
              <span>Congés : <strong>{e.solde_conges.solde} j</strong> de solde ({e.solde_conges.acquis} acquis)</span>
              <span>Tél. {e.telephone ?? '—'} · {e.email ?? 'sans e-mail'}</span>
              <span>CNSS : {e.numero_cnss ?? '—'}</span>
            </div>
            <Card title="Contrats" flush><Table rows={e.contrats} vide="Aucun contrat" cols={[
              { titre: 'Type', render: (c) => c.type.toUpperCase() }, { titre: 'Début', render: (c) => fdate(c.date_debut) }, { titre: 'Fin', render: (c) => (c.date_fin ? fdate(c.date_fin) : '—') },
              { titre: "Essai jusqu'au", render: (c) => (c.periode_essai_fin ? fdate(c.periode_essai_fin) : '—') }, { titre: 'Salaire de base', num: true, render: (c) => xof(c.salaire_base) },
            ]} /></Card>
            <Card title="Pièces du dossier" flush actions={can('grh:write') && <Button small onClick={() => setDoc(true)}>Ajouter une pièce</Button>}><Table rows={e.documents} vide="Aucune pièce" cols={[
              { titre: 'Type', render: (x) => x.type }, { titre: 'Libellé', render: (x) => x.libelle }, { titre: 'Référence', render: (x) => x.reference ?? '' },
              { titre: 'Expiration', render: (x) => (x.date_expiration ? fdate(x.date_expiration) : '—') },
            ]} /></Card>
            <Card title="Congés récents" flush><Table rows={e.conges} vide="Aucun congé" cols={[
              { titre: 'Type', render: (c) => c.type }, { titre: 'Période', render: (c) => `${fdate(c.date_debut)} → ${fdate(c.date_fin)}` }, { titre: 'Jours', num: true, render: (c) => c.jours_ouvres }, { titre: 'Statut', render: (c) => c.statut },
            ]} /></Card>
            <Card title="Formations, évaluations, sanctions" flush>
              <Table rows={[
                ...e.formations.map((x) => ({ k: `f${x.titre}${x.date_debut}`, nature: 'Formation', libelle: x.titre, detail: `${x.statut}${x.certificat_ref ? ` — ${x.certificat_ref}` : ''}`, date: x.date_debut })),
                ...e.evaluations.map((x) => ({ k: `e${x.id}`, nature: 'Évaluation', libelle: x.campagne, detail: `${x.statut}${x.note_globale !== null ? ` — ${x.note_globale}/10` : ''}${x.decision ? ` — ${x.decision}` : ''}`, date: '' })),
                ...e.sanctions.map((x) => ({ k: `s${x.id}`, nature: 'Sanction', libelle: x.type.replace(/_/g, ' '), detail: `${x.statut} — ${x.motif}`, date: x.date_faits })),
              ]} vide="Rien à signaler" cols={[
                { titre: 'Nature', render: (x) => x.nature }, { titre: 'Libellé', render: (x) => x.libelle }, { titre: 'Détail', render: (x) => x.detail }, { titre: 'Date', render: (x) => (x.date ? fdate(x.date) : '') },
              ]} />
            </Card>
            {certificat && <CertificatModal c={certificat} onClose={() => setCertificat(null)} />}
            {doc && (
              <FormModal titre="Nouvelle pièce" onClose={() => setDoc(false)} busy={busy} valider="Ajouter"
                onSubmit={() => void run(() => api.post(`/api/grh/employes/${id}/documents`, { type: d.type, libelle: d.libelle, reference: d.reference || null, date_expiration: d.expiration || null }), 'Pièce ajoutée', () => { setDoc(false); q.reload() })}>
                <Field label="Type"><Select value={d.type} onChange={(x) => setD({ ...d, type: x.target.value })}>{['identite', 'diplome', 'contrat', 'cnss', 'certificat_medical', 'casier_judiciaire', 'attestation', 'photo', 'autre'].map((t) => <option key={t} value={t}>{t.replace(/_/g, ' ')}</option>)}</Select></Field>
                <Field label="Libellé"><Input value={d.libelle} onChange={(x) => setD({ ...d, libelle: x.target.value })} required /></Field>
                <Field label="Référence"><Input value={d.reference} onChange={(x) => setD({ ...d, reference: x.target.value })} /></Field>
                <Field label="Date d'expiration"><Input type="date" value={d.expiration} onChange={(x) => setD({ ...d, expiration: x.target.value })} /></Field>
              </FormModal>
            )}
            {edition && (
              <FormModal titre="Modifier le dossier" onClose={() => setEdition(false)} busy={busy}
                onSubmit={() => void run(() => api.patch(`/api/grh/employes/${id}`, Object.fromEntries(Object.entries(f).map(([k, v]) => [k, v || null]))), 'Dossier mis à jour', () => { setEdition(false); q.reload() })}>
                {[['telephone', 'Téléphone'], ['email', 'E-mail'], ['adresse', 'Adresse'], ['numero_cnss', 'N° CNSS'], ['urgence_nom', 'Personne à prévenir'], ['urgence_telephone', 'Téléphone de la personne à prévenir'], ['banque', 'Banque'], ['numero_compte', 'N° de compte']].map(([k, l]) => (
                  <Field key={k} label={l}><Input value={f[k] ?? ''} onChange={(x) => setF({ ...f, [k]: x.target.value })} /></Field>
                ))}
              </FormModal>
            )}
          </div>
        )}
      </Charge>
    </Modal>
  )
}

/* ------------------------------------------------------------------ agents commerciaux */
interface AgentRh { agent_id: number; matricule: string; nom: string; actif: boolean; employe_id: number | null; statut_rh: string | null; date_embauche: string | null; salaire_base: number | null; nb_zones: number; nb_clients: number; collecte_du_mois: number; poste: string | null }

export function Agents() {
  const { can } = useSession()
  const q = useFetch(() => api.get<AgentRh[]>('/api/grh/agents'), [])
  const { run, busy } = useAction()
  const [dossier, setDossier] = useState<number | null>(null)
  return (
    <Card flush>
      <Alert tone="info">Les agents commerciaux collectent sur le terrain. Un agent sans fiche RH n'a ni dossier, ni contrat, ni congé : « Créer la fiche RH » l'ajoute au personnel (même matricule, poste « Agent commercial »).</Alert>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucun agent commercial" cols={[
            { titre: 'Matricule', render: (a) => a.matricule },
            { titre: 'Agent', render: (a) => <strong>{a.nom}</strong> },
            { titre: 'Zones', num: true, render: (a) => a.nb_zones },
            { titre: 'Clients', num: true, render: (a) => a.nb_clients },
            { titre: 'Collecte du mois', num: true, render: (a) => xof(a.collecte_du_mois) },
            { titre: 'Fiche RH', render: (a) => (a.employe_id ? <Badge tone="ok">Oui — embauché le {fdate(a.date_embauche)}</Badge> : <Badge tone="warn">Sans fiche RH</Badge>) },
            { titre: 'Salaire de base', num: true, render: (a) => (a.salaire_base === null ? '—' : xof(a.salaire_base)) },
            { titre: '', render: (a) => (a.employe_id ? <Button small onClick={() => setDossier(a.employe_id!)}>Dossier</Button> : can('grh:write') && (
              <Button small variant="primary" disabled={busy} onClick={() => void run(() => api.post(`/api/grh/agents/${a.agent_id}/fiche-rh`, { date_embauche: aujourdhui() }), 'Fiche RH créée', q.reload)}>Créer la fiche RH</Button>
            )) },
          ]} />
        )}
      </Charge>
      {dossier !== null && <DossierModal id={dossier} onClose={() => setDossier(null)} />}
    </Card>
  )
}

/* ------------------------------------------------------------------ organisation */
interface Service { id: number; code: string; libelle: string; parent: string | null; effectif: number }
interface Poste { id: number; code: string; libelle: string; service: string | null; salaire_min: number | null; salaire_max: number | null; effectif_prevu: number; effectif: number }
interface Noeud { id: number; matricule: string; nom: string; niveau: number; poste: string | null; service: string | null }

function Organisation() {
  const { can } = useSession()
  const services = useFetch(() => api.get<Service[]>('/api/grh/services'), [])
  const postes = useFetch(() => api.get<Poste[]>('/api/grh/postes'), [])
  const org = useFetch(() => api.get<Noeud[]>('/api/grh/organigramme'), [])
  const { run, busy } = useAction()
  const [sv, setSv] = useState<null | { code: string; libelle: string }>(null)
  const [ps, setPs] = useState<null | { code: string; libelle: string; min: string; max: string; prevu: string }>(null)
  return (
    <div className="stack">
      <Card title="Services" flush actions={can('grh:write') && <Button small onClick={() => setSv({ code: '', libelle: '' })}>Nouveau service</Button>}>
        <Charge q={services}>{(r) => <Table rows={r} vide="Aucun service" cols={[
          { titre: 'Code', render: (s) => <strong>{s.code}</strong> }, { titre: 'Libellé', render: (s) => s.libelle }, { titre: 'Rattaché à', render: (s) => s.parent ?? '—' }, { titre: 'Effectif', num: true, render: (s) => s.effectif },
        ]} />}</Charge>
      </Card>
      <Card title="Postes (fiches de poste)" flush actions={can('grh:write') && <Button small onClick={() => setPs({ code: '', libelle: '', min: '', max: '', prevu: '1' })}>Nouveau poste</Button>}>
        <Charge q={postes}>{(r) => <Table rows={r} vide="Aucun poste" cols={[
          { titre: 'Code', render: (p) => <strong>{p.code}</strong> }, { titre: 'Poste', render: (p) => p.libelle }, { titre: 'Service', render: (p) => p.service ?? '—' },
          { titre: 'Fourchette de salaire', render: (p) => (p.salaire_min || p.salaire_max ? `${p.salaire_min ? xof(p.salaire_min) : '…'} → ${p.salaire_max ? xof(p.salaire_max) : '…'}` : '—') },
          { titre: 'Effectif / prévu', num: true, render: (p) => `${p.effectif} / ${p.effectif_prevu}` },
        ]} />}</Charge>
      </Card>
      <Card title="Organigramme">
        <Charge q={org}>{(r) => (r.length === 0 ? <p className="muted">Renseignez le supérieur direct dans les dossiers pour construire l'organigramme.</p> : (
          <div>{r.map((n) => <div key={n.id} style={{ padding: `2px 0 2px ${n.niveau * 24}px` }}>{n.niveau > 0 ? '└ ' : ''}<strong>{n.nom}</strong> <span className="muted">{n.matricule}{n.poste ? ` · ${n.poste}` : ''}{n.service ? ` · ${n.service}` : ''}</span></div>)}</div>
        ))}</Charge>
      </Card>
      {sv && <FormModal titre="Nouveau service" onClose={() => setSv(null)} busy={busy} onSubmit={() => void run(() => api.post('/api/grh/services', sv), 'Service créé', () => { setSv(null); services.reload() })}>
        <Field label="Code"><Input value={sv.code} maxLength={15} onChange={(e) => setSv({ ...sv, code: e.target.value })} required autoFocus /></Field>
        <Field label="Libellé"><Input value={sv.libelle} onChange={(e) => setSv({ ...sv, libelle: e.target.value })} required /></Field>
      </FormModal>}
      {ps && <FormModal titre="Nouveau poste" onClose={() => setPs(null)} busy={busy} onSubmit={() => void run(() => api.post('/api/grh/postes', { code: ps.code, libelle: ps.libelle, salaire_min: ps.min ? Number(ps.min) : null, salaire_max: ps.max ? Number(ps.max) : null, effectif_prevu: Number(ps.prevu) }), 'Poste créé', () => { setPs(null); postes.reload() })}>
        <Field label="Code"><Input value={ps.code} maxLength={15} onChange={(e) => setPs({ ...ps, code: e.target.value })} required autoFocus /></Field>
        <Field label="Libellé"><Input value={ps.libelle} onChange={(e) => setPs({ ...ps, libelle: e.target.value })} required /></Field>
        <Field label="Salaire minimum"><Input type="number" min={0} value={ps.min} onChange={(e) => setPs({ ...ps, min: e.target.value })} /></Field>
        <Field label="Salaire maximum" hint="Les embauches doivent rester dans la fourchette"><Input type="number" min={0} value={ps.max} onChange={(e) => setPs({ ...ps, max: e.target.value })} /></Field>
        <Field label="Effectif prévu"><Input type="number" min={0} value={ps.prevu} onChange={(e) => setPs({ ...ps, prevu: e.target.value })} /></Field>
      </FormModal>}
    </div>
  )
}
