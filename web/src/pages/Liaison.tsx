import { useRef, useState } from 'react'
import { api } from '../lib/api'
import { xof } from '../lib/format'
import { useRecherche } from '../lib/recherche'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Field, Input, Page, Select, Table, useAction } from '../components/ui'

interface Compte { id: number; numero: string; produit: string; solde: number; disponible: number }
interface Cycle {
  id: number; numero: string; type_cycle: number; mise_courante: number; montant_collecte: number; reste_a_collecter: number | null
  nb_lignes: number; nb_lignes_prevues: number; compte_lie_id: number | null
}
interface Situation { client: { id: number; numero: string; nom: string }; comptes: Compte[]; cycles: Cycle[] }

export default function Liaison() {
  const { can } = useSession()
  const [suffixe, setSuffixe] = useState('')
  const refNumero = useRef<HTMLInputElement>(null)
  const { data: s, erreur, recharger } = useRecherche<Situation>('/api/liaisons/recherche', suffixe ? { suffixe } : null)

  return (
    <Page title="Tontine et épargne classique" subtitle="Un client a deux comptes : sa souscription de tontine et son compte d'épargne classique. Cette page les met en relation et permet d'alimenter l'un par l'autre">
      <Card title="Client">
        <div className="row">
          <Field label="N° client" hint="Numéro d'ordre seul (ex. 5)">
            <Input ref={refNumero} inputMode="numeric" value={suffixe} placeholder="5" autoComplete="off" onChange={(e) => setSuffixe(e.target.value.replace(/\D/g, ''))} />
          </Field>
          <Field label="Numéro de base du client"><Input readOnly value={s?.client.numero ?? ''} /></Field>
          <Field label="Nom et prénom"><Input readOnly value={s?.client.nom ?? ''} /></Field>
        </div>
        {erreur && <Alert tone="warn">{erreur}</Alert>}
      </Card>
      {s && (
        <>
          <Card title="Compte d'épargne classique" flush>
            {s.comptes.length === 0
              ? <div style={{ padding: 16 }}><Alert tone="warn">Ce client n'a aucun compte d'épargne classique actif. Il faut d'abord qu'il soit membre (page Adhésion et parts), puis ouvrir le compte depuis sa fiche client.</Alert></div>
              : <Table rows={s.comptes} cols={[
                  { titre: 'Compte', render: (c) => <strong>{c.numero}</strong> },
                  { titre: 'Produit', render: (c) => c.produit },
                  { titre: 'Solde', num: true, render: (c) => xof(c.solde) },
                  { titre: 'Disponible', num: true, render: (c) => xof(c.disponible) },
                ]} />}
          </Card>
          <Card title="Souscriptions de tontine en cours" flush>
            {s.cycles.length === 0
              ? <div style={{ padding: 16 }}><Alert tone="info">Aucune souscription de tontine en cours pour ce client.</Alert></div>
              : s.cycles.map((c) => <CycleLiaison key={c.id} cycle={c} comptes={s.comptes} peut={can('epargne:write')} peutRetirer={can('retrait:request')} onFait={recharger} />)}
          </Card>
        </>
      )}
    </Page>
  )
}

function CycleLiaison({ cycle: c, comptes, peut, peutRetirer, onFait }: { cycle: Cycle; comptes: Compte[]; peut: boolean; peutRetirer: boolean; onFait: () => void }) {
  const { run, busy } = useAction()
  const [compte, setCompte] = useState(String(c.compte_lie_id ?? comptes[0]?.id ?? ''))
  const [montant, setMontant] = useState('')
  const type3 = c.type_cycle === 3
  const m = Number(montant)
  const multipleOk = !m || type3 || m % c.mise_courante === 0
  const depasse = !type3 && c.reste_a_collecter !== null && m > c.reste_a_collecter
  const cible = comptes.find((x) => String(x.id) === compte)
  const lie = c.compte_lie_id !== null && String(c.compte_lie_id) === compte

  return (
    <div style={{ padding: 16, borderTop: '1px solid var(--line, #e5e7eb)' }}>
      <div className="row">
        <Field label="Souscription"><Input readOnly value={c.numero} /></Field>
        <Field label="Mise"><Input readOnly value={xof(c.mise_courante)} /></Field>
        <Field label="Total collecté"><Input readOnly value={xof(c.montant_collecte)} /></Field>
        <Field label="Encours de collecte"><Input readOnly value={c.reste_a_collecter === null ? 'Libre (type 3)' : xof(c.reste_a_collecter)} /></Field>
        <Field label="Compte classique relié">
          <Select value={compte} onChange={(e) => setCompte(e.target.value)} disabled={comptes.length === 0}>
            {comptes.map((x) => <option key={x.id} value={x.id}>{x.numero} — {xof(x.solde)}</option>)}
          </Select>
        </Field>
      </div>
      {peut && comptes.length > 0 && (
        <div className="row">
          {lie ? <Badge tone="ok">Reliée à ce compte</Badge> : <Badge tone="warn">Pas encore reliée</Badge>}
          <Button small disabled={busy || lie} onClick={() => void run(() => api.put(`/api/liaisons/cycles/${c.id}`, { compte_id: Number(compte) }), 'Souscription reliée au compte', onFait)}>Relier</Button>
          {c.compte_lie_id !== null && <Button small disabled={busy} onClick={() => void run(() => api.del(`/api/liaisons/cycles/${c.id}`), 'Liaison supprimée', onFait)}>Délier</Button>}
        </div>
      )}
      {peut && cible && (
        <div className="row">
          <Field label="Alimenter la tontine depuis le compte (F)" hint={`${type3 ? 'Montant libre' : `Multiple de ${c.mise_courante} F`} · disponible ${xof(cible.disponible)}`}>
            <Input type="number" min={1} step={type3 ? 1 : c.mise_courante} value={montant} aria-label={`Montant vers ${c.numero}`} onChange={(e) => setMontant(e.target.value)} />
          </Field>
          <Button variant="primary" disabled={busy || !(m > 0) || !multipleOk || depasse || m > cible.disponible}
            onClick={() => void run(() => api.post('/api/virements/epargne-vers-tontine', { compte_id: cible.id, cycle_id: c.id, montant: m }),
              'Tontine alimentée', () => { setMontant(''); onFait() })}>Virer vers la tontine</Button>
          {peutRetirer && (
            <Button disabled={busy || c.montant_collecte === 0}
              onClick={() => { if (window.confirm(`Virer la tontine ${c.numero} (${xof(c.montant_collecte)} collectés) vers le compte ${cible.numero} ? Le cycle est clôturé et la demande suit le circuit des retraits (contrôle des écarts).`)) void run(() => api.post(`/api/cycles/${c.id}/retrait`, { nature: 'virement_vers_epargne', compte_id: cible.id }), 'Demande de virement créée : à suivre dans Retraits et écarts', onFait) }}>
              Alimenter le compte par la tontine</Button>
          )}
        </div>
      )}
      {!multipleOk && <Alert tone="bad">Le montant doit être un multiple de la mise ({xof(c.mise_courante)}).</Alert>}
      {depasse && <Alert tone="bad">Le montant dépasse l'encours de collecte ({xof(c.reste_a_collecter ?? 0)}).</Alert>}
    </div>
  )
}
