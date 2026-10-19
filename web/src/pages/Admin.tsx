import { useState } from 'react'
import { api } from '../lib/api'
import { dateHeure, libellesRole } from '../lib/format'
import { useSession } from '../lib/session'
import InstitutionAdmin from './InstitutionAdmin'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Modal, Page, Select, Table, Tabs, useAction, useFetch } from '../components/ui'

interface Utilisateur { id: number; login: string; nom: string; role: string; agence_id: number | null; actif: boolean; derniere_connexion: string | null; verrouille_jusqua: string | null }
interface Parametre { cle: string; valeur: string; description: string | null; agence_id: number | null }
interface Audit { id: number; horodatage: string; utilisateur: string; table_name: string; operation: string; ligne_id: string | null; avant: unknown; apres: unknown }

const ROLES = Object.keys(libellesRole)
const ROLES_SIEGE = ['admin', 'directeur', 'comptable', 'auditeur']

export default function Admin() {
  const { can } = useSession()
  const onglets = [
    ...(can('users:manage') ? [{ id: 'utilisateurs', titre: 'Utilisateurs' }] : []),
    ...(can('params:read') ? [{ id: 'parametres', titre: 'Paramètres' }] : []),
    ...(can('ref:write') ? [{ id: 'referentiels', titre: 'Référentiels' }] : []),
    ...(can('ref:read') ? [{ id: 'institution', titre: 'Institution et en-tête' }] : []),
    ...(can('audit:read') ? [{ id: 'audit', titre: "Piste d'audit" }] : []),
  ]
  const [onglet, setOnglet] = useState(onglets[0]?.id ?? '')
  return (
    <Page title="Administration" subtitle="Utilisateurs, paramètres, référentiels et audit">
      <Tabs actif={onglet} onChange={setOnglet} tabs={onglets} />
      {onglet === 'utilisateurs' && <Utilisateurs />}
      {onglet === 'parametres' && <Parametres />}
      {onglet === 'referentiels' && <Referentiels />}
      {onglet === 'institution' && <InstitutionAdmin />}
      {onglet === 'audit' && <AuditLog />}
    </Page>
  )
}

function Utilisateurs() {
  const { agences, user } = useSession()
  const q = useFetch(() => api.get<Utilisateur[]>('/api/utilisateurs'), [])
  const { run, busy } = useAction()
  const [modale, setModale] = useState<null | 'nouveau' | Utilisateur>(null)
  const fin = () => { setModale(null); q.reload() }
  return (
    <Card flush actions={<Button variant="primary" onClick={() => setModale('nouveau')}>Nouvel utilisateur</Button>}>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} cols={[
            { titre: 'Identifiant', render: (u) => <strong>{u.login}</strong> },
            { titre: 'Nom', render: (u) => u.nom },
            { titre: 'Rôle', render: (u) => libellesRole[u.role] },
            { titre: 'Agence', render: (u) => (u.agence_id === null ? 'Siège' : agences.find((a) => a.id === u.agence_id)?.code ?? u.agence_id) },
            { titre: 'Dernière connexion', render: (u) => dateHeure(u.derniere_connexion) },
            { titre: 'État', render: (u) => (!u.actif ? <Badge tone="bad">Désactivé</Badge> : u.verrouille_jusqua && new Date(u.verrouille_jusqua) > new Date() ? <Badge tone="warn">Verrouillé</Badge> : <Badge tone="ok">Actif</Badge>) },
            { titre: '', render: (u) => (
              <span className="actions">
                <Button small onClick={() => setModale(u)}>Mot de passe</Button>
                {u.id !== user?.id && <Button small variant={u.actif ? 'danger' : undefined} disabled={busy} onClick={() => void run(() => api.patch(`/api/utilisateurs/${u.id}`, { actif: !u.actif }), u.actif ? 'Compte désactivé' : 'Compte réactivé', q.reload)}>{u.actif ? 'Désactiver' : 'Réactiver'}</Button>}
              </span>
            ) },
          ]} />
        )}
      </Charge>
      {modale === 'nouveau' && <NouvelUtilisateur onClose={() => setModale(null)} onFait={fin} />}
      {modale && typeof modale === 'object' && <Reinit u={modale} onClose={() => setModale(null)} onFait={fin} />}
    </Card>
  )
}

function NouvelUtilisateur({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const { agences } = useSession()
  const { run, busy } = useAction()
  const [f, setF] = useState({ login: '', nom: '', role: 'caissier', agence_id: '', mdp: '' })
  const maj = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  const siegeOk = ROLES_SIEGE.includes(f.role)
  return (
    <FormModal titre="Nouvel utilisateur" onClose={onClose} busy={busy} valider="Créer le compte"
      onSubmit={() => void run(() => api.post('/api/utilisateurs', { login: f.login, nom: f.nom, role: f.role, agence_id: f.agence_id ? Number(f.agence_id) : null, mot_de_passe: f.mdp }), 'Utilisateur créé', onFait)}>
      <Field label="Identifiant" hint="Lettres, chiffres, . _ - @"><Input value={f.login} onChange={maj('login')} required autoFocus /></Field>
      <Field label="Nom"><Input value={f.nom} onChange={maj('nom')} required /></Field>
      <Field label="Rôle"><Select value={f.role} onChange={maj('role')}>{ROLES.map((r) => <option key={r} value={r}>{libellesRole[r]}</option>)}</Select></Field>
      <Field label="Agence" hint={siegeOk ? 'Vide : siège (toutes les agences)' : 'Obligatoire pour ce rôle'}>
        <Select value={f.agence_id} onChange={maj('agence_id')} required={!siegeOk}>
          <option value="">{siegeOk ? 'Siège' : '— choisir —'}</option>{agences.map((a) => <option key={a.id} value={a.id}>{a.code} — {a.libelle}</option>)}
        </Select>
      </Field>
      <Field label="Mot de passe provisoire" hint="10 caractères au moins"><Input type="password" value={f.mdp} onChange={maj('mdp')} minLength={10} autoComplete="new-password" required /></Field>
    </FormModal>
  )
}

function Reinit({ u, onClose, onFait }: { u: Utilisateur; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [mdp, setMdp] = useState('')
  return (
    <FormModal titre={`Mot de passe — ${u.login}`} onClose={onClose} busy={busy} valider="Réinitialiser"
      onSubmit={() => void run(() => api.post(`/api/utilisateurs/${u.id}/mot-de-passe`, { mot_de_passe: mdp }), 'Mot de passe réinitialisé (compte déverrouillé)', onFait)}>
      <Field label="Nouveau mot de passe" hint="10 caractères au moins"><Input type="password" value={mdp} onChange={(e) => setMdp(e.target.value)} minLength={10} autoComplete="new-password" required autoFocus /></Field>
    </FormModal>
  )
}

const LIBELLES_PARAM: Record<string, string> = {
  taux_commission: 'Taux de commission des collectrices (ex. 0,02 = 2 %)', plafond_retenue: 'Part maximale de la commission retenable pour solder le compte agent',
  mode_cloture: 'Mode de clôture / production : calendaire_mensuel ou date_fin_client', arrondi_mode: 'Arrondi de la mise (type 3) : plus_proche, superieur, inferieur',
  arrondi_multiple: "Multiple d'arrondi", diviseur_type3: 'Diviseur de la mise finale (type 3)', jours_saisie_garantie: 'Jours de retard avant saisie de la garantie',
  points_a_temps: 'Points : échéance payée à temps', points_retard_par_tranche: 'Points perdus par tranche de retard', jours_tranche_retard: 'Taille d’une tranche de retard (jours)',
  points_credit_solde: 'Points : crédit soldé sans retard', penalite_taux: 'Pénalité par jour : part du capital de l’échéance', penalite_plafond: 'Plafond de pénalité (part de l’échéance)',
  seuil_validation_credit: 'Montant au-delà duquel un validateur est obligatoire', comptabilisation_auto: 'Comptabilisation automatique des opérations : oui / non',
}

function Parametres() {
  const { can, agenceId } = useSession()
  const q = useFetch(() => api.get<Parametre[]>('/api/parametres'), [agenceId])
  const [edit, setEdit] = useState<Parametre | null>(null)
  return (
    <div className="stack">
      <Alert tone="warn">Valeurs provisoires à faire valider par le client : taux de commission, plafond de retenue, plafond de pénalité, points de fidélité. L'activation de la comptabilisation automatique exige un exercice comptable ouvert et des règles validées par le comptable.</Alert>
      <Card flush>
        <Charge q={q}>
          {(rows) => (
            <Table rows={rows} cols={[
              { titre: 'Paramètre', render: (p) => <><strong>{p.cle}</strong><div className="muted">{LIBELLES_PARAM[p.cle] ?? p.description}</div></> },
              { titre: 'Valeur', render: (p) => <>{p.valeur}{p.agence_id !== null && <> <Badge tone="info">surcharge agence</Badge></>}</> },
              { titre: '', render: (p) => can('params:write') && <Button small onClick={() => setEdit(p)}>Modifier</Button> },
            ]} />
          )}
        </Charge>
        {edit && <ModifierParametre p={edit} onClose={() => setEdit(null)} onFait={() => { setEdit(null); q.reload() }} />}
      </Card>
    </div>
  )
}

function ModifierParametre({ p, onClose, onFait }: { p: Parametre; onClose: () => void; onFait: () => void }) {
  const { agenceId } = useSession()
  const { agences } = useSession()
  const { run, busy } = useAction()
  const [v, setV] = useState(p.valeur)
  const [portee, setPortee] = useState(p.agence_id !== null ? 'agence' : 'globale')
  return (
    <FormModal titre={`Modifier ${p.cle}`} onClose={onClose} busy={busy} valider="Enregistrer"
      onSubmit={() => void run(() => api.put(`/api/parametres/${p.cle}`, { valeur: v, agence_id: portee === 'agence' ? agenceId : null }), 'Paramètre modifié', onFait)}>
      <Field label="Valeur"><Input value={v} onChange={(e) => setV(e.target.value)} required autoFocus /></Field>
      <Field label="Portée">
        <Select value={portee} onChange={(e) => setPortee(e.target.value)}>
          <option value="globale">Toutes les agences</option>
          <option value="agence">Cette agence seulement ({agences.find((a) => a.id === agenceId)?.code})</option>
        </Select>
      </Field>
    </FormModal>
  )
}

function Referentiels() {
  const { agenceId, can } = useSession()
  const [type, setType] = useState('zone')
  const [modale, setModale] = useState(false)
  const zones = useFetch(() => api.get<{ id: number; code: string; libelle: string; collectrice: string | null }[]>('/api/zones'), [agenceId])
  const agents = useFetch(() => api.get<{ id: number; matricule: string; nom: string }[]>('/api/agents'), [agenceId])
  const colls = useFetch(() => api.get<{ id: number; matricule: string; nom: string }[]>('/api/collectrices'), [agenceId])
  const produits = useFetch(() => api.get<{ id: number; code: string; libelle: string; categorie: string; type_cycle: number | null; solde_minimum: number }[]>('/api/produits-epargne'), [])
  const pcredit = useFetch(() => api.get<{ id: number; code: string; libelle: string; type: string; taux_annuel: number; frais_dossier_taux: number }[]>('/api/produits-credit'), [])
  const recharger = () => { zones.reload(); agents.reload(); colls.reload(); produits.reload(); pcredit.reload() }
  return (
    <div className="stack">
      <Tabs actif={type} onChange={setType} tabs={[{ id: 'zone', titre: 'Zones' }, { id: 'agent', titre: 'Agents' }, { id: 'collectrice', titre: 'Collectrices' }, { id: 'produit', titre: "Produits d'épargne" }, { id: 'credit', titre: 'Produits de crédit' }]} />
      <Card flush actions={can('ref:write') && <Button variant="primary" onClick={() => setModale(true)}>Ajouter</Button>}>
        {type === 'zone' && <Charge q={zones}>{(r) => <Table rows={r} cols={[{ titre: 'Code', render: (z) => z.code }, { titre: 'Libellé', render: (z) => z.libelle }, { titre: 'Collectrice actuelle', render: (z) => z.collectrice ?? '—' }]} />}</Charge>}
        {type === 'agent' && <Charge q={agents}>{(r) => <Table rows={r} cols={[{ titre: 'Matricule', render: (a) => a.matricule }, { titre: 'Nom', render: (a) => a.nom }]} />}</Charge>}
        {type === 'collectrice' && <Charge q={colls}>{(r) => <Table rows={r} cols={[{ titre: 'Matricule', render: (a) => a.matricule }, { titre: 'Nom', render: (a) => a.nom }]} />}</Charge>}
        {type === 'produit' && <Charge q={produits}>{(r) => <Table rows={r} cols={[{ titre: 'Code', render: (p) => p.code }, { titre: 'Libellé', render: (p) => p.libelle }, { titre: 'Nature', render: (p) => (p.categorie === 'collecte' ? `Tontine type ${p.type_cycle}` : 'Épargne classique') }, { titre: 'Solde minimum', num: true, render: (p) => p.solde_minimum }]} />}</Charge>}
        {type === 'credit' && <Charge q={pcredit}>{(r) => <Table rows={r} cols={[{ titre: 'Code', render: (p) => p.code }, { titre: 'Libellé', render: (p) => p.libelle }, { titre: 'Type', render: (p) => (p.type === 'sur_epargne' ? 'Sur épargne' : 'Sans épargne') }, { titre: 'Taux annuel', num: true, render: (p) => `${Math.round(p.taux_annuel * 1000) / 10} %` }, { titre: 'Frais de dossier', num: true, render: (p) => `${Math.round(p.frais_dossier_taux * 1000) / 10} %` }]} />}</Charge>}
      </Card>
      {modale && <AjoutReferentiel type={type} onClose={() => setModale(false)} onFait={() => { setModale(false); recharger() }} />}
    </div>
  )
}

function AjoutReferentiel({ type, onClose, onFait }: { type: string; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ code: '', libelle: '', nom: '', categorie: 'collecte', type_cycle: '1', solde_minimum: '0', type: 'sur_epargne', taux: '12', frais: '1' })
  const maj = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  const envoyer = () => {
    if (type === 'zone') return api.post('/api/zones', { code: f.code, libelle: f.libelle })
    if (type === 'agent') return api.post('/api/agents', { matricule: f.code, nom: f.nom })
    if (type === 'collectrice') return api.post('/api/collectrices', { matricule: f.code, nom: f.nom })
    if (type === 'produit') return api.post('/api/produits-epargne', { code: f.code, libelle: f.libelle, categorie: f.categorie, type_cycle: f.categorie === 'collecte' ? Number(f.type_cycle) : null, solde_minimum: Number(f.solde_minimum) })
    return api.post('/api/produits-credit', { code: f.code, libelle: f.libelle, type: f.type, taux_annuel: Number(f.taux) / 100, frais_dossier_taux: Number(f.frais) / 100 })
  }
  return (
    <FormModal titre="Ajouter" onClose={onClose} busy={busy} valider="Créer" onSubmit={() => void run(envoyer, 'Créé', onFait)}>
      <Field label={type === 'agent' || type === 'collectrice' ? 'Matricule' : 'Code'}><Input value={f.code} onChange={maj('code')} maxLength={20} required autoFocus /></Field>
      {(type === 'agent' || type === 'collectrice') ? <Field label="Nom"><Input value={f.nom} onChange={maj('nom')} required /></Field> : <Field label="Libellé"><Input value={f.libelle} onChange={maj('libelle')} required /></Field>}
      {type === 'produit' && (
        <>
          <Field label="Nature"><Select value={f.categorie} onChange={maj('categorie')}><option value="collecte">Tontine (collecte)</option><option value="classique">Épargne classique</option></Select></Field>
          {f.categorie === 'collecte' ? <Field label="Type de cycle"><Select value={f.type_cycle} onChange={maj('type_cycle')}><option value="1">Type 1 — mise × 31 lignes</option><option value="2">Type 2 — durée</option><option value="3">Type 3 — collecte libre</option></Select></Field>
            : <Field label="Solde minimum (F)"><Input type="number" min={0} value={f.solde_minimum} onChange={maj('solde_minimum')} /></Field>}
        </>
      )}
      {type === 'credit' && (
        <>
          <Field label="Type"><Select value={f.type} onChange={maj('type')}><option value="sur_epargne">Sur épargne (garantie)</option><option value="sans_epargne">Sans épargne</option></Select></Field>
          <Field label="Taux annuel (%)"><Input type="number" step="0.1" min={0} value={f.taux} onChange={maj('taux')} /></Field>
          <Field label="Frais de dossier (%)"><Input type="number" step="0.1" min={0} value={f.frais} onChange={maj('frais')} /></Field>
        </>
      )}
    </FormModal>
  )
}

function AuditLog() {
  const [table, setTable] = useState('')
  const [utilisateur, setUtilisateur] = useState('')
  const q = useFetch(() => api.get<Audit[]>('/api/audit', { table_name: table, utilisateur, limit: 200 }), [table, utilisateur])
  const [ouvert, setOuvert] = useState<Audit | null>(null)
  return (
    <Card flush>
      <div className="card-b row">
        <Field label="Table"><Input value={table} onChange={(e) => setTable(e.target.value.trim())} placeholder="ex. retrait" /></Field>
        <Field label="Utilisateur"><Input value={utilisateur} onChange={(e) => setUtilisateur(e.target.value.trim())} placeholder="ex. caissier.lom" /></Field>
      </div>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} onRowClick={setOuvert} vide="Aucune trace" cols={[
            { titre: 'Horodatage', render: (a) => dateHeure(a.horodatage) },
            { titre: 'Utilisateur', render: (a) => a.utilisateur },
            { titre: 'Table', render: (a) => a.table_name },
            { titre: 'Opération', render: (a) => <Badge tone={a.operation === 'DELETE' ? 'bad' : a.operation === 'UPDATE' ? 'warn' : 'ok'}>{a.operation}</Badge> },
            { titre: 'Ligne', render: (a) => a.ligne_id ?? '—' },
          ]} />
        )}
      </Charge>
      {ouvert && (
        <Modal titre={`${ouvert.operation} sur ${ouvert.table_name} #${ouvert.ligne_id}`} onClose={() => setOuvert(null)} large>
          <div className="grid-2">
            <div><h3>Avant</h3><pre style={{ overflow: 'auto', fontSize: '0.8rem' }}>{JSON.stringify(ouvert.avant, null, 2) ?? '—'}</pre></div>
            <div><h3>Après</h3><pre style={{ overflow: 'auto', fontSize: '0.8rem' }}>{JSON.stringify(ouvert.apres, null, 2) ?? '—'}</pre></div>
          </div>
        </Modal>
      )}
    </Card>
  )
}
