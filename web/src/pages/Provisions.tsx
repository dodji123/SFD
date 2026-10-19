import { useState } from 'react'
import { api } from '../lib/api'
import { telechargerCsv } from '../lib/csv'
import { aujourdhui, date as fdate, nombre, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, Input, Kpi, Page, Table, useAction, useFetch } from '../components/ui'

interface Classe { classe: string; libelle: string; nb_credits: number; encours: number; solde_restant_du: number; provision_reglementaire: number; provision_interne: number; provision_retenue: number }
interface Rapport { classes: Classe[]; ecarts: { compte: string; requis: number; constitue: number; delta: number }[]; total_requis: number; total_constitue: number; a_doter: number; a_reprendre: number; a_passer_en_perte: number }
interface Credit {
  credit_id: number; numero: string; client: string; capital_restant: number; garantie_bloquee: number; jours_retard: number; classe: string; declasse: boolean
  compte_encours: string | null; solde_restant_du: number; taux_reglementaire: number; provision_reglementaire: number; taux_interne: number | null
  provision_interne: number | null; provision_retenue: number; compte_provision: string | null; a_passer_en_perte: boolean
}
interface Param { cle: string; valeur: string; description: string }

const LIB_CLASSE: Record<string, string> = { sain: 'Sain', '0_3': '0 à 3 mois', '3_6': '3 à 6 mois', '6_12': '6 à 12 mois', '12_24': '12 à 24 mois', irrecouvrable: 'Plus de 24 mois' }
const INTERNES = ['prov_interne_0_3m', 'prov_interne_3_6m', 'prov_interne_6_12m', 'prov_interne_12_24m']

export default function Provisions() {
  const { agenceId, can, user } = useSession()
  const [date, setDate] = useState(aujourdhui())
  const [reseau, setReseau] = useState(false)
  const consolide = reseau && can('etats:consolide') && user?.agence_id === null
  const rap = useFetch(() => api.get<Rapport>('/api/provisions/rapport', { date, consolide }), [date, consolide, agenceId])
  const cre = useFetch(() => api.get<Credit[]>('/api/provisions/classification', { date, consolide }), [date, consolide, agenceId])
  const { run, busy } = useAction()
  const [message, setMessage] = useState<string | null>(null)
  const recharger = () => { rap.reload(); cre.reload() }
  return (
    <Page title="Provisions sur créances" subtitle="Classification par ancienneté de l'impayé et provisions selon le référentiel comptable des SFD"
      actions={<><Field label="Situation au"><Input type="date" value={date} onChange={(e) => setDate(e.target.value || date)} /></Field>
        {can('etats:consolide') && user?.agence_id === null && <label className="actions"><input type="checkbox" checked={reseau} onChange={(e) => setReseau(e.target.checked)} /> Réseau entier</label>}</>}>
      <Charge q={rap}>
        {(r) => (
          <div className="stack">
            <div className="grid-kpi">
              <Kpi label="Provision requise" value={xof(r.total_requis)} />
              <Kpi label="Provision constituée (comptes 299)" value={xof(r.total_constitue)} />
              <Kpi label="À doter" value={xof(r.a_doter)} tone={r.a_doter > 0 ? 'warn' : undefined} />
              <Kpi label="À reprendre" value={xof(r.a_reprendre)} />
              <Kpi label="Encours à passer en charges" value={xof(r.a_passer_en_perte)} tone={r.a_passer_en_perte > 0 ? 'bad' : undefined} />
            </div>
            <Card title="Par classe d'ancienneté" flush actions={<>
              {can('provisions:generer') && !consolide && (
                <Button small variant="primary" disabled={busy || (r.a_doter === 0 && r.a_reprendre === 0)}
                  onClick={() => { if (window.confirm(`Passer la pièce de provisions au ${date} ? Dotation ${xof(r.a_doter)}, reprise ${xof(r.a_reprendre)}.`)) void run(async () => { const x = await api.post<{ message: string }>(`/api/provisions/generer?date=${date}`); setMessage(x.message) }, 'Provisions passées', recharger) }}>Passer les écritures de provisions</Button>)}
              <Button small onClick={() => telechargerCsv(`provisions-${date}`, ['Classe', 'Crédits', 'Encours', 'Solde restant dû', 'Provision réglementaire', 'Provision interne', 'Provision retenue'],
                r.classes.map((c) => [c.libelle, c.nb_credits, c.encours, c.solde_restant_du, c.provision_reglementaire, c.provision_interne, c.provision_retenue]))}>Exporter en CSV</Button></>}>
              <Table rows={r.classes} cols={[
                { titre: 'Classe', render: (c) => <strong>{c.libelle}</strong> },
                { titre: 'Crédits', num: true, render: (c) => c.nb_credits },
                { titre: 'Encours', num: true, render: (c) => xof(c.encours) },
                { titre: 'Solde restant dû', num: true, render: (c) => xof(c.solde_restant_du) },
                { titre: 'Réglementaire', num: true, render: (c) => xof(c.provision_reglementaire) },
                { titre: 'Règle interne', num: true, render: (c) => (c.provision_interne ? xof(c.provision_interne) : '—') },
                { titre: 'Retenue', num: true, render: (c) => <strong>{xof(c.provision_retenue)}</strong> },
              ]} />
            </Card>
            {message && <Alert tone="info">{message}</Alert>}
            <Alert tone="info">Le solde restant dû est l'encours moins les dépôts constitués en garantie. L'ancienneté est celle de la plus ancienne échéance impayée ; le déclassement porte sur la totalité de l'encours du crédit. Un mois vaut 30 jours. Le déclassement comptable (transfert vers les comptes 2921 à 294) et le passage en perte ne sont pas automatisés : la liste ci-dessous les signale.</Alert>
          </div>
        )}
      </Charge>
      <Card title="Crédits en retard" flush>
        <Charge q={cre}>
          {(rows) => (
            <Table rows={rows.filter((c) => c.classe !== 'sain')} vide="Aucun crédit en retard à cette date" cols={[
              { titre: 'Crédit', render: (c) => <><strong>{c.numero}</strong><div className="muted">{c.client}</div></> },
              { titre: 'Impayé depuis', num: true, render: (c) => `${nombre(c.jours_retard)} j` },
              { titre: 'Classe', render: (c) => <><Badge tone={c.classe === 'irrecouvrable' ? 'bad' : c.classe === '0_3' ? 'info' : 'warn'}>{LIB_CLASSE[c.classe]}</Badge>{c.a_passer_en_perte && <div className="muted">à passer en charges</div>}</> },
              { titre: 'Compte d\'encours', render: (c) => c.compte_encours ?? 'non déclassé' },
              { titre: 'Encours', num: true, render: (c) => xof(c.capital_restant) },
              { titre: 'Garantie', num: true, render: (c) => (c.garantie_bloquee ? xof(c.garantie_bloquee) : '—') },
              { titre: 'Taux', num: true, render: (c) => `${nombre(c.taux_reglementaire)} %${c.taux_interne !== null ? ` / ${nombre(c.taux_interne)} %` : ''}` },
              { titre: 'Provision retenue', num: true, render: (c) => <strong>{xof(c.provision_retenue)}</strong> },
            ]} />
          )}
        </Charge>
      </Card>
      <ModePassage />
      <Parametres onChange={recharger} />
    </Page>
  )
}

function Parametres({ onChange }: { onChange: () => void }) {
  const { can } = useSession()
  const q = useFetch(() => api.get<Param[]>('/api/provisions/parametres'), [])
  const { run, busy } = useAction()
  const [saisie, setSaisie] = useState<Record<string, string>>({})
  const modifiable = can('provisions:parametrer')
  const existants = new Set((q.data ?? []).map((p) => p.cle))
  const enregistrer = (cle: string) => void run(async () => { await api.put(`/api/provisions/parametres/${cle}`, { valeur: saisie[cle] }); setSaisie({}) }, 'Paramètre enregistré', () => { q.reload(); onChange() })
  return (
    <Card title="Paramètres du provisionnement" flush>
      <Charge q={q}>
        {(rows) => (
          <>
            <Table rows={rows} cols={[
              { titre: 'Paramètre', render: (p) => <><strong>{p.cle}</strong><div className="muted">{p.description}</div></> },
              { titre: 'Valeur', render: (p) => (modifiable
                ? <span className="actions"><Input style={{ width: 100 }} value={saisie[p.cle] ?? p.valeur} onChange={(e) => setSaisie({ ...saisie, [p.cle]: e.target.value })} />
                    {saisie[p.cle] !== undefined && saisie[p.cle] !== p.valeur && <Button small variant="primary" disabled={busy} onClick={() => enregistrer(p.cle)}>Enregistrer</Button>}
                    {INTERNES.includes(p.cle) && <Button small variant="danger" disabled={busy} onClick={() => void run(() => api.del(`/api/provisions/parametres/${p.cle}`), 'Règle interne retirée', () => { q.reload(); onChange() })}>Retirer</Button>}</span>
                : p.valeur) },
            ]} />
            {modifiable && (
              <div className="card-b stack">
                <strong>Règle interne plus stricte (facultative)</strong>
                <span className="muted">Un taux interne supérieur au taux réglementaire s'applique ; les deux sont affichés.</span>
                <div className="actions">
                  {INTERNES.filter((c) => !existants.has(c)).map((c) => (
                    <Button key={c} small disabled={busy} onClick={() => { const v = window.prompt(`Taux interne en % (${c.replace('prov_interne_', '')})`); if (v) void run(() => api.put(`/api/provisions/parametres/${c}`, { valeur: v }), 'Règle interne ajoutée', () => { q.reload(); onChange() }) }}>Ajouter {c.replace('prov_interne_', '')}</Button>
                  ))}
                </div>
              </div>
            )}
          </>
        )}
      </Charge>
    </Card>
  )
}

interface ModeReponse { mode: 'manuel' | 'automatique'; dernieres_executions: { date_tache: string; statut: string; nb_traites: number | null; message: string | null; agence: string }[] }

function ModePassage() {
  const { can } = useSession()
  const q = useFetch(() => api.get<ModeReponse>('/api/provisions/mode'), [])
  const { run, busy } = useAction()
  const modifiable = can('provisions:parametrer')
  const choisir = (mode: string) => void run(() => api.put('/api/provisions/mode', { mode }), mode === 'automatique' ? 'Mode automatique activé' : 'Mode manuel activé', q.reload)
  return (
    <Card title="Mode de passage des écritures de provisions" flush>
      <Charge q={q}>
        {(m) => (
          <div className="card-b stack">
            <div className="actions">
              <label><input type="radio" name="mode-prov" checked={m.mode === 'manuel'} disabled={!modifiable || busy} onChange={() => choisir('manuel')} /> <strong>Manuel</strong> : le comptable passe la pièce d'un clic (bouton « Passer les écritures de provisions »)</label>
            </div>
            <div className="actions">
              <label><input type="radio" name="mode-prov" checked={m.mode === 'automatique'} disabled={!modifiable || busy} onChange={() => choisir('automatique')} /> <strong>Automatique</strong> : la pièce est passée chaque jour par le traitement quotidien, sans intervention</label>
            </div>
            <Alert tone={m.mode === 'automatique' ? 'warn' : 'info'}>
              {m.mode === 'automatique'
                ? "Le mode automatique n'agit que si le traitement quotidien est planifié sur le serveur (commande « python -m app.cli planifier », à lancer chaque jour par la tâche planifiée du système). Le bouton manuel reste utilisable ; une seule pièce est passée par agence et par jour."
                : "En mode manuel, aucune écriture de provisions n'est passée sans action du comptable."}
            </Alert>
            {m.dernieres_executions.length > 0 && (
              <Table rows={m.dernieres_executions} cols={[
                { titre: 'Jour traité', render: (e) => fdate(e.date_tache) },
                { titre: 'Agence', render: (e) => e.agence },
                { titre: 'Résultat', render: (e) => (e.statut === 'ok' ? <Badge tone="ok">{e.nb_traites ? 'Pièce passée' : 'Rien à passer'}</Badge> : <Badge tone="bad">Échec</Badge>) },
                { titre: 'Détail', render: (e) => e.message ?? '' },
              ]} />
            )}
          </div>
        )}
      </Charge>
    </Card>
  )
}
