import { useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { type Zone, useProduitsEpargne } from '../lib/hooks'
import { useSession } from '../lib/session'
import EspaceCard from './EspaceCard'
import KycCard from './KycCard'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Kpi, Page, Select, Statut, Table, useAction, useFetch } from '../components/ui'

interface Transfert {
  id: number; type: 'zone' | 'agence'; date_effet: string; motif: string | null; agence_source: string; agence_dest: string
  zone_source: string | null; zone_dest: string | null; ancien_numero: string | null; nouveau_numero: string | null; solde_epargne: number | null; utilisateur: string | null
}

interface Compte { id: number; numero: string; statut: string; produit: string; solde: number; disponible: number }
interface CycleLigne { id: number; numero: string; statut: string; type_cycle: number; montant_collecte: number; net: number }
interface CreditLigne { id: number; numero: string; type: string; mode_remboursement: string; capital_restant: number; statut: string }
interface Detail {
  id: number; agence_id: number; numero: string; nom: string; telephone: string | null; zone: string | null; actif: boolean; points_fidelite: number
  comptes: Compte[]; cycles: CycleLigne[]; credits: CreditLigne[]
}

export default function ClientDetail() {
  const { id } = useParams()
  const nav = useNavigate()
  const { can } = useSession()
  const q = useFetch(() => api.get<Detail>(`/api/clients/${id}`), [id])
  const [modale, setModale] = useState<null | 'compte' | 'cycle' | 'credit' | 'zone' | 'agence' | { op: 'depot' | 'retrait'; compte: Compte }>(null)
  const transferts = useFetch(() => api.get<Transfert[]>(`/api/clients/${id}/transferts`), [id])
  const fin = () => { setModale(null); q.reload(); transferts.reload() }

  return (
    <Charge q={q}>
      {(c) => (
        <Page title={c.nom} subtitle={`${c.numero} · ${c.telephone ?? 'sans téléphone'} · zone ${c.zone ?? '—'}`}
          actions={<>
            <Link to="/clients" className="btn">← Clients</Link>{!c.actif && <Badge tone="bad">Inactif</Badge>}
            {can('clients:transfer-zone') && <Button onClick={() => setModale('zone')}>Changer de zone</Button>}
            {can('clients:transfer-agence') && <Button onClick={() => setModale('agence')}>Transférer vers une agence</Button>}
          </>}>
          <div className="grid-kpi">
            <Kpi label="Comptes d'épargne" value={c.comptes.length} />
            <Kpi label="Épargne totale" value={xof(c.comptes.reduce((s, x) => s + x.solde, 0))} />
            <Kpi label="Cycles en cours" value={c.cycles.filter((x) => x.statut === 'en_cours').length} />
            <Kpi label="Points de fidélité" value={c.points_fidelite} />
          </div>

          <KycCard clientId={c.id} />
          <EspaceCard clientId={c.id} />

          <Card title="Comptes d'épargne" flush actions={can('epargne:write') && <Button small onClick={() => setModale('compte')}>Ouvrir un compte</Button>}>
            <Table rows={c.comptes} vide="Aucun compte d'épargne" cols={[
              { titre: 'Numéro', render: (x) => x.numero },
              { titre: 'Produit', render: (x) => x.produit },
              { titre: 'Solde', num: true, render: (x) => xof(x.solde) },
              { titre: 'Disponible', num: true, render: (x) => xof(x.disponible) },
              { titre: '', render: (x) => can('epargne:write') && (
                <span className="actions">
                  <Button small onClick={() => setModale({ op: 'depot', compte: x })}>Dépôt</Button>
                  <Button small onClick={() => setModale({ op: 'retrait', compte: x })}>Retrait</Button>
                </span>
              ) },
            ]} />
          </Card>

          <Card title="Cycles de tontine" flush actions={can('collecte:write') && <Button small onClick={() => setModale('cycle')}>Nouveau cycle</Button>}>
            <Table rows={c.cycles} onRowClick={(x) => nav(`/cycles/${x.id}`)} vide="Aucun cycle" cols={[
              { titre: 'Cycle', render: (x) => x.numero },
              { titre: 'Type', render: (x) => `Type ${x.type_cycle}` },
              { titre: 'Collecté', num: true, render: (x) => xof(x.montant_collecte) },
              { titre: 'Net', num: true, render: (x) => xof(x.net) },
              { titre: 'Statut', render: (x) => <Statut s={x.statut} /> },
            ]} />
          </Card>

          <Card title="Crédits" flush actions={can('credit:request') && <Button small onClick={() => setModale('credit')}>Nouvelle demande</Button>}>
            <Table rows={c.credits} onRowClick={(x) => nav(`/credits/${x.id}`)} vide="Aucun crédit" cols={[
              { titre: 'Crédit', render: (x) => x.numero },
              { titre: 'Type', render: (x) => (x.type === 'sur_epargne' ? 'Sur épargne' : 'Sans épargne') },
              { titre: 'Capital restant', num: true, render: (x) => xof(x.capital_restant) },
              { titre: 'Statut', render: (x) => <Statut s={x.statut} /> },
            ]} />
          </Card>

          {(transferts.data ?? []).length > 0 && (
            <Card title="Transferts du client" flush>
              <Table rows={transferts.data ?? []} cols={[
                { titre: 'Date', render: (t) => fdate(t.date_effet) },
                { titre: 'Type', render: (t) => <Badge tone={t.type === 'agence' ? 'warn' : 'info'}>{t.type === 'agence' ? 'Agence' : 'Zone'}</Badge> },
                { titre: 'De', render: (t) => `${t.agence_source}${t.zone_source ? ' · ' + t.zone_source : ''}` },
                { titre: 'Vers', render: (t) => `${t.agence_dest}${t.zone_dest ? ' · ' + t.zone_dest : ''}` },
                { titre: 'Numéro', render: (t) => (t.type === 'agence' ? `${t.ancien_numero} → ${t.nouveau_numero}` : '—') },
                { titre: 'Épargne déplacée', num: true, render: (t) => (t.type === 'agence' ? xof(t.solde_epargne) : '—') },
                { titre: 'Motif', render: (t) => t.motif ?? '—' },
              ]} />
            </Card>
          )}

          {modale === 'zone' && <TransfertZone client={c} onClose={() => setModale(null)} onFait={fin} />}
          {modale === 'agence' && <TransfertAgence client={c} onClose={() => setModale(null)} onFait={() => nav('/clients')} />}
          {modale === 'compte' && <OuvrirCompte client={c} onClose={() => setModale(null)} onFait={fin} />}
          {modale === 'cycle' && <NouveauCycle client={c} onClose={() => setModale(null)} onFait={(cid) => nav(`/cycles/${cid}`)} />}
          {modale === 'credit' && <NouvelleDemande client={c} onClose={() => setModale(null)} onFait={() => { fin(); nav('/credits') }} />}
          {modale && typeof modale === 'object' && <Mouvement op={modale.op} compte={modale.compte} onClose={() => setModale(null)} onFait={fin} />}
        </Page>
      )}
    </Charge>
  )
}

function TransfertZone({ client, onClose, onFait }: { client: Detail; onClose: () => void; onFait: () => void }) {
  const zones = useFetch(() => api.get<Zone[]>('/api/zones', { agence_id: client.agence_id }), [client.agence_id])
  const { run, busy } = useAction()
  const [f, setF] = useState({ zone_id: '', date: aujourdhui(), motif: '' })
  return (
    <FormModal titre={`Changer de zone — ${client.nom}`} onClose={onClose} busy={busy} valider="Transférer"
      onSubmit={() => void run(() => api.post(`/api/clients/${client.id}/transfert-zone`, { zone_id: Number(f.zone_id), date: f.date, motif: f.motif || null }), 'Client transféré', onFait)}>
      <Field label="Nouvelle zone" hint={`Zone actuelle : ${client.zone ?? '—'}`}>
        <Select value={f.zone_id} onChange={(e) => setF({ ...f, zone_id: e.target.value })} required>
          <option value="">— choisir —</option>
          {(zones.data ?? []).filter((z) => z.code !== client.zone).map((z) => <option key={z.id} value={z.id}>{z.code} — {z.libelle}</option>)}
        </Select>
      </Field>
      <Field label="Date d'effet"><Input type="date" value={f.date} max={aujourdhui()} onChange={(e) => setF({ ...f, date: e.target.value })} required /></Field>
      <Field label="Motif"><Input value={f.motif} onChange={(e) => setF({ ...f, motif: e.target.value })} /></Field>
      <p className="muted" style={{ gridColumn: '1 / -1', margin: 0 }}>Les opérations antérieures à la date d'effet restent rattachées à l'ancienne zone dans les rapports et les commissions.</p>
    </FormModal>
  )
}

function TransfertAgence({ client, onClose, onFait }: { client: Detail; onClose: () => void; onFait: () => void }) {
  const { agences } = useSession()
  const { run, busy } = useAction()
  const [f, setF] = useState({ agence_id: '', zone_id: '', date: aujourdhui(), motif: '' })
  const zones = useFetch(() => (f.agence_id ? api.get<Zone[]>('/api/zones', { agence_id: Number(f.agence_id) }) : Promise.resolve([] as Zone[])), [f.agence_id])
  return (
    <FormModal titre={`Transférer ${client.nom} vers une autre agence`} onClose={onClose} busy={busy} valider="Transférer" large
      onSubmit={() => {
        if (!window.confirm('Transférer ce client et ses comptes d\'épargne vers la nouvelle agence ? Ses numéros seront renouvelés.')) return
        void run(() => api.post<{ solde_epargne: number }>(`/api/clients/${client.id}/transfert-agence`, {
          agence_id: Number(f.agence_id), zone_id: f.zone_id ? Number(f.zone_id) : null, date: f.date, motif: f.motif || null,
        }), 'Client transféré', onFait)
      }}>
      <Field label="Agence de destination">
        <Select value={f.agence_id} onChange={(e) => setF({ ...f, agence_id: e.target.value, zone_id: '' })} required>
          <option value="">— choisir —</option>
          {agences.filter((a) => a.id !== client.agence_id && !a.siege).map((a) => <option key={a.id} value={a.id}>{a.code} — {a.libelle}</option>)}
        </Select>
      </Field>
      <Field label="Zone de destination">
        <Select value={f.zone_id} onChange={(e) => setF({ ...f, zone_id: e.target.value })}>
          <option value="">— à définir plus tard —</option>
          {(zones.data ?? []).map((z) => <option key={z.id} value={z.id}>{z.code} — {z.libelle}</option>)}
        </Select>
      </Field>
      <Field label="Date d'effet"><Input type="date" value={f.date} max={aujourdhui()} onChange={(e) => setF({ ...f, date: e.target.value })} required /></Field>
      <Field label="Motif"><Input value={f.motif} onChange={(e) => setF({ ...f, motif: e.target.value })} /></Field>
      <div style={{ gridColumn: '1 / -1' }}>
        <Alert tone="warn">Refusé tant que le client a un cycle de tontine non retiré, un retrait en cours, un crédit non soldé, une demande de crédit en attente ou une garantie bloquée. Le solde d'épargne ({xof(client.comptes.reduce((s, x) => s + x.solde, 0))}) change d'agence : aucune écriture comptable inter-agences n'est passée, à régler par le comptable.</Alert>
      </div>
    </FormModal>
  )
}

function OuvrirCompte({ client, onClose, onFait }: { client: Detail; onClose: () => void; onFait: () => void }) {
  const produits = useProduitsEpargne('classique')
  const { run, busy } = useAction()
  const [p, setP] = useState('')
  return (
    <FormModal titre="Ouvrir un compte d'épargne" onClose={onClose} busy={busy} valider="Ouvrir le compte"
      onSubmit={() => void run(() => api.post('/api/comptes-epargne', { client_id: client.id, produit_id: Number(p) }), 'Compte ouvert', onFait)}>
      <Field label="Produit">
        <Select value={p} onChange={(e) => setP(e.target.value)} required>
          <option value="">— choisir —</option>
          {produits.map((x) => <option key={x.id} value={x.id}>{x.libelle} (minimum {xof(x.solde_minimum)})</option>)}
        </Select>
      </Field>
    </FormModal>
  )
}

function Mouvement({ op, compte, onClose, onFait }: { op: 'depot' | 'retrait'; compte: Compte; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [montant, setMontant] = useState('')
  const [jour, setJour] = useState(aujourdhui())
  const [libelle, setLibelle] = useState('')
  const titre = op === 'depot' ? `Dépôt sur ${compte.numero}` : `Retrait sur ${compte.numero}`
  return (
    <FormModal titre={titre} onClose={onClose} busy={busy} valider={op === 'depot' ? 'Enregistrer le dépôt' : 'Enregistrer le retrait'}
      onSubmit={() => void run(() => api.post(`/api/comptes-epargne/${compte.id}/${op}`, { montant: Number(montant), date_operation: jour, libelle: libelle || null }),
        op === 'depot' ? 'Dépôt enregistré' : 'Retrait enregistré', onFait)}>
      <Field label="Montant (F)" hint={op === 'retrait' ? `Disponible : ${xof(compte.disponible)}` : `Solde : ${xof(compte.solde)}`}>
        <Input type="number" min={1} step={1} value={montant} onChange={(e) => setMontant(e.target.value)} required autoFocus />
      </Field>
      <Field label="Date de l'opération"><Input type="date" value={jour} onChange={(e) => setJour(e.target.value)} required /></Field>
      <Field label="Libellé"><Input value={libelle} onChange={(e) => setLibelle(e.target.value)} /></Field>
    </FormModal>
  )
}

function NouveauCycle({ client, onClose, onFait }: { client: Detail; onClose: () => void; onFait: (id: number) => void }) {
  const produits = useProduitsEpargne('collecte')
  const { run, busy } = useAction()
  const [f, setF] = useState({ produit_id: '', mise: '', date_debut: aujourdhui(), date_fin: '' })
  const maj = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  return (
    <FormModal titre={`Nouveau cycle — ${client.nom}`} onClose={onClose} busy={busy} valider="Créer le cycle"
      onSubmit={() => void run(async () => {
        const c = await api.post<{ id: number }>('/api/cycles', { client_id: client.id, produit_id: Number(f.produit_id), mise: Number(f.mise), date_debut: f.date_debut, date_fin: f.date_fin })
        onFait(c.id)
      }, 'Cycle créé')}>
      <Field label="Produit de tontine">
        <Select value={f.produit_id} onChange={maj('produit_id')} required>
          <option value="">— choisir —</option>
          {produits.map((x) => <option key={x.id} value={x.id}>{x.libelle} (type {x.type_cycle})</option>)}
        </Select>
      </Field>
      <Field label="Mise (F)" hint="Montant d'une ligne du livret"><Input type="number" min={1} value={f.mise} onChange={maj('mise')} required /></Field>
      <Field label="Début"><Input type="date" value={f.date_debut} onChange={maj('date_debut')} required /></Field>
      <Field label="Fin"><Input type="date" value={f.date_fin} onChange={maj('date_fin')} required /></Field>
    </FormModal>
  )
}

interface ProduitCredit { id: number; code: string; libelle: string; type: string; taux_annuel: number }

function NouvelleDemande({ client, onClose, onFait }: { client: Detail; onClose: () => void; onFait: () => void }) {
  const produits = useFetch(() => api.get<ProduitCredit[]>('/api/produits-credit'), [])
  const { run, busy } = useAction()
  const [f, setF] = useState({ produit_id: '', montant: '', nb_echeances: '3', taux: '', garantie: '0', mode: 'prelevement_compte', compte_id: '', cycle_id: '', note: '' })
  const maj = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  const produit = (produits.data ?? []).find((p) => String(p.id) === f.produit_id)
  const cyclesActifs = client.cycles.filter((c) => c.statut === 'en_cours')
  return (
    <FormModal titre={`Demande de crédit — ${client.nom}`} onClose={onClose} busy={busy} valider="Déposer la demande" large
      onSubmit={() => void run(() => api.post('/api/demandes-credit', {
        client_id: client.id, produit_id: Number(f.produit_id), montant: Number(f.montant), nb_echeances: Number(f.nb_echeances),
        taux: f.taux ? Number(f.taux) / 100 : null, garantie_montant: Number(f.garantie || 0), mode_remboursement: f.mode,
        compte_id: f.compte_id ? Number(f.compte_id) : null, cycle_id: f.cycle_id ? Number(f.cycle_id) : null, note: f.note || null,
      }), 'Demande enregistrée', onFait)}>
      <Field label="Produit de crédit">
        <Select value={f.produit_id} onChange={maj('produit_id')} required>
          <option value="">— choisir —</option>
          {(produits.data ?? []).map((x) => <option key={x.id} value={x.id}>{x.libelle} ({Math.round(x.taux_annuel * 100)} %/an)</option>)}
        </Select>
      </Field>
      <Field label="Montant (F)"><Input type="number" min={1} value={f.montant} onChange={maj('montant')} required /></Field>
      <Field label="Nombre d'échéances"><Input type="number" min={1} max={240} value={f.nb_echeances} onChange={maj('nb_echeances')} required /></Field>
      <Field label="Taux annuel (%)" hint={produit ? `Par défaut : ${Math.round(produit.taux_annuel * 1000) / 10} %` : 'Vide : taux du produit'}><Input type="number" step="0.1" min={0} value={f.taux} onChange={maj('taux')} /></Field>
      <Field label="Garantie négociée (F)" hint={produit?.type === 'sur_epargne' ? 'Obligatoire pour un crédit sur épargne' : undefined}><Input type="number" min={0} value={f.garantie} onChange={maj('garantie')} /></Field>
      <Field label="Remboursement">
        <Select value={f.mode} onChange={maj('mode')}>
          <option value="prelevement_compte">Prélèvement sur compte</option>
          <option value="especes">Espèces à la caisse</option>
          <option value="tontine">Sur la collecte (tontine)</option>
        </Select>
      </Field>
      <Field label="Compte d'épargne">
        <Select value={f.compte_id} onChange={maj('compte_id')}>
          <option value="">— aucun —</option>
          {client.comptes.map((x) => <option key={x.id} value={x.id}>{x.numero} · {xof(x.disponible)} disponibles</option>)}
        </Select>
      </Field>
      <Field label="Cycle de tontine">
        <Select value={f.cycle_id} onChange={maj('cycle_id')}>
          <option value="">— aucun —</option>
          {cyclesActifs.map((x) => <option key={x.id} value={x.id}>{x.numero}</option>)}
        </Select>
      </Field>
      <Field label="Note"><Input value={f.note} onChange={maj('note')} /></Field>
      <p className="muted" style={{ gridColumn: '1 / -1', margin: 0 }}>La demande devra être approuvée par un responsable, puis débloquée.</p>
    </FormModal>
  )
}
