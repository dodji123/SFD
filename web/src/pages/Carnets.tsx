import { useEffect, useState } from 'react'
import { api } from '../lib/api'
import { dateHeure } from '../lib/format'
import { useAgents, useProduitsEpargne } from '../lib/hooks'
import { useSession } from '../lib/session'
import { BoutonScanner, QrCode, contenuQr, lireQr } from '../components/Qr'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Modal, Page, Select, Table, Tabs, useAction, useFetch } from '../components/ui'

interface Stock {
  agence_id: number; agence: string; produit_id: number; produit: string; produit_libelle: string
  en_stock: number; chez_agents: number; attribues: number; termines: number; perdus: number; abimes: number; annules: number; total: number; reapprovisionner: boolean
}
interface Carnet {
  id: number; agence_id: number; produit_id: number; produit: string; numero: string; statut: string; agent: string | null; agent_nom: string | null
  cycle_id: number | null; cycle: string | null; client: string | null; client_numero: string | null; remplace_id: number | null; motif: string | null
  historique?: { id: number; de_statut: string | null; a_statut: string; agent: string | null; cycle: string | null; motif: string | null; par: string | null; le: string }[]
}
interface CycleLigne { id: number; numero: string; client: string; produit: string }

const STATUTS: Record<string, { texte: string; tone: 'ok' | 'warn' | 'bad' | 'info' | 'neutre' }> = {
  en_stock: { texte: 'En stock', tone: 'info' }, chez_agent: { texte: 'Chez un agent', tone: 'warn' }, attribue: { texte: 'Attribué', tone: 'ok' },
  termine: { texte: 'Terminé', tone: 'neutre' }, perdu: { texte: 'Perdu', tone: 'bad' }, abime: { texte: 'Abîmé', tone: 'bad' }, annule: { texte: 'Annulé', tone: 'neutre' },
}

/** Carnets (livrets papier) : stock par agence et par produit, remise aux agents, attribution aux membres. */
export default function Carnets() {
  const { can, agenceId } = useSession()
  const [onglet, setOnglet] = useState('stock')
  const [lot, setLot] = useState(false)
  const stock = useFetch(() => api.get<Stock[]>('/api/carnets/stock'), [agenceId])
  const [filtreStock, setFiltreStock] = useState('')
  return (
    <Page title="Carnets et stock" subtitle="Chaque produit a son livret : stock, remise aux agents et attribution aux membres"
      actions={can('carnet:write') && <Button variant="primary" onClick={() => setLot(true)}>Recevoir un lot</Button>}>
      <Tabs actif={onglet} onChange={setOnglet} tabs={[{ id: 'stock', titre: 'Stock' }, { id: 'liste', titre: 'Carnets' }]} />
      {onglet === 'stock' && (
        <Card flush>
          <div className="card-b row"><Field label="Produit"><Input value={filtreStock} onChange={(e) => setFiltreStock(e.target.value)} placeholder="Code ou libellé" /></Field></div>
          <Charge q={stock}>
            {(rows) => (
              <Table rows={rows.filter((s) => `${s.produit} ${s.produit_libelle}`.toLowerCase().includes(filtreStock.trim().toLowerCase()))} vide="Aucun carnet reçu : recevez un lot pour commencer" cols={[
                { titre: 'Agence', render: (s) => s.agence }, { titre: 'Produit', render: (s) => `${s.produit} — ${s.produit_libelle}` },
                { titre: 'En stock', num: true, render: (s) => <strong>{s.en_stock}</strong> }, { titre: 'Chez agents', num: true, render: (s) => s.chez_agents },
                { titre: 'Attribués', num: true, render: (s) => s.attribues }, { titre: 'Terminés', num: true, render: (s) => s.termines },
                { titre: 'Perdus / abîmés', num: true, render: (s) => s.perdus + s.abimes }, { titre: 'Total', num: true, render: (s) => s.total },
                { titre: 'Alerte', render: (s) => (s.reapprovisionner ? <Badge tone="bad">À réapprovisionner</Badge> : <Badge tone="ok">Suffisant</Badge>) },
              ]} />
            )}
          </Charge>
        </Card>
      )}
      {onglet === 'liste' && <ListeCarnets onChange={stock.reload} />}
      {lot && <LotModal onClose={() => setLot(false)} onFait={() => { setLot(false); stock.reload() }} />}
    </Page>
  )
}

function LotModal({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const { agenceId } = useSession()
  const produits = useProduitsEpargne('collecte')
  const { run, busy } = useAction()
  const [f, setF] = useState({ produit_id: '', quantite: '50', reference: '' })
  return (
    <FormModal titre="Recevoir un lot de carnets" onClose={onClose} busy={busy} valider="Enregistrer le lot"
      onSubmit={() => void run(() => api.post('/api/carnets/lots', { produit_id: Number(f.produit_id), quantite: Number(f.quantite), reference: f.reference.trim() || null, agence_id: agenceId }), 'Lot enregistré : carnets numérotés créés', onFait)}>
      <Field label="Produit de tontine" hint="Un lot concerne un seul produit : chaque produit a son livret">
        <Select value={f.produit_id} onChange={(e) => setF({ ...f, produit_id: e.target.value })} required><option value="">— choisir —</option>{produits.map((p) => <option key={p.id} value={p.id}>{p.code} — {p.libelle}</option>)}</Select>
      </Field>
      <Field label="Nombre de carnets"><Input type="number" min={1} max={5000} value={f.quantite} onChange={(e) => setF({ ...f, quantite: e.target.value })} required /></Field>
      <Field label="Référence (bon de livraison)"><Input value={f.reference} onChange={(e) => setF({ ...f, reference: e.target.value })} /></Field>
    </FormModal>
  )
}

function ListeCarnets({ onChange }: { onChange: () => void }) {
  const { agenceId } = useSession()
  const produits = useProduitsEpargne('collecte')
  const agents = useAgents()
  const [statut, setStatut] = useState('')
  const [produit, setProduit] = useState('')
  const [agent, setAgent] = useState('')
  const [q, setQ] = useState('')
  const [qd, setQd] = useState('')
  const [ouvert, setOuvert] = useState<number | null>(null)
  useEffect(() => { const t = setTimeout(() => setQd(q), 250); return () => clearTimeout(t) }, [q])
  const liste = useFetch(() => api.get<Carnet[]>('/api/carnets', { statut, produit_id: produit, agent_id: agent, q: qd, limit: 300 }), [statut, produit, agent, qd, agenceId])
  return (
    <Card flush>
      <div className="card-b row">
        <Field label="Recherche"><Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="N° de carnet, client, cycle" /></Field>
        <BoutonScanner libelle="Scanner un carnet" onLu={(t) => setQ(lireQr(t).numero)} />
        <Field label="Statut"><Select value={statut} onChange={(e) => setStatut(e.target.value)}><option value="">Tous</option>{Object.entries(STATUTS).map(([k, v]) => <option key={k} value={k}>{v.texte}</option>)}</Select></Field>
        <Field label="Produit"><Select value={produit} onChange={(e) => setProduit(e.target.value)}><option value="">Tous</option>{produits.map((p) => <option key={p.id} value={p.id}>{p.code} — {p.libelle}</option>)}</Select></Field>
        <Field label="Agent"><Select value={agent} onChange={(e) => setAgent(e.target.value)}><option value="">Tous</option>{agents.map((a) => <option key={a.id} value={a.id}>{a.matricule} — {a.nom}</option>)}</Select></Field>
      </div>
      <Charge q={liste}>
        {(rows) => (
          <Table rows={rows} onRowClick={(c) => setOuvert(c.id)} vide="Aucun carnet" cols={[
            { titre: 'Carnet', render: (c) => <strong>{c.numero}</strong> }, { titre: 'Produit', render: (c) => c.produit },
            { titre: 'Statut', render: (c) => <Badge tone={STATUTS[c.statut]?.tone ?? 'neutre'}>{STATUTS[c.statut]?.texte ?? c.statut}</Badge> },
            { titre: 'Agent', render: (c) => c.agent ?? '—' }, { titre: 'Membre', render: (c) => (c.client ? `${c.client} (${c.client_numero})` : '—') }, { titre: 'Cycle', render: (c) => c.cycle ?? '—' },
          ]} />
        )}
      </Charge>
      {ouvert !== null && <DetailCarnet id={ouvert} onClose={() => setOuvert(null)} onChange={() => { liste.reload(); onChange() }} />}
    </Card>
  )
}

function DetailCarnet({ id, onClose, onChange }: { id: number; onClose: () => void; onChange: () => void }) {
  const { can } = useSession()
  const q = useFetch(() => api.get<Carnet>(`/api/carnets/${id}`), [id])
  const { run, busy } = useAction()
  const agents = useAgents()
  const [mode, setMode] = useState<null | 'remettre' | 'attribuer' | 'declarer'>(null)
  const [agentChoisi, setAgentChoisi] = useState('')
  const apres = () => { setMode(null); q.reload(); onChange() }
  return (
    <Modal titre="Carnet" onClose={onClose} large footer={<Button onClick={onClose}>Fermer</Button>}>
      <Charge q={q}>
        {(c) => (
          <div className="stack">
            <div className="row" style={{ alignItems: 'flex-start', gap: 16 }}>
              <QrCode valeur={contenuQr('CA', c.numero)} legende={c.numero} taille={120} />
              <div className="stack">
                <p style={{ margin: 0 }}><strong>{c.numero}</strong> · produit {c.produit} <Badge tone={STATUTS[c.statut]?.tone ?? 'neutre'}>{STATUTS[c.statut]?.texte ?? c.statut}</Badge></p>
                {c.agent && <p style={{ margin: 0 }}>Remis à l'agent {c.agent} ({c.agent_nom})</p>}
                {c.cycle && <p style={{ margin: 0 }}>Cycle {c.cycle} — {c.client} ({c.client_numero})</p>}
                {c.motif && <p style={{ margin: 0 }}>Motif : {c.motif}</p>}
              </div>
            </div>
            {can('carnet:write') && (
              <div className="row">
                {c.statut === 'en_stock' && <Button onClick={() => setMode('remettre')}>Remettre à un agent</Button>}
                {c.statut === 'chez_agent' && <Button disabled={busy} onClick={() => void run(() => api.post(`/api/carnets/${c.id}/retour`), 'Carnet remis en stock', apres)}>Retour en stock</Button>}
                {(c.statut === 'en_stock' || c.statut === 'chez_agent') && <Button variant="primary" onClick={() => setMode('attribuer')}>Attribuer à un membre</Button>}
                {c.statut === 'attribue' && <Button disabled={busy} onClick={() => void run(() => api.post(`/api/carnets/${c.id}/terminer`), 'Carnet terminé', apres)}>Terminer</Button>}
                {['en_stock', 'chez_agent', 'attribue'].includes(c.statut) && <Button variant="danger" onClick={() => setMode('declarer')}>Déclarer perdu / abîmé</Button>}
              </div>
            )}
            <Table rows={c.historique ?? []} vide="Aucun mouvement" cols={[
              { titre: 'Date', render: (m) => dateHeure(m.le) }, { titre: 'Changement', render: (m) => `${m.de_statut ? (STATUTS[m.de_statut]?.texte ?? m.de_statut) : 'Création'} → ${STATUTS[m.a_statut]?.texte ?? m.a_statut}` },
              { titre: 'Agent', render: (m) => m.agent ?? '' }, { titre: 'Cycle', render: (m) => m.cycle ?? '' }, { titre: 'Motif', render: (m) => m.motif ?? '' }, { titre: 'Par', render: (m) => m.par ?? '' },
            ]} />
            {mode === 'remettre' && (
              <FormModal titre="Remettre le carnet à un agent" onClose={() => setMode(null)} busy={busy || !agentChoisi} valider="Remettre"
                onSubmit={() => { if (agentChoisi) void run(() => api.post(`/api/carnets/${c.id}/remettre`, { agent_id: Number(agentChoisi) }), 'Carnet remis à l’agent', apres) }}>
                <Field label="Agent"><Select value={agentChoisi} onChange={(e) => setAgentChoisi(e.target.value)} required><option value="">— choisir —</option>{agents.map((a) => <option key={a.id} value={a.id}>{a.matricule} — {a.nom}</option>)}</Select></Field>
              </FormModal>
            )}
            {mode === 'attribuer' && <AttribuerModal carnet={c} onClose={() => setMode(null)} onFait={apres} />}
            {mode === 'declarer' && <DeclarerModal carnet={c} onClose={() => setMode(null)} onFait={apres} />}
          </div>
        )}
      </Charge>
    </Modal>
  )
}

function AttribuerModal({ carnet, onClose, onFait }: { carnet: Carnet; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [recherche, setRecherche] = useState('')
  const [trouves, setTrouves] = useState<CycleLigne[]>([])
  const [cycle, setCycle] = useState<CycleLigne | null>(null)
  const [remplace, setRemplace] = useState<Carnet | null>(null)
  useEffect(() => {
    if (recherche.trim().length < 2 || cycle) { setTrouves([]); return }
    let ok = true
    const t = setTimeout(() => { api.get<CycleLigne[]>('/api/cycles', { q: recherche.trim(), statut: 'en_cours', produit_id: carnet.produit_id, limit: 8 }).then((d) => ok && setTrouves(d)).catch(() => ok && setTrouves([])) }, 250)
    return () => { ok = false; clearTimeout(t) }
  }, [recherche, cycle, carnet.produit_id])
  const choisir = (c: CycleLigne) => {
    setCycle(c)
    void api.get<Carnet[]>(`/api/cycles/${c.id}/carnets`).then((l) => setRemplace([...l].reverse().find((x) => x.statut === 'perdu' || x.statut === 'abime') ?? null)).catch(() => setRemplace(null))
  }
  return (
    <FormModal titre={`Attribuer ${carnet.numero} à un membre`} onClose={onClose} busy={busy || !cycle} valider="Attribuer"
      onSubmit={() => { if (cycle) void run(() => api.post(`/api/carnets/${carnet.id}/attribuer`, { cycle_id: cycle.id, remplace_id: remplace?.id ?? null }), 'Carnet attribué', onFait) }}>
      <Alert tone="info">Seuls les cycles en cours du produit {carnet.produit} sont proposés : chaque produit a son livret.</Alert>
      <Field label="Cycle (numéro, nom ou numéro de client)"><Input value={cycle ? `${cycle.numero} — ${cycle.client}` : recherche} readOnly={!!cycle} onChange={(e) => setRecherche(e.target.value)} placeholder="Taper ou scanner le QR du cycle" /></Field>
      {!cycle && <BoutonScanner libelle="Scanner le QR du cycle" onLu={(t) => setRecherche(lireQr(t).numero)} />}
      {cycle && <div><Button type="button" small onClick={() => { setCycle(null); setRemplace(null); setRecherche('') }}>Changer de cycle</Button></div>}
      {trouves.length > 0 && (
        <ul role="listbox" aria-label="Cycles trouvés" style={{ margin: 0, padding: 0, listStyle: 'none' }}>
          {trouves.map((c) => <li key={c.id} role="option" aria-selected={false} tabIndex={0} style={{ padding: '6px 10px', cursor: 'pointer' }} onClick={() => choisir(c)} onKeyDown={(e) => { if (e.key === 'Enter') choisir(c) }}>{c.numero} — {c.client}</li>)}
        </ul>
      )}
      {remplace && <Alert tone="warn">Ce cycle avait le carnet {remplace.numero} ({STATUTS[remplace.statut]?.texte.toLowerCase()}) : le nouveau carnet le remplacera.</Alert>}
    </FormModal>
  )
}

function DeclarerModal({ carnet, onClose, onFait }: { carnet: Carnet; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ statut: 'perdu', motif: '' })
  return (
    <FormModal titre={`Déclarer ${carnet.numero}`} onClose={onClose} busy={busy} valider="Déclarer"
      onSubmit={() => void run(() => api.post(`/api/carnets/${carnet.id}/declarer`, { statut: f.statut, motif: f.motif.trim() }), 'Carnet déclaré', onFait)}>
      <Field label="Constat"><Select value={f.statut} onChange={(e) => setF({ ...f, statut: e.target.value })}><option value="perdu">Perdu</option><option value="abime">Abîmé</option>{carnet.statut === 'en_stock' && <option value="annule">Annulé</option>}</Select></Field>
      <Field label="Motif (5 caractères minimum)" hint="Un carnet perdu ou abîmé ne revient pas en stock ; attribuez ensuite un carnet de remplacement"><Input value={f.motif} minLength={5} onChange={(e) => setF({ ...f, motif: e.target.value })} required /></Field>
      {carnet.statut === 'attribue' && <Alert tone="warn">Le cycle {carnet.cycle} se retrouve sans carnet : attribuez-lui un remplaçant.</Alert>}
    </FormModal>
  )
}
