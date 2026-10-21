import { useState } from 'react'
import { api } from '../lib/api'
import { dateHeure, libellesRole } from '../lib/format'
import { useSession } from '../lib/session'
import InstitutionAdmin from './InstitutionAdmin'
import ParametresAdmin from './ParametresAdmin'
import ReseauxAdmin from './ReseauxAdmin'
import SecuriteAdmin from './SecuriteAdmin'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Modal, Page, Select, Table, Tabs, useAction, useFetch } from '../components/ui'

interface Utilisateur { id: number; login: string; nom: string; role: string; agence_id: number | null; reseau_id: number | null; email: string | null; telephone: string | null; doit_changer_mdp: boolean; actif: boolean; derniere_connexion: string | null; verrouille_jusqua: string | null }
interface ReseauLigne { id: number; code: string; libelle: string }
interface Audit { id: number; horodatage: string; utilisateur: string; table_name: string; operation: string; ligne_id: string | null; avant: unknown; apres: unknown }

const ROLES = Object.keys(libellesRole)
const ROLES_SIEGE = ['admin', 'directeur', 'comptable', 'auditeur']
const ROLES_RESEAU = ['coordinateur']

export default function Admin() {
  const { can } = useSession()
  const onglets = [
    ...(can('users:manage') ? [{ id: 'utilisateurs', titre: 'Utilisateurs' }] : []),
    ...(can('params:read') ? [{ id: 'parametres', titre: 'Paramètres' }] : []),
    ...(can('ref:write') ? [{ id: 'referentiels', titre: 'Référentiels' }] : []),
    ...(can('ref:read') ? [{ id: 'institution', titre: 'Institution et en-tête' }] : []),
    ...(can('reseaux:read') ? [{ id: 'reseaux', titre: 'Réseaux' }] : []),
    ...(can('securite:read') ? [{ id: 'securite', titre: 'Sécurité' }] : []),
    ...(can('audit:read') ? [{ id: 'audit', titre: "Piste d'audit" }] : []),
  ]
  const [onglet, setOnglet] = useState(onglets[0]?.id ?? '')
  return (
    <Page title="Administration" subtitle="Utilisateurs, paramètres, référentiels et audit">
      <Tabs actif={onglet} onChange={setOnglet} tabs={onglets} />
      {onglet === 'utilisateurs' && <Utilisateurs />}
      {onglet === 'parametres' && <ParametresAdmin />}
      {onglet === 'referentiels' && <Referentiels />}
      {onglet === 'institution' && <InstitutionAdmin />}
      {onglet === 'reseaux' && <ReseauxAdmin />}
      {onglet === 'securite' && <SecuriteAdmin />}
      {onglet === 'audit' && <AuditLog />}
    </Page>
  )
}

function Utilisateurs() {
  const { agences, user } = useSession()
  const q = useFetch(() => api.get<Utilisateur[]>('/api/utilisateurs'), [])
  const reseaux = useFetch(() => api.get<ReseauLigne[]>('/api/reseaux'), [])
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
            { titre: 'Périmètre', render: (u) => (u.agence_id !== null ? agences.find((a) => a.id === u.agence_id)?.code ?? u.agence_id : u.reseau_id !== null ? `Réseau ${reseaux.data?.find((r) => r.id === u.reseau_id)?.code ?? u.reseau_id}` : 'Siège') },
            { titre: 'Contact', render: (u) => u.email ?? <span className="muted">aucun</span> },
            { titre: 'Dernière connexion', render: (u) => dateHeure(u.derniere_connexion) },
            { titre: 'État', render: (u) => (!u.actif ? <Badge tone="bad">Désactivé</Badge> : u.verrouille_jusqua && new Date(u.verrouille_jusqua) > new Date() ? <Badge tone="warn">Verrouillé</Badge> : u.doit_changer_mdp ? <Badge tone="info">Mot de passe temporaire</Badge> : <Badge tone="ok">Actif</Badge>) },
            { titre: '', render: (u) => (
              <span className="actions">
                <Button small onClick={() => setModale(u)}>Mot de passe</Button>
                {u.verrouille_jusqua && new Date(u.verrouille_jusqua) > new Date() && <Button small disabled={busy} onClick={() => void run(() => api.post(`/api/utilisateurs/${u.id}/deverrouiller`), 'Compte déverrouillé', q.reload)}>Déverrouiller</Button>}
                {u.id !== user?.id && <Button small variant={u.actif ? 'danger' : undefined} disabled={busy} onClick={() => void run(() => api.patch(`/api/utilisateurs/${u.id}`, { actif: !u.actif }), u.actif ? 'Compte désactivé' : 'Compte réactivé', q.reload)}>{u.actif ? 'Désactiver' : 'Réactiver'}</Button>}
              </span>
            ) },
          ]} />
        )}
      </Charge>
      {modale === 'nouveau' && <NouvelUtilisateur reseaux={reseaux.data ?? []} onClose={() => setModale(null)} onFait={fin} />}
      {modale && typeof modale === 'object' && <Reinit u={modale} onClose={() => setModale(null)} onFait={fin} />}
    </Card>
  )
}

function NouvelUtilisateur({ reseaux, onClose, onFait }: { reseaux: ReseauLigne[]; onClose: () => void; onFait: () => void }) {
  const { agences } = useSession()
  const { run, busy } = useAction()
  const [f, setF] = useState({ login: '', nom: '', role: 'caissier', agence_id: '', reseau_id: '', email: '', telephone: '', mdp: '' })
  const maj = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  const siegeOk = ROLES_SIEGE.includes(f.role)
  const reseauRole = ROLES_RESEAU.includes(f.role)
  return (
    <FormModal titre="Nouvel utilisateur" onClose={onClose} busy={busy} valider="Créer le compte"
      onSubmit={() => void run(() => api.post('/api/utilisateurs', {
        login: f.login, nom: f.nom, role: f.role, agence_id: reseauRole ? null : f.agence_id ? Number(f.agence_id) : null,
        reseau_id: reseauRole ? Number(f.reseau_id) : null, email: f.email || null, telephone: f.telephone || null, mot_de_passe: f.mdp,
      }), 'Utilisateur créé', onFait)}>
      <Field label="Identifiant" hint="Lettres, chiffres, . _ - @"><Input value={f.login} onChange={maj('login')} required autoFocus /></Field>
      <Field label="Nom"><Input value={f.nom} onChange={maj('nom')} required /></Field>
      <Field label="Rôle"><Select value={f.role} onChange={maj('role')}>{ROLES.map((r) => <option key={r} value={r}>{libellesRole[r]}</option>)}</Select></Field>
      {reseauRole ? (
        <Field label="Réseau" hint="Le coordinateur voit toutes les agences de ce réseau, et elles seules">
          <Select value={f.reseau_id} onChange={maj('reseau_id')} required><option value="">— choisir —</option>{reseaux.map((r) => <option key={r.id} value={r.id}>{r.code} — {r.libelle}</option>)}</Select>
        </Field>
      ) : (
        <Field label="Agence" hint={siegeOk ? 'Vide : siège (toutes les agences)' : 'Obligatoire pour ce rôle'}>
          <Select value={f.agence_id} onChange={maj('agence_id')} required={!siegeOk}>
            <option value="">{siegeOk ? 'Siège' : '— choisir —'}</option>{agences.map((a) => <option key={a.id} value={a.id}>{a.code} — {a.libelle}</option>)}
          </Select>
        </Field>
      )}
      <Field label="Adresse e-mail" hint="Sert à la récupération du mot de passe"><Input type="email" value={f.email} onChange={maj('email')} /></Field>
      <Field label="Téléphone"><Input value={f.telephone} onChange={maj('telephone')} /></Field>
      <Field label="Mot de passe provisoire" hint="10 caractères, avec majuscule, minuscule, chiffre et caractère spécial. L'intéressé devra le changer à sa première connexion."><Input type="password" value={f.mdp} onChange={maj('mdp')} minLength={10} autoComplete="new-password" required /></Field>
    </FormModal>
  )
}

function Reinit({ u, onClose, onFait }: { u: Utilisateur; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [mdp, setMdp] = useState('')
  return (
    <FormModal titre={`Mot de passe — ${u.login}`} onClose={onClose} busy={busy} valider="Réinitialiser"
      onSubmit={() => void run(() => api.post(`/api/utilisateurs/${u.id}/mot-de-passe`, { mot_de_passe: mdp }), 'Mot de passe réinitialisé (compte déverrouillé)', onFait)}>
      <Field label="Nouveau mot de passe temporaire" hint="10 caractères, majuscule, minuscule, chiffre et caractère spécial. L'intéressé devra le changer à sa prochaine connexion."><Input type="password" value={mdp} onChange={(e) => setMdp(e.target.value)} minLength={10} autoComplete="new-password" required autoFocus /></Field>
    </FormModal>
  )
}

interface ProduitEp { id: number; code: string; libelle: string; categorie: string; type_cycle: number | null; solde_minimum: number; delai_grace_jours: number | null }
const contient = (t: string, ...champs: (string | null | undefined)[]) => champs.some((c) => (c ?? '').toLowerCase().includes(t.trim().toLowerCase()))

function Referentiels() {
  const { agenceId, can } = useSession()
  const [type, setType] = useState('zone')
  const [modale, setModale] = useState(false)
  const [texte, setTexte] = useState('')
  const [nature, setNature] = useState('')
  const { run, busy } = useAction()
  const zones = useFetch(() => api.get<{ id: number; code: string; libelle: string; collectrice: string | null }[]>('/api/zones'), [agenceId])
  const agents = useFetch(() => api.get<{ id: number; matricule: string; nom: string }[]>('/api/agents'), [agenceId])
  const colls = useFetch(() => api.get<{ id: number; matricule: string; nom: string }[]>('/api/collectrices'), [agenceId])
  const produits = useFetch(() => api.get<ProduitEp[]>('/api/produits-epargne'), [])
  const pcredit = useFetch(() => api.get<{ id: number; code: string; libelle: string; type: string; taux_annuel: number; frais_dossier_taux: number }[]>('/api/produits-credit'), [])
  const recharger = () => { zones.reload(); agents.reload(); colls.reload(); produits.reload(); pcredit.reload() }
  const changerGrace = (p: ProduitEp) => {
    const v = window.prompt(`Délai de grâce de « ${p.libelle} » en jours (0 à 90). Laisser vide pour reprendre le paramètre commun :`, p.delai_grace_jours === null ? '' : String(p.delai_grace_jours))
    if (v === null) return
    void run(() => api.patch(`/api/produits-epargne/${p.id}`, { delai_grace_jours: v.trim() === '' ? null : Number(v) }), 'Délai de grâce enregistré', recharger)
  }
  return (
    <div className="stack">
      <Tabs actif={type} onChange={(t) => { setType(t); setTexte(''); setNature('') }} tabs={[{ id: 'zone', titre: 'Zones' }, { id: 'agent', titre: 'Agents' }, { id: 'collectrice', titre: 'Collectrices' }, { id: 'produit', titre: "Produits d'épargne" }, { id: 'credit', titre: 'Produits de crédit' }]} />
      <Card flush actions={can('ref:write') && <Button variant="primary" onClick={() => setModale(true)}>Ajouter</Button>}>
        <div className="card-b row">
          <Field label="Recherche"><Input value={texte} onChange={(e) => setTexte(e.target.value)} placeholder="Code, nom ou libellé" /></Field>
          {type === 'produit' && <Field label="Nature"><Select value={nature} onChange={(e) => setNature(e.target.value)}><option value="">Toutes</option><option value="collecte">Tontine</option><option value="classique">Épargne classique</option></Select></Field>}
          {type === 'credit' && <Field label="Type"><Select value={nature} onChange={(e) => setNature(e.target.value)}><option value="">Tous</option><option value="sur_epargne">Sur épargne</option><option value="sans_epargne">Sans épargne</option></Select></Field>}
        </div>
        {type === 'zone' && <Charge q={zones}>{(r) => <Table rows={r.filter((z) => contient(texte, z.code, z.libelle, z.collectrice))} cols={[{ titre: 'Code', render: (z) => z.code }, { titre: 'Libellé', render: (z) => z.libelle }, { titre: 'Collectrice actuelle', render: (z) => z.collectrice ?? '—' }]} />}</Charge>}
        {type === 'agent' && <Charge q={agents}>{(r) => <Table rows={r.filter((a) => contient(texte, a.matricule, a.nom))} cols={[{ titre: 'Matricule', render: (a) => a.matricule }, { titre: 'Nom', render: (a) => a.nom }]} />}</Charge>}
        {type === 'collectrice' && <Charge q={colls}>{(r) => <Table rows={r.filter((a) => contient(texte, a.matricule, a.nom))} cols={[{ titre: 'Matricule', render: (a) => a.matricule }, { titre: 'Nom', render: (a) => a.nom }]} />}</Charge>}
        {type === 'produit' && <Charge q={produits}>{(r) => <Table rows={r.filter((p) => contient(texte, p.code, p.libelle) && (!nature || p.categorie === nature))} cols={[
          { titre: 'Code', render: (p) => p.code }, { titre: 'Libellé', render: (p) => p.libelle },
          { titre: 'Nature', render: (p) => (p.categorie === 'collecte' ? (p.type_cycle ? `Tontine — type ${p.type_cycle} imposé` : 'Tontine — type choisi à la première mise') : 'Épargne classique') },
          { titre: 'Délai de grâce', num: true, render: (p) => (p.categorie === 'collecte' ? (p.delai_grace_jours === null ? 'paramètre commun' : `${p.delai_grace_jours} j`) : '') },
          { titre: 'Solde minimum', num: true, render: (p) => p.solde_minimum },
          { titre: '', render: (p) => can('ref:write') && p.categorie === 'collecte' && <Button small disabled={busy} onClick={() => changerGrace(p)}>Délai de grâce</Button> },
        ]} />}</Charge>}
        {type === 'credit' && <Charge q={pcredit}>{(r) => <Table rows={r.filter((p) => contient(texte, p.code, p.libelle) && (!nature || p.type === nature))} cols={[{ titre: 'Code', render: (p) => p.code }, { titre: 'Libellé', render: (p) => p.libelle }, { titre: 'Type', render: (p) => (p.type === 'sur_epargne' ? 'Sur épargne' : 'Sans épargne') }, { titre: 'Taux annuel', num: true, render: (p) => `${Math.round(p.taux_annuel * 1000) / 10} %` }, { titre: 'Frais de dossier', num: true, render: (p) => `${Math.round(p.frais_dossier_taux * 1000) / 10} %` }]} />}</Charge>}
      </Card>
      {modale && <AjoutReferentiel type={type} onClose={() => setModale(false)} onFait={() => { setModale(false); recharger() }} />}
    </div>
  )
}

function AjoutReferentiel({ type, onClose, onFait }: { type: string; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ code: '', libelle: '', nom: '', categorie: 'collecte', grace: '', solde_minimum: '0', type: 'sur_epargne', taux: '12', frais: '1' })
  const maj = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  const envoyer = () => {
    if (type === 'zone') return api.post('/api/zones', { code: f.code, libelle: f.libelle })
    if (type === 'agent') return api.post('/api/agents', { matricule: f.code, nom: f.nom })
    if (type === 'collectrice') return api.post('/api/collectrices', { matricule: f.code, nom: f.nom })
    if (type === 'produit') return api.post('/api/produits-epargne', { code: f.code, libelle: f.libelle, categorie: f.categorie, solde_minimum: Number(f.solde_minimum), delai_grace_jours: f.categorie === 'collecte' && f.grace !== '' ? Number(f.grace) : null })
    return api.post('/api/produits-credit', { code: f.code, libelle: f.libelle, type: f.type, taux_annuel: Number(f.taux) / 100, frais_dossier_taux: Number(f.frais) / 100 })
  }
  return (
    <FormModal titre="Ajouter" onClose={onClose} busy={busy} valider="Créer" onSubmit={() => void run(envoyer, 'Créé', onFait)}>
      <Field label={type === 'agent' || type === 'collectrice' ? 'Matricule' : 'Code'}><Input value={f.code} onChange={maj('code')} maxLength={20} required autoFocus /></Field>
      {(type === 'agent' || type === 'collectrice') ? <Field label="Nom"><Input value={f.nom} onChange={maj('nom')} required /></Field> : <Field label="Libellé"><Input value={f.libelle} onChange={maj('libelle')} required /></Field>}
      {type === 'produit' && (
        <>
          <Field label="Nature"><Select value={f.categorie} onChange={maj('categorie')}><option value="collecte">Tontine (collecte)</option><option value="classique">Épargne classique</option></Select></Field>
          {f.categorie === 'collecte'
            ? <><Alert tone="info">Le type de cycle (1, 2 ou 3) n'est pas lié au produit : il est choisi à la première mise de chaque client, puis reste le même.</Alert>
              <Field label="Délai de grâce (jours)" hint="Après la date de fin d'un cycle : saisie encore acceptée, clôture automatique différée. Vide : paramètre commun."><Input type="number" min={0} max={90} value={f.grace} onChange={maj('grace')} /></Field></>
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
  const [vue, setVue] = useState('journal')
  return (
    <div className="stack">
      <Tabs actif={vue} onChange={setVue} tabs={[{ id: 'journal', titre: 'Journal des modifications' }, { id: 'supprimees', titre: 'Opérations supprimées' }]} />
      {vue === 'journal' ? <JournalAudit /> : <OperationsSupprimees />}
    </div>
  )
}

interface Supprimee { id: number; nature: string; ligne_id: string | null; agence: string | null; cycle: string | null; supprime_par: string; supprime_le: string; motif: string; donnees: Record<string, unknown> }
const NATURES: Record<string, string> = { ligne_collecte: 'Collecte', mouvement_epargne: "Mouvement d'épargne", versement_agent: "Versement d'agent", retrait: 'Retrait de tontine' }

function OperationsSupprimees() {
  const [nature, setNature] = useState('')
  const [utilisateur, setUtilisateur] = useState('')
  const [du, setDu] = useState('')
  const [au, setAu] = useState('')
  const q = useFetch(() => api.get<Supprimee[]>('/api/audit/operations-supprimees', { nature, utilisateur: utilisateur.trim(), du, au }), [nature, utilisateur, du, au])
  const [ouvert, setOuvert] = useState<Supprimee | null>(null)
  return (
    <Card flush>
      <Alert tone="info">Ces opérations ont été supprimées : elles n'apparaissent plus dans les écrans ni dans les calculs. Cette liste est conservée pour l'audit (auteur, date, motif et contenu d'origine) et ne peut être ni modifiée ni effacée.</Alert>
      <div className="card-b row">
        <Field label="Nature"><Select value={nature} onChange={(e) => setNature(e.target.value)}><option value="">Toutes</option>{Object.entries(NATURES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
        <Field label="Supprimée par"><Input value={utilisateur} onChange={(e) => setUtilisateur(e.target.value)} placeholder="identifiant" /></Field>
        <Field label="Du"><Input type="date" value={du} onChange={(e) => setDu(e.target.value)} /></Field>
        <Field label="Au"><Input type="date" value={au} onChange={(e) => setAu(e.target.value)} /></Field>
      </div>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} onRowClick={setOuvert} vide="Aucune opération supprimée" cols={[
            { titre: 'Supprimée le', render: (o) => dateHeure(o.supprime_le) },
            { titre: 'Mention', render: () => <Badge tone="bad">SUPPRIMÉE</Badge> },
            { titre: 'Nature', render: (o) => NATURES[o.nature] ?? o.nature },
            { titre: 'Agence', render: (o) => o.agence ?? '—' },
            { titre: 'Cycle', render: (o) => o.cycle ?? '—' },
            { titre: 'Montant', num: true, render: (o) => String(o.donnees.montant_collecte ?? o.donnees.montant ?? o.donnees.montant_verse ?? '') },
            { titre: 'Par', render: (o) => o.supprime_par },
            { titre: 'Motif', render: (o) => o.motif },
          ]} />
        )}
      </Charge>
      {ouvert && (
        <Modal titre={`Opération supprimée — ${NATURES[ouvert.nature] ?? ouvert.nature} #${ouvert.ligne_id}`} onClose={() => setOuvert(null)} large footer={<Button onClick={() => setOuvert(null)}>Fermer</Button>}>
          <p><Badge tone="bad">SUPPRIMÉE</Badge> le {dateHeure(ouvert.supprime_le)} par <strong>{ouvert.supprime_par}</strong> — motif : {ouvert.motif}</p>
          <pre style={{ overflow: 'auto', fontSize: '0.8rem' }}>{JSON.stringify(ouvert.donnees, null, 2)}</pre>
        </Modal>
      )}
    </Card>
  )
}

function JournalAudit() {
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
