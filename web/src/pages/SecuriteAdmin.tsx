import { useState } from 'react'
import { api } from '../lib/api'
import { dateHeure } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Kpi, Select, Table, Tabs, useAction, useFetch } from '../components/ui'

interface Etat {
  sauvegardes: { derniere: string | null; derniere_fiable: string | null; dernier_test_reussi: string | null }
  comptes: { actifs: number; sans_mot_de_passe: number; mot_de_passe_temporaire: number; sans_contact: number; verrouilles: number; mot_de_passe_perime: number; inactifs_90j: number }
  alertes: { n: number; elevees: number }
  constats: { gravite: 'elevee' | 'moyenne' | 'faible'; texte: string }[]
  politique: { session_minutes: number; mdp_longueur_min: number; mdp_validite_jours: number; mdp_historique: number; verrouillage: string; heures_ouvrables: string }
}
interface Connexion { id: number; horodatage: string; login: string; evenement: string; ip: string | null; detail: string | null }
interface Alerte { id: number; horodatage: string; type: string; gravite: 'faible' | 'moyenne' | 'elevee'; utilisateur: string | null; detail: string; traitee_le: string | null; commentaire: string | null }
interface Sauvegarde {
  id: number; effectuee_le: string; type: string; support: string; emplacement: string | null; taille_mo: number | null
  effectuee_par_login: string | null; test_restaure_le: string | null; test_resultat: 'reussi' | 'echec' | null; test_par_login: string | null; test_commentaire: string | null
}

const TON: Record<string, 'bad' | 'warn' | 'info'> = { elevee: 'bad', moyenne: 'warn', faible: 'info' }
const EVENEMENTS: Record<string, string> = {
  succes: 'Connexion', echec: 'Échec', verrouille: 'Verrouillage', mdp_oublie: 'Mot de passe oublié', mdp_reinitialise: 'Mot de passe réinitialisé',
  mdp_change: 'Mot de passe changé', mdp_reinit_admin: 'Réinitialisé par admin', hors_heures: 'Hors heures',
}

export default function SecuriteAdmin() {
  const { can } = useSession()
  const [vue, setVue] = useState('etat')
  const vues = [
    { id: 'etat', titre: 'État de la sécurité' },
    ...(can('securite:alertes') ? [{ id: 'alertes', titre: 'Alertes' }] : []),
    { id: 'connexions', titre: 'Journal des connexions' },
    { id: 'sauvegardes', titre: 'Sauvegardes' },
  ]
  return (
    <div className="stack">
      <Tabs actif={vue} onChange={setVue} tabs={vues} />
      {vue === 'etat' && <EtatSecurite />}
      {vue === 'alertes' && <Alertes />}
      {vue === 'connexions' && <Connexions />}
      {vue === 'sauvegardes' && <Sauvegardes />}
    </div>
  )
}

function EtatSecurite() {
  const q = useFetch(() => api.get<Etat>('/api/securite/etat'), [])
  return (
    <Charge q={q}>
      {(e) => (
        <div className="stack">
          {e.constats.length === 0 && <Alert tone="info">Aucun constat : sauvegardes testées, comptes à jour.</Alert>}
          {e.constats.map((c, i) => <Alert key={i} tone={c.gravite === 'elevee' ? 'bad' : c.gravite === 'moyenne' ? 'warn' : 'info'}>{c.texte}</Alert>)}
          <div className="kpis">
            <Kpi label="Comptes actifs" value={e.comptes.actifs} />
            <Kpi label="Alertes ouvertes" value={e.alertes.n} tone={e.alertes.elevees ? 'bad' : e.alertes.n ? 'warn' : undefined} />
            <Kpi label="Comptes verrouillés" value={e.comptes.verrouilles} tone={e.comptes.verrouilles ? 'warn' : undefined} />
            <Kpi label="Mots de passe temporaires" value={e.comptes.mot_de_passe_temporaire} />
            <Kpi label="Sans contact de récupération" value={e.comptes.sans_contact} tone={e.comptes.sans_contact ? 'warn' : undefined} />
            <Kpi label="Dernière sauvegarde testée" value={e.sauvegardes.dernier_test_reussi ? dateHeure(e.sauvegardes.dernier_test_reussi) : 'Jamais'} tone={e.sauvegardes.dernier_test_reussi ? undefined : 'bad'} />
          </div>
          <Card title="Politique appliquée">
            <ul style={{ margin: 0, paddingLeft: 18 }}>
              <li>Session du personnel : déconnexion après {e.politique.session_minutes} minutes d'inactivité.</li>
              <li>Mot de passe : {e.politique.mdp_longueur_min} caractères au moins, majuscule, minuscule, chiffre et caractère spécial ; valable {e.politique.mdp_validite_jours} jours ; les {e.politique.mdp_historique} derniers ne peuvent pas être réutilisés.</li>
              <li>Mot de passe temporaire (création, réinitialisation par l'administrateur) : à changer avant toute opération.</li>
              <li>Verrouillage du compte : {e.politique.verrouillage}.</li>
              <li>Heures ouvrables : {e.politique.heures_ouvrables} (connexion en dehors : alerte).</li>
              <li>Récupération : lien à usage unique, valable 30 minutes, envoyé à l'adresse du compte.</li>
            </ul>
          </Card>
        </div>
      )}
    </Charge>
  )
}

function Alertes() {
  const [ouvertes, setOuvertes] = useState(true)
  const q = useFetch(() => api.get<Alerte[]>('/api/securite/alertes', { ouvertes }), [ouvertes])
  const { run, busy } = useAction()
  const [cible, setCible] = useState<Alerte | null>(null)
  const [commentaire, setCommentaire] = useState('')
  return (
    <Card flush actions={<label className="row" style={{ gap: 6 }}><input type="checkbox" checked={ouvertes} onChange={(e) => setOuvertes(e.target.checked)} /> Non traitées seulement</label>}>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucune alerte" cols={[
            { titre: 'Date', render: (a) => dateHeure(a.horodatage) },
            { titre: 'Gravité', render: (a) => <Badge tone={TON[a.gravite]}>{a.gravite}</Badge> },
            { titre: 'Type', render: (a) => a.type.replace(/_/g, ' ') },
            { titre: 'Détail', render: (a) => a.detail },
            { titre: 'Traitement', render: (a) => (a.traitee_le ? <span className="muted">{dateHeure(a.traitee_le)} — {a.commentaire}</span> : <Button small onClick={() => { setCible(a); setCommentaire('') }}>Traiter</Button>) },
          ]} />
        )}
      </Charge>
      {cible && (
        <FormModal titre="Traiter l'alerte" onClose={() => setCible(null)} busy={busy} valider="Marquer comme traitée"
          onSubmit={() => void run(() => api.post(`/api/securite/alertes/${cible.id}/traiter`, { commentaire }), 'Alerte traitée', () => { setCible(null); q.reload() })}>
          <Alert tone="info">{cible.detail}</Alert>
          <Field label="Mesure prise" hint="5 caractères au moins"><Input value={commentaire} onChange={(e) => setCommentaire(e.target.value)} minLength={5} required autoFocus /></Field>
        </FormModal>
      )}
    </Card>
  )
}

function Connexions() {
  const [evenement, setEvenement] = useState('')
  const [login, setLogin] = useState('')
  const q = useFetch(() => api.get<Connexion[]>('/api/securite/connexions', { evenement, login: login.trim(), limit: 200 }), [evenement, login])
  return (
    <Card flush actions={
      <span className="row" style={{ gap: 8 }}>
        <Input placeholder="Identifiant" value={login} onChange={(e) => setLogin(e.target.value)} style={{ width: 160 }} />
        <Select value={evenement} onChange={(e) => setEvenement(e.target.value)} aria-label="Événement">
          <option value="">Tous les événements</option>
          {Object.entries(EVENEMENTS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
        </Select>
      </span>
    }>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucun événement" cols={[
            { titre: 'Date', render: (c) => dateHeure(c.horodatage) },
            { titre: 'Identifiant', render: (c) => c.login },
            { titre: 'Événement', render: (c) => <Badge tone={['echec', 'verrouille', 'hors_heures'].includes(c.evenement) ? 'warn' : 'neutre'}>{EVENEMENTS[c.evenement] ?? c.evenement}</Badge> },
            { titre: 'Adresse IP', render: (c) => c.ip ?? '—' },
            { titre: 'Détail', render: (c) => c.detail ?? '' },
          ]} />
        )}
      </Charge>
    </Card>
  )
}

function Sauvegardes() {
  const { can } = useSession()
  const q = useFetch(() => api.get<Sauvegarde[]>('/api/securite/sauvegardes'), [])
  const { run, busy } = useAction()
  const [nouvelle, setNouvelle] = useState(false)
  const [test, setTest] = useState<Sauvegarde | null>(null)
  const [f, setF] = useState({ effectuee_le: '', type: 'complete', support: '', emplacement: '', taille_mo: '', empreinte: '' })
  const [t, setT] = useState({ resultat: 'reussi', commentaire: '' })
  return (
    <Card flush actions={can('sauvegarde:write') ? <Button variant="primary" onClick={() => { setF({ ...f, effectuee_le: new Date().toISOString().slice(0, 16) }); setNouvelle(true) }}>Enregistrer une sauvegarde</Button> : undefined}>
      <Alert tone="info">Une sauvegarde n'est fiable qu'une fois sa restauration testée, par une personne autre que celle qui l'a faite.</Alert>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucune sauvegarde enregistrée" cols={[
            { titre: 'Date', render: (s) => dateHeure(s.effectuee_le) },
            { titre: 'Type', render: (s) => s.type },
            { titre: 'Support', render: (s) => s.support + (s.emplacement ? ` — ${s.emplacement}` : '') },
            { titre: 'Taille', render: (s) => (s.taille_mo !== null ? `${s.taille_mo} Mo` : '—') },
            { titre: 'Par', render: (s) => s.effectuee_par_login ?? '—' },
            { titre: 'Test de restauration', render: (s) => (s.test_resultat ? <span><Badge tone={s.test_resultat === 'reussi' ? 'ok' : 'bad'}>{s.test_resultat}</Badge> <span className="muted">{dateHeure(s.test_restaure_le)} · {s.test_par_login}</span></span> : can('sauvegarde:tester') ? <Button small onClick={() => { setTest(s); setT({ resultat: 'reussi', commentaire: '' }) }}>Enregistrer le test</Button> : <Badge tone="warn">Non testée</Badge>) },
          ]} />
        )}
      </Charge>
      {nouvelle && (
        <FormModal titre="Nouvelle sauvegarde" onClose={() => setNouvelle(false)} busy={busy} valider="Enregistrer"
          onSubmit={() => void run(() => api.post('/api/securite/sauvegardes', {
            effectuee_le: new Date(f.effectuee_le).toISOString(), type: f.type, support: f.support, emplacement: f.emplacement || null,
            taille_mo: f.taille_mo ? Number(f.taille_mo) : null, empreinte: f.empreinte || null,
          }), 'Sauvegarde enregistrée', () => { setNouvelle(false); q.reload() })}>
          <Field label="Date et heure"><Input type="datetime-local" value={f.effectuee_le} onChange={(e) => setF({ ...f, effectuee_le: e.target.value })} required /></Field>
          <Field label="Type"><Select value={f.type} onChange={(e) => setF({ ...f, type: e.target.value })}><option value="complete">Complète</option><option value="incrementale">Incrémentale</option><option value="journal">Journal des transactions</option></Select></Field>
          <Field label="Support" hint="Ex. disque externe du coffre, serveur distant"><Input value={f.support} onChange={(e) => setF({ ...f, support: e.target.value })} required minLength={2} /></Field>
          <Field label="Emplacement"><Input value={f.emplacement} onChange={(e) => setF({ ...f, emplacement: e.target.value })} /></Field>
          <Field label="Taille (Mo)"><Input type="number" min={0} step="0.1" value={f.taille_mo} onChange={(e) => setF({ ...f, taille_mo: e.target.value })} /></Field>
          <Field label="Somme de contrôle" hint="Empreinte du fichier, pour vérifier son intégrité"><Input value={f.empreinte} onChange={(e) => setF({ ...f, empreinte: e.target.value })} /></Field>
        </FormModal>
      )}
      {test && (
        <FormModal titre="Test de restauration" onClose={() => setTest(null)} busy={busy} valider="Enregistrer le résultat"
          onSubmit={() => void run(() => api.post(`/api/securite/sauvegardes/${test.id}/test`, { resultat: t.resultat, commentaire: t.commentaire || null }), 'Test enregistré', () => { setTest(null); q.reload() })}>
          <Field label="Résultat"><Select value={t.resultat} onChange={(e) => setT({ ...t, resultat: e.target.value })}><option value="reussi">Restauration réussie</option><option value="echec">Échec</option></Select></Field>
          <Field label="Observations"><Input value={t.commentaire} onChange={(e) => setT({ ...t, commentaire: e.target.value })} /></Field>
        </FormModal>
      )}
    </Card>
  )
}
