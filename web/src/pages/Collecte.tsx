import { useCallback, useEffect, useRef, useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, xof } from '../lib/format'
import { useAgents, useProduitsEpargne, useZones } from '../lib/hooks'
import { useSession } from '../lib/session'
import { ChampClient, FiltreTableau, estNumero, filtrer } from '../components/ChampClient'
import { Alert, Badge, Button, Card, Charge, Field, Input, Kpi, Page, Select, Table, useAction, useFetch } from '../components/ui'

interface Feuille {
  total_collecte: number; nb_lignes: number
  versement: { montant_collecte: number; montant_verse: number; ecart: number } | null
}
interface LigneJour {
  id: number; cycle_id: number; souscription: string; client_numero: string; client: string; produit: string; type_cycle: number
  mise: number; montant_collecte: number; agent_id: number; agent: string; versee: boolean; modifiable: boolean
}
interface Jour { date: string; validee: boolean; validation: { valide_le: string; valide_par: string | null } | null; lignes: LigneJour[]; total: number }
interface Trouve {
  client: { id: number; numero: string; nom: string; zone_id: number | null }
  cycle: { id: number; numero: string; type_cycle: number; mise_courante: number; montant_collecte: number; reste_a_collecter: number | null }
}

export default function Collecte() {
  const { user, can, agenceId } = useSession()
  const agents = useAgents()
  const zones = useZones()
  const [agent, setAgent] = useState<string>('')
  const [zone, setZone] = useState<string>('')
  const [jour, setJour] = useState(aujourdhui())
  const [rafraichir, setRafraichir] = useState(0)
  const peutSaisir = can('collecte:write')

  useEffect(() => {
    if (!agent && user?.agent_id) choisirAgent(String(user.agent_id))
    else if (!agent && agents.length === 1) choisirAgent(String(agents[0].id))
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [agents, user])

  // agent -> zone : la zone de l'agent s'affiche (si l'agent n'en a qu'une) ; zone -> agent : l'agent responsable de la zone
  function choisirAgent(id: string) {
    setAgent(id)
    const siennes = zones.filter((z) => String(z.agent_id) === id)
    if (siennes.length === 1) setZone(String(siennes[0].id))
    else if (!siennes.some((z) => String(z.id) === zone)) setZone('')
  }
  function choisirZone(id: string) {
    setZone(id)
    const z = zones.find((x) => String(x.id) === id)
    if (z?.agent_id) setAgent(String(z.agent_id))
  }

  return (
    <Page title="Collecte du jour" subtitle="Saisie des collectes, correction jusqu'à la validation de la journée, versement de fin de tournée">
      <Card>
        <div className="row">
          <Field label="Jour"><Input type="date" max={aujourdhui()} value={jour} onChange={(e) => setJour(e.target.value || aujourdhui())} /></Field>
        </div>
      </Card>
      {peutSaisir && (
        <FormulaireSaisie key={`f-${agenceId}`} jour={jour} agent={agent} zone={zone} agents={agents} zones={zones}
          onAgent={choisirAgent} onZone={choisirZone} onFait={() => setRafraichir((n) => n + 1)} />
      )}
      <TableauJour key={`t-${jour}-${agenceId}-${rafraichir}`} jour={jour} onChange={() => setRafraichir((n) => n + 1)} />
      {agent && <Tournee key={`v-${agent}-${jour}-${agenceId}-${rafraichir}`} agentId={Number(agent)} jour={jour} />}
    </Page>
  )
}

function FormulaireSaisie({ jour, agent, zone, agents, zones, onAgent, onZone, onFait }: {
  jour: string; agent: string; zone: string
  agents: { id: number; matricule: string; nom: string }[]; zones: { id: number; code: string; libelle: string }[]
  onAgent: (id: string) => void; onZone: (id: string) => void; onFait: () => void
}) {
  const produits = useProduitsEpargne('collecte')
  const [produit, setProduit] = useState('')
  const [suffixe, setSuffixe] = useState('')
  const [trouve, setTrouve] = useState<Trouve | null>(null)
  const [erreur, setErreur] = useState<string | null>(null)
  const [montant, setMontant] = useState('')
  const { run, busy } = useAction()
  const refNumero = useRef<HTMLInputElement>(null)
  const refMontant = useRef<HTMLInputElement>(null)

  // recherche du client dès que le numéro d'ordre, le produit, la zone ou le jour changent ; le curseur passe au montant
  useEffect(() => {
    setTrouve(null); setErreur(null)
    if (!estNumero(suffixe) || !produit) return
    let ok = true
    const t = setTimeout(() => {
      api.get<Trouve>('/api/collecte/client-cycle', { suffixe, produit_id: produit, date: jour, ...(zone ? { zone_id: zone } : {}) })
        .then((d) => ok && setTrouve(d))
        .catch((e: Error) => ok && setErreur(e.message))
    }, 250)
    return () => { ok = false; clearTimeout(t) }
  }, [suffixe, produit, zone, jour])

  // le curseur passe au montant dès que le client est retrouvé (le champ est alors activé)
  useEffect(() => { if (trouve) refMontant.current?.focus() }, [trouve])

  const c = trouve?.cycle
  const m = Number(montant)
  const type3 = c?.type_cycle === 3
  const multipleOk = !c || !m || type3 || m % c.mise_courante === 0
  const depasse = !!c && !type3 && c.reste_a_collecter !== null && m > c.reste_a_collecter
  const pret = !!c && !!agent && m > 0 && multipleOk && !depasse && !busy

  const enregistrer = useCallback(() => api.post('/api/collecte/saisie', { cycle_id: c!.id, agent_id: Number(agent), date_collecte: jour, montant_collecte: m }), [c, agent, jour, m])
  const valider = () => void run(enregistrer, 'Collecte enregistrée', () => {
    setSuffixe(''); setMontant(''); setTrouve(null); setErreur(null)   // le formulaire se réinitialise
    onFait()
    setTimeout(() => refNumero.current?.focus(), 0)
  })

  return (
    <Card title="Saisie d'une collecte">
      <div className="row">
        <Field label="Produit tontine">
          <Select value={produit} onChange={(e) => setProduit(e.target.value)}>
            <option value="">— choisir un produit —</option>
            {produits.map((p) => <option key={p.id} value={p.id}>{p.code} — {p.libelle}</option>)}
          </Select>
        </Field>
        <Field label="Agent commercial">
          <Select value={agent} onChange={(e) => onAgent(e.target.value)}>
            <option value="">— choisir un agent —</option>
            {agents.map((a) => <option key={a.id} value={a.id}>{a.matricule} — {a.nom}</option>)}
          </Select>
        </Field>
        <Field label="Zone" hint="Liée à l'agent : choisir l'un renseigne l'autre">
          <Select value={zone} onChange={(e) => onZone(e.target.value)}>
            <option value="">— toutes les zones —</option>
            {zones.map((z) => <option key={z.id} value={z.id}>{z.code} — {z.libelle}</option>)}
          </Select>
        </Field>
      </div>
      <div className="row">
        <ChampClient valeur={suffixe} onChange={setSuffixe} inputRef={refNumero} />
        <Field label="Numéro de base du client"><Input readOnly value={trouve?.client.numero ?? ''} /></Field>
        <Field label="N° de souscription"><Input readOnly value={c?.numero ?? ''} /></Field>
        <Field label="Nom et prénom"><Input readOnly value={trouve?.client.nom ?? ''} /></Field>
      </div>
      <div className="row">
        <Field label="Mise"><Input readOnly value={c ? xof(c.mise_courante) : ''} /></Field>
        <Field label="Total déjà collecté"><Input readOnly value={c ? xof(c.montant_collecte) : ''} /></Field>
        <Field label="Encours de collecte"><Input readOnly value={c ? (c.reste_a_collecter === null ? 'Libre (type 3)' : xof(c.reste_a_collecter)) : ''} /></Field>
        <Field label="Montant à saisir (F)" hint={c ? (type3 ? 'Montant libre pour une mise de type 3' : `Multiple de ${c.mise_courante} F, au plus ${c.reste_a_collecter ?? 0} F`) : undefined}>
          <Input ref={refMontant} type="number" min={1} step={type3 || !c ? 1 : c.mise_courante} value={montant} disabled={!c}
            onChange={(e) => setMontant(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter' && pret) valider() }} aria-label="Montant à saisir" />
        </Field>
        <Button variant="primary" disabled={!pret} onClick={valider}>Valider la saisie</Button>
      </div>
      {erreur && <Alert tone="warn">{erreur}</Alert>}
      {!multipleOk && c && <Alert tone="bad">Le montant doit être un multiple de la mise ({xof(c.mise_courante)}).</Alert>}
      {depasse && c && <Alert tone="bad">Le montant dépasse l'encours de collecte ({xof(c.reste_a_collecter ?? 0)}).</Alert>}
    </Card>
  )
}

function TableauJour({ jour, onChange }: { jour: string; onChange: () => void }) {
  const { can } = useSession()
  const q = useFetch(() => api.get<Jour>('/api/collecte/jour', { date: jour }), [jour])
  const { run, busy } = useAction()
  const [edit, setEdit] = useState<{ id: number; montant: string } | null>(null)
  const [filtre, setFiltre] = useState('')

  const apres = () => { setEdit(null); q.reload(); onChange() }
  const supprimer = (l: LigneJour) => {
    if (window.confirm(`Supprimer la collecte de ${xof(l.montant_collecte)} de ${l.client} ?`)) void run(() => api.del(`/api/collecte/lignes/${l.id}`), 'Collecte supprimée', apres)
  }
  const rouvrir = () => {
    const motif = window.prompt('Motif de la réouverture de la journée (obligatoire) :')
    if (motif) void run(() => api.post('/api/collecte/rouvrir-journee', { date: jour, motif }), 'Journée rouverte', apres)
  }

  return (
    <Charge q={q}>
      {(d) => (
        <Card title={`Collectes du ${jour.split('-').reverse().join('/')}`} flush actions={
          <>
            {d.validee ? <Badge tone="ok">Journée validée</Badge> : <Badge tone="warn">Journée en cours</Badge>}
            {can('collecte:admin') && (d.validee
              ? <Button small disabled={busy} onClick={rouvrir}>Rouvrir la journée</Button>
              : <Button small variant="primary" disabled={busy || d.lignes.length === 0}
                  onClick={() => { if (window.confirm(`Valider la journée : ${d.lignes.length} collecte(s), ${xof(d.total)}. Elles ne seront plus modifiables.`)) void run(() => api.post('/api/collecte/valider-journee', { date: jour }), 'Journée validée', apres) }}>Valider la journée</Button>)}
          </>}>
          <div className="grid-kpi" style={{ padding: '0 16px' }}>
            <Kpi label="Total collecté" value={xof(d.total)} />
            <Kpi label="Collectes saisies" value={d.lignes.length} />
          </div>
          <FiltreTableau valeur={filtre} onChange={setFiltre} />
          <Table rows={filtrer(d.lignes, filtre, (l) => [l.client, l.client_numero, l.souscription, l.agent])} vide={filtre ? 'Aucune collecte ne correspond au filtre' : 'Aucune collecte saisie ce jour'} cols={[
            { titre: 'N° client', render: (l) => l.client_numero },
            { titre: 'Client', render: (l) => <strong>{l.client}</strong> },
            { titre: 'Souscription', render: (l) => <>{l.souscription}<div className="muted">{l.produit}</div></> },
            { titre: 'Mise', num: true, render: (l) => xof(l.mise) },
            { titre: 'Agent', render: (l) => l.agent },
            { titre: 'Montant', num: true, render: (l) => edit?.id === l.id
              ? <Input type="number" min={1} step={l.type_cycle === 3 ? 1 : l.mise} style={{ width: 110, textAlign: 'right' }} value={edit.montant}
                  onChange={(e) => setEdit({ id: l.id, montant: e.target.value })} aria-label={`Nouveau montant ${l.client}`} />
              : xof(l.montant_collecte) },
            { titre: '', render: (l) => !can('collecte:write') ? null : !l.modifiable ? <span className="muted">{l.versee ? 'versée' : 'validée'}</span> : edit?.id === l.id
              ? <>
                  <Button small variant="primary" disabled={busy || !Number(edit.montant)}
                    onClick={() => void run(() => api.put(`/api/collecte/lignes/${l.id}`, { montant_collecte: Number(edit.montant) }), 'Collecte modifiée', apres)}>Enregistrer</Button>{' '}
                  <Button small onClick={() => setEdit(null)}>Annuler</Button>
                </>
              : <>
                  <Button small onClick={() => setEdit({ id: l.id, montant: String(l.montant_collecte) })}>Modifier</Button>{' '}
                  <Button small variant="danger" disabled={busy} onClick={() => supprimer(l)}>Supprimer</Button>
                </> },
          ]} />
        </Card>
      )}
    </Charge>
  )
}

function Tournee({ agentId, jour }: { agentId: number; jour: string }) {
  const { can } = useSession()
  const feuille = useFetch(() => api.get<Feuille>('/api/collecte/journee', { agent_id: agentId, date: jour }), [agentId, jour])
  return can('versement:write') || feuille.data?.versement ? <Versement agentId={agentId} jour={jour} feuille={feuille.data} onFait={feuille.reload} /> : null
}

function Versement({ agentId, jour, feuille, onFait }: { agentId: number; jour: string; feuille: Feuille | null; onFait: () => void }) {
  const { can } = useSession()
  const { run, busy } = useAction()
  const [verse, setVerse] = useState('')
  const v = feuille?.versement
  const collecte = feuille?.total_collecte ?? 0
  const ecart = verse === '' ? null : collecte - Number(verse)
  return (
    <Card title="Versement de fin de tournée de l'agent">
      {v ? (
        <div className="stack">
          <Alert tone={v.ecart === 0 ? 'info' : 'warn'}>
            Versement enregistré : {xof(v.montant_verse)} pour {xof(v.montant_collecte)} collectés.{' '}
            {v.ecart > 0 ? `Manquant de ${xof(v.ecart)} porté au compte de l'agent.` : v.ecart < 0 ? `Surplus de ${xof(-v.ecart)} à traiter.` : 'Aucun écart.'}
          </Alert>
        </div>
      ) : can('versement:write') ? (
        <div className="row">
          <Field label="Collecté (saisie du jour)"><Input value={xof(collecte)} readOnly /></Field>
          <Field label="Montant versé (F)"><Input type="number" min={0} value={verse} onChange={(e) => setVerse(e.target.value)} /></Field>
          <Field label="Écart">
            <Input readOnly value={ecart === null ? '—' : ecart > 0 ? `Manquant ${xof(ecart)}` : ecart < 0 ? `Surplus ${xof(-ecart)}` : 'Aucun'} />
          </Field>
          <Button variant="primary" disabled={busy || verse === ''}
            onClick={() => void run(() => api.post(`/api/agents/${agentId}/versement`, { date_tournee: jour, montant_verse: Number(verse) }), 'Versement enregistré', onFait)}>Enregistrer le versement</Button>
        </div>
      ) : <p className="muted">Aucun versement enregistré.</p>}
    </Card>
  )
}
