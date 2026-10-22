import { useState } from 'react'
import { api } from '../lib/api'
import { date as fdate } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Page, Select, Table, Tabs, useAction, useFetch } from '../components/ui'

interface Role { code: string; libelle: string; systeme: boolean; actif: boolean; nb_droits?: number; nb_utilisateurs_base?: number }
interface Permission { code: string; categorie: string; roles: string[] }
interface Matrice { roles: Role[]; permissions: Permission[] }
interface Affectation {
  id: number; statut: string; utilisateur_nom: string; login: string; role_code: string; role_libelle: string; agence: string; date_debut: string; date_fin: string
  motif: string; demande_par_nom: string | null; valide_par_nom: string | null; commentaire_decision: string | null; en_cours: boolean
}
interface Personne { id: number; login: string; nom: string; role: string; agence_id: number | null }

const STATUTS: Record<string, { texte: string; tone: 'ok' | 'warn' | 'bad' | 'neutre' }> = {
  demandee: { texte: 'En attente', tone: 'warn' }, active: { texte: 'Active', tone: 'ok' }, refusee: { texte: 'Refusée', tone: 'bad' }, revoquee: { texte: 'Révoquée', tone: 'neutre' },
}

/** Attribution des rôles : matrice de droits, rôles personnalisés et affectations temporaires soumises à validation. */
export default function Roles() {
  const { can } = useSession()
  const [onglet, setOnglet] = useState('affectations')
  return (
    <Page title="Rôles et droits" subtitle="Qui peut faire quoi. Une affectation temporaire d’un rôle est demandée puis validée par un autre responsable.">
      <Tabs actif={onglet} onChange={setOnglet} tabs={[
        { id: 'affectations', titre: 'Affectations' },
        { id: 'matrice', titre: 'Matrice des droits' },
        ...(can('roles:gerer') ? [{ id: 'roles', titre: 'Rôles' }] : []),
      ]} />
      {onglet === 'affectations' && <Affectations />}
      {onglet === 'matrice' && <MatriceDroits />}
      {onglet === 'roles' && <GestionRoles />}
    </Page>
  )
}

function Affectations() {
  const { can, agenceId } = useSession()
  const [statut, setStatut] = useState('')
  const [demande, setDemande] = useState(false)
  const [decision, setDecision] = useState<{ a: Affectation; accepte: boolean } | null>(null)
  const [revocation, setRevocation] = useState<Affectation | null>(null)
  const liste = useFetch(() => api.get<Affectation[]>('/api/affectations-roles', { statut }), [statut, agenceId])
  return (
    <Card flush actions={can('roles:demander') && <Button variant="primary" onClick={() => setDemande(true)}>Demander un rôle temporaire</Button>}>
      <Alert tone="info">Le rôle temporaire ne prend effet qu’à sa validation, pour les dates prévues, dans l’agence indiquée. Celui qui demande ne peut pas le valider.</Alert>
      <div className="card-b row">
        <Field label="Statut"><Select value={statut} onChange={(e) => setStatut(e.target.value)}><option value="">Tous</option>{Object.entries(STATUTS).map(([k, v]) => <option key={k} value={k}>{v.texte}</option>)}</Select></Field>
      </div>
      <Charge q={liste}>
        {(rows) => (
          <Table rows={rows} vide="Aucune affectation" cols={[
            { titre: 'Personne', render: (a) => <><strong>{a.utilisateur_nom}</strong><div className="muted">{a.login}</div></> },
            { titre: 'Rôle temporaire', render: (a) => a.role_libelle }, { titre: 'Agence', render: (a) => a.agence },
            { titre: 'Période', render: (a) => `${fdate(a.date_debut)} → ${fdate(a.date_fin)}` },
            { titre: 'Motif', render: (a) => a.motif },
            { titre: 'Statut', render: (a) => <><Badge tone={STATUTS[a.statut]?.tone ?? 'neutre'}>{STATUTS[a.statut]?.texte ?? a.statut}</Badge>{a.en_cours && <> <Badge tone="info">En cours</Badge></>}</> },
            { titre: 'Demandé par', render: (a) => a.demande_par_nom ?? '' }, { titre: 'Validé par', render: (a) => a.valide_par_nom ?? '' },
            { titre: '', render: (a) => (
              <span className="row">
                {a.statut === 'demandee' && can('roles:valider') && <Button small variant="primary" onClick={() => setDecision({ a, accepte: true })}>Valider</Button>}
                {a.statut === 'demandee' && can('roles:valider') && <Button small variant="danger" onClick={() => setDecision({ a, accepte: false })}>Refuser</Button>}
                {a.statut === 'active' && can('roles:valider') && <Button small onClick={() => setRevocation(a)}>Révoquer</Button>}
              </span>
            ) },
          ]} />
        )}
      </Charge>
      {demande && <DemandeRole onClose={() => setDemande(false)} onFait={() => { setDemande(false); liste.reload() }} />}
      {decision && <DecisionRole {...decision} onClose={() => setDecision(null)} onFait={() => { setDecision(null); liste.reload() }} />}
      {revocation && <RevocationRole a={revocation} onClose={() => setRevocation(null)} onFait={() => { setRevocation(null); liste.reload() }} />}
    </Card>
  )
}

function DemandeRole({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const { agenceId } = useSession()
  const personnes = useFetch(() => api.get<Personne[]>('/api/roles/utilisateurs'), [agenceId])
  const roles = useFetch(() => api.get<Role[]>('/api/roles'), [])
  const { run, busy } = useAction()
  const aujourdhui = new Date().toISOString().slice(0, 10)
  const [f, setF] = useState({ utilisateur: '', role: '', agence: '', debut: aujourdhui, fin: '', motif: '' })
  return (
    <FormModal titre="Demander un rôle temporaire" onClose={onClose} busy={busy} valider="Envoyer la demande" large
      onSubmit={() => void run(() => api.post('/api/affectations-roles', {
        utilisateur_id: Number(f.utilisateur), role_code: f.role, agence_id: Number(f.agence), date_debut: f.debut, date_fin: f.fin, motif: f.motif.trim(),
      }), 'Demande envoyée : un autre responsable doit la valider', onFait)}>
      <Field label="Personne"><Select value={f.utilisateur} onChange={(e) => setF({ ...f, utilisateur: e.target.value })} required><option value="">— choisir —</option>{personnes.data?.map((p) => <option key={p.id} value={p.id}>{p.nom} ({p.login})</option>)}</Select></Field>
      <Field label="Rôle temporaire"><Select value={f.role} onChange={(e) => setF({ ...f, role: e.target.value })} required><option value="">— choisir —</option>{roles.data?.filter((r) => r.actif).map((r) => <option key={r.code} value={r.code}>{r.libelle}</option>)}</Select></Field>
      <Field label="Agence" hint="Une agence de la personne"><Input value={f.agence} onChange={(e) => setF({ ...f, agence: e.target.value })} placeholder="Identifiant de l’agence" required /></Field>
      <div className="row">
        <Field label="Du"><Input type="date" value={f.debut} min={aujourdhui} onChange={(e) => setF({ ...f, debut: e.target.value })} required /></Field>
        <Field label="Au" hint="Six mois au plus"><Input type="date" value={f.fin} min={f.debut} onChange={(e) => setF({ ...f, fin: e.target.value })} required /></Field>
      </div>
      <Field label="Motif"><Input value={f.motif} minLength={10} onChange={(e) => setF({ ...f, motif: e.target.value })} required /></Field>
    </FormModal>
  )
}

function DecisionRole({ a, accepte, onClose, onFait }: { a: Affectation; accepte: boolean; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [commentaire, setCommentaire] = useState('')
  return (
    <FormModal titre={accepte ? 'Valider le rôle temporaire' : 'Refuser le rôle temporaire'} onClose={onClose} busy={busy} valider={accepte ? 'Valider' : 'Refuser'}
      onSubmit={() => void run(() => api.post(`/api/affectations-roles/${a.id}/decider`, { accepte, commentaire: commentaire.trim() || null }), accepte ? 'Rôle activé' : 'Demande refusée', onFait)}>
      <p style={{ margin: 0 }}>{a.role_libelle} pour {a.utilisateur_nom}, agence {a.agence}, du {fdate(a.date_debut)} au {fdate(a.date_fin)}.</p>
      <p style={{ margin: 0 }} className="muted">Motif : {a.motif}</p>
      <Field label={accepte ? 'Commentaire (facultatif)' : 'Raison du refus (obligatoire)'}><Input value={commentaire} onChange={(e) => setCommentaire(e.target.value)} required={!accepte} minLength={accepte ? 0 : 5} /></Field>
    </FormModal>
  )
}

function RevocationRole({ a, onClose, onFait }: { a: Affectation; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [motif, setMotif] = useState('')
  return (
    <FormModal titre="Révoquer le rôle temporaire" onClose={onClose} busy={busy} valider="Révoquer"
      onSubmit={() => void run(() => api.post(`/api/affectations-roles/${a.id}/revoquer`, { motif: motif.trim() }), 'Rôle révoqué : effet immédiat', onFait)}>
      <p style={{ margin: 0 }}>{a.role_libelle} de {a.utilisateur_nom} est retiré immédiatement.</p>
      <Field label="Motif de la révocation"><Input value={motif} minLength={5} onChange={(e) => setMotif(e.target.value)} required /></Field>
    </FormModal>
  )
}

function MatriceDroits() {
  const { agenceId } = useSession()
  const [categorie, setCategorie] = useState('')
  const [q, setQ] = useState('')
  const m = useFetch(() => api.get<Matrice>('/api/roles/matrice'), [agenceId])
  return (
    <Card flush>
      <div className="card-b row">
        <Field label="Recherche"><Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Permission" /></Field>
        <Field label="Catégorie"><Select value={categorie} onChange={(e) => setCategorie(e.target.value)}><option value="">Toutes</option>{[...new Set((m.data?.permissions ?? []).map((p) => p.categorie))].sort().map((c) => <option key={c} value={c}>{c}</option>)}</Select></Field>
      </div>
      <Charge q={m}>
        {(d) => (
          <Table rows={d.permissions.filter((p) => (!categorie || p.categorie === categorie) && p.code.includes(q.trim().toLowerCase()))} vide="Aucune permission" cols={[
            { titre: 'Permission', render: (p) => <code>{p.code}</code> },
            { titre: 'Rôles qui l’ont', render: (p) => (p.roles.length === 0 ? <span className="muted">aucun</span> : p.roles.map((r) => <span key={r} style={{ marginRight: 6 }}><Badge tone="neutre">{d.roles.find((x) => x.code === r)?.libelle ?? r}</Badge></span>)) },
          ]} />
        )}
      </Charge>
    </Card>
  )
}

function GestionRoles() {
  const { agenceId } = useSession()
  const roles = useFetch(() => api.get<Role[]>('/api/roles'), [agenceId])
  const matrice = useFetch(() => api.get<Matrice>('/api/roles/matrice'), [agenceId])
  const [creation, setCreation] = useState(false)
  const [editeDroits, setEditeDroits] = useState<Role | null>(null)
  const { run, busy } = useAction()
  return (
    <Card flush actions={<Button variant="primary" onClick={() => setCreation(true)}>Nouveau rôle</Button>}>
      <Charge q={roles}>
        {(rows) => (
          <Table rows={rows} vide="Aucun rôle" cols={[
            { titre: 'Rôle', render: (r) => <><strong>{r.libelle}</strong><div className="muted">{r.code}</div></> },
            { titre: 'Origine', render: (r) => (r.systeme ? <Badge tone="neutre">D’origine</Badge> : <Badge tone="info">Personnalisé</Badge>) },
            { titre: 'Permissions', num: true, render: (r) => r.nb_droits ?? 0 },
            { titre: 'Utilisateurs (rôle de base)', num: true, render: (r) => r.nb_utilisateurs_base ?? 0 },
            { titre: 'État', render: (r) => <Badge tone={r.actif ? 'ok' : 'neutre'}>{r.actif ? 'Actif' : 'Désactivé'}</Badge> },
            { titre: '', render: (r) => (
              <span className="row">
                <Button small onClick={() => setEditeDroits(r)}>Permissions</Button>
                {r.code !== 'admin' && <Button small disabled={busy} onClick={() => void run(() => api.patch(`/api/roles/${r.code}`, { actif: !r.actif }), r.actif ? 'Rôle désactivé' : 'Rôle réactivé', roles.reload)}>{r.actif ? 'Désactiver' : 'Réactiver'}</Button>}
              </span>
            ) },
          ]} />
        )}
      </Charge>
      {creation && <CreationRole onClose={() => setCreation(false)} onFait={() => { setCreation(false); roles.reload() }} />}
      {editeDroits && matrice.data && <EditionDroits role={editeDroits} permissions={matrice.data.permissions} onClose={() => setEditeDroits(null)} onFait={() => { setEditeDroits(null); roles.reload(); matrice.reload() }} />}
    </Card>
  )
}

function CreationRole({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ code: '', libelle: '' })
  return (
    <FormModal titre="Nouveau rôle" onClose={onClose} busy={busy} valider="Créer"
      onSubmit={() => void run(() => api.post('/api/roles', { code: f.code, libelle: f.libelle.trim() }), 'Rôle créé : définissez ses permissions', onFait)}>
      <Field label="Code" hint="minuscules, chiffres et _"><Input value={f.code} pattern="[a-z0-9_]{2,30}" onChange={(e) => setF({ ...f, code: e.target.value })} required /></Field>
      <Field label="Libellé"><Input value={f.libelle} minLength={3} onChange={(e) => setF({ ...f, libelle: e.target.value })} required /></Field>
    </FormModal>
  )
}

function EditionDroits({ role, permissions, onClose, onFait }: { role: Role; permissions: Permission[]; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [coches, setCoches] = useState<Set<string>>(new Set(permissions.filter((p) => p.roles.includes(role.code)).map((p) => p.code)))
  const bascule = (code: string) => setCoches((s) => { const n = new Set(s); if (n.has(code)) n.delete(code); else n.add(code); return n })
  const categories = [...new Set(permissions.map((p) => p.categorie))].sort()
  return (
    <FormModal titre={`Permissions de « ${role.libelle} »`} onClose={onClose} busy={busy} valider="Enregistrer" large
      onSubmit={() => void run(() => api.put(`/api/roles/${role.code}/droits`, { permissions: [...coches] }), 'Permissions enregistrées : effet immédiat', onFait)}>
      <Alert tone="warn">Les changements prennent effet immédiatement pour toutes les personnes ayant ce rôle. L’administrateur garde toujours la gestion des rôles.</Alert>
      {categories.map((c) => (
        <div key={c} className="stack">
          <strong>{c}</strong>
          <div className="row" style={{ flexWrap: 'wrap', gap: 12 }}>
            {permissions.filter((p) => p.categorie === c).map((p) => (
              <label key={p.code} className="row" style={{ gap: 6, alignItems: 'center' }}>
                <input type="checkbox" checked={coches.has(p.code)} onChange={() => bascule(p.code)} /> <code>{p.code}</code>
              </label>
            ))}
          </div>
        </div>
      ))}
    </FormModal>
  )
}
