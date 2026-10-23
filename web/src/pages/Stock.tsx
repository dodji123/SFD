import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, nombre, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Kpi, Page, Select, Table, Tabs, useAction, useFetch } from '../components/ui'

interface Article {
  id: number; code: string; designation: string; type: 'consommable' | 'immobilisable'; unite: string; seuil_alerte: number; categorie_immobilisation: string | null
  cout_moyen: number; actif: boolean; quantite: number; valeur: number; en_alerte: boolean; nb_unites: number
}
interface Destination { type: 'siege' | 'agence' | 'agent'; agence_id: number | null; utilisateur_id: number | null; libelle: string }
interface Solde { article_id: number; article_code: string; designation: string; unite: string; lieu: string; lieu_type: string; quantite: number; cout_moyen: number; valeur: number }
interface Mouvement {
  id: number; date_mouvement: string; type: string; article_code: string; designation: string; unite: string; lieu: string; quantite: number; cout_unitaire: number; valeur: number
  motif: string | null; reference_facture: string | null; cree_par_nom: string | null; piece_numero: string | null
}
interface Demande {
  id: number; type: string; statut: string; article_code: string | null; designation: string | null; lieu: string | null; immobilisation_numero: string | null; quantite: number | null
  date_effet: string; motif: string; demande_par: number; demande_par_nom: string; decide_par_nom: string | null; motif_decision: string | null
}
interface Alerte { article_id: number; article_code: string; designation: string; unite: string; perimetre: string; quantite: number; seuil_alerte: number; rupture: boolean }
interface Unite {
  id: number; numero: string; designation: string; article_code: string | null; article_designation: string | null; statut: string; valeur_acquisition: number; valeur_nette: number
  numero_serie: string | null; agence_id: number; affecte_a_id: number | null; affecte_a: string | null; affecte_depuis: string | null
}
interface Valo { lignes: { agence_id: number | null; perimetre: string; nb_articles: number; valeur: number }[]; total: number }

const LIB_MVT: Record<string, string> = { entree: 'Entrée', sortie: 'Sortie', transfert: 'Transfert', inventaire: 'Inventaire', rebut: 'Rebut' }
const LIB_DEMANDE: Record<string, string> = { sortie: 'Sortie', rebut: 'Rebut', inventaire: 'Inventaire', rebut_immobilisation: 'Rebut d’immobilisation' }
const TON_DEMANDE: Record<string, 'ok' | 'warn' | 'bad'> = { en_attente: 'warn', validee: 'ok', rejetee: 'bad' }
const LIB_DEMANDE_STATUT: Record<string, string> = { en_attente: 'En attente', validee: 'Validée', rejetee: 'Rejetée' }
const TON_IMMO: Record<string, 'ok' | 'warn' | 'bad' | 'neutre'> = { en_service: 'ok', en_maintenance: 'warn', hors_service: 'bad', sortie: 'neutre' }

const cle = (d: Destination) => `${d.type}:${d.agence_id ?? ''}:${d.utilisateur_id ?? ''}`
const ref = (d: Destination) => ({ type: d.type, agence_id: d.agence_id, utilisateur_id: d.utilisateur_id })

/** Choix d'un lieu (siège, agence, agent) dans le périmètre de l'utilisateur. */
function LieuSelect({ label, destinations, valeur, onChange, types }: {
  label: string; destinations: Destination[]; valeur: string; onChange: (v: string) => void; types?: string[]
}) {
  const liste = destinations.filter((d) => !types || types.includes(d.type))
  return (
    <Field label={label}>
      <Select value={valeur} onChange={(e) => onChange(e.target.value)} required>
        <option value="">— choisir —</option>
        {liste.map((d) => <option key={cle(d)} value={cle(d)}>{d.libelle}</option>)}
      </Select>
    </Field>
  )
}

/** Stock des fournitures : catalogue, soldes, mouvements, inventaire, alertes et immobilisations affectées aux agents. */
export default function Stock() {
  const [onglet, setOnglet] = useState('articles')
  return (
    <Page title="Stock des fournitures" subtitle="Consommables (livrets, reçus, papeterie) et matériel immobilisé, par siège, agence et agent">
      <Tabs actif={onglet} onChange={setOnglet} tabs={[
        { id: 'articles', titre: 'Articles' }, { id: 'stock', titre: 'Stock et valorisation' }, { id: 'mouvements', titre: 'Mouvements' },
        { id: 'demandes', titre: 'Sorties, rebuts et inventaire' }, { id: 'alertes', titre: 'Alertes' }, { id: 'immobilisations', titre: 'Immobilisations' },
      ]} />
      {onglet === 'articles' && <Articles />}
      {onglet === 'stock' && <Soldes />}
      {onglet === 'mouvements' && <Mouvements />}
      {onglet === 'demandes' && <Demandes />}
      {onglet === 'alertes' && <Alertes />}
      {onglet === 'immobilisations' && <Immobilisations />}
    </Page>
  )
}

/* ---------------------------------------------------------------- articles */
function Articles() {
  const { can, agenceId } = useSession()
  const [q, setQ] = useState('')
  const [creation, setCreation] = useState(false)
  const [edition, setEdition] = useState<Article | null>(null)
  const liste = useFetch(() => api.get<Article[]>('/api/stock/articles', { q: q || undefined, actifs: false }), [q, agenceId])
  return (
    <Card flush actions={can('stock:gerer') && <Button variant="primary" onClick={() => setCreation(true)}>Nouvel article</Button>}>
      <div className="card-b row"><Field label="Recherche"><Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Code ou désignation" /></Field></div>
      <Charge q={liste}>
        {(rows) => (
          <Table rows={rows} onRowClick={can('stock:gerer') ? setEdition : undefined} vide="Aucun article" cols={[
            { titre: 'Code', render: (a) => <strong>{a.code}</strong> }, { titre: 'Désignation', render: (a) => a.designation },
            { titre: 'Type', render: (a) => (a.type === 'consommable' ? 'Consommable' : 'Immobilisable') },
            { titre: 'En stock', num: true, render: (a) => (a.type === 'consommable' ? `${nombre(a.quantite)} ${a.unite}` : `${a.nb_unites} unité(s)`) },
            { titre: 'Coût moyen', num: true, render: (a) => (a.type === 'consommable' ? xof(a.cout_moyen) : '—') },
            { titre: 'Valeur', num: true, render: (a) => (a.type === 'consommable' ? xof(a.valeur) : '—') },
            { titre: 'Seuil', num: true, render: (a) => (a.type === 'consommable' ? nombre(a.seuil_alerte) : '—') },
            { titre: 'État', render: (a) => (!a.actif ? <Badge tone="neutre">Inactif</Badge> : a.en_alerte ? <Badge tone="bad">Sous le seuil</Badge> : <Badge tone="ok">OK</Badge>) },
          ]} />
        )}
      </Charge>
      {creation && <CreationArticle onClose={() => setCreation(false)} onFait={() => { setCreation(false); liste.reload() }} />}
      {edition && <EditionArticle article={edition} onClose={() => setEdition(null)} onFait={() => { setEdition(null); liste.reload() }} />}
    </Card>
  )
}

function CreationArticle({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const categories = useFetch(() => api.get<{ code: string; libelle: string }[]>('/api/categories-immobilisation'), [])
  const { run, busy } = useAction()
  const [f, setF] = useState({ code: '', designation: '', type: 'consommable', unite: 'unité', seuil: '0', categorie: '' })
  return (
    <FormModal titre="Nouvel article" onClose={onClose} busy={busy}
      onSubmit={() => void run(() => api.post('/api/stock/articles', {
        code: f.code.trim().toUpperCase(), designation: f.designation.trim(), type: f.type, unite: f.unite.trim() || 'unité',
        seuil_alerte: f.type === 'consommable' ? Number(f.seuil || 0) : 0, categorie_immobilisation: f.type === 'immobilisable' ? f.categorie : null,
      }), 'Article créé', onFait)}>
      <Field label="Code" hint="Majuscules, chiffres, tirets (ex. LIVRET-A5)"><Input value={f.code} onChange={(e) => setF({ ...f, code: e.target.value })} required minLength={2} /></Field>
      <Field label="Désignation"><Input value={f.designation} onChange={(e) => setF({ ...f, designation: e.target.value })} required minLength={3} /></Field>
      <Field label="Type">
        <Select value={f.type} onChange={(e) => setF({ ...f, type: e.target.value })}><option value="consommable">Consommable (suivi en quantité)</option><option value="immobilisable">Immobilisable (suivi à l’unité)</option></Select>
      </Field>
      {f.type === 'consommable' ? (
        <div className="row">
          <Field label="Unité"><Input value={f.unite} onChange={(e) => setF({ ...f, unite: e.target.value })} /></Field>
          <Field label="Seuil d’alerte" hint="Alerte quand le stock d’un périmètre descend à ce niveau"><Input type="number" min={0} value={f.seuil} onChange={(e) => setF({ ...f, seuil: e.target.value })} /></Field>
        </div>
      ) : (
        <Field label="Catégorie d’immobilisation" hint="Compte et durée d’amortissement">
          <Select value={f.categorie} onChange={(e) => setF({ ...f, categorie: e.target.value })} required><option value="">— choisir —</option>{categories.data?.map((c) => <option key={c.code} value={c.code}>{c.libelle}</option>)}</Select>
        </Field>
      )}
    </FormModal>
  )
}

function EditionArticle({ article, onClose, onFait }: { article: Article; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ designation: article.designation, unite: article.unite, seuil: String(article.seuil_alerte), actif: article.actif })
  return (
    <FormModal titre={`Article ${article.code}`} onClose={onClose} busy={busy}
      onSubmit={() => void run(() => api.patch(`/api/stock/articles/${article.id}`, { designation: f.designation.trim(), unite: f.unite.trim(), seuil_alerte: Number(f.seuil || 0), actif: f.actif }), 'Article modifié', onFait)}>
      <Field label="Désignation"><Input value={f.designation} onChange={(e) => setF({ ...f, designation: e.target.value })} required minLength={3} /></Field>
      {article.type === 'consommable' && (
        <div className="row">
          <Field label="Unité"><Input value={f.unite} onChange={(e) => setF({ ...f, unite: e.target.value })} /></Field>
          <Field label="Seuil d’alerte"><Input type="number" min={0} value={f.seuil} onChange={(e) => setF({ ...f, seuil: e.target.value })} /></Field>
        </div>
      )}
      <Field label="Actif"><Select value={f.actif ? 'oui' : 'non'} onChange={(e) => setF({ ...f, actif: e.target.value === 'oui' })}><option value="oui">Oui</option><option value="non">Non (plus de nouveaux mouvements)</option></Select></Field>
    </FormModal>
  )
}

/* ---------------------------------------------------------------- stock et valorisation */
function Soldes() {
  const { agenceId } = useSession()
  const valo = useFetch(() => api.get<Valo>('/api/stock/valorisation'), [agenceId])
  const soldes = useFetch(() => api.get<Solde[]>('/api/stock/soldes', { agence_id: null }), [agenceId])   // tout le périmètre, siège compris
  return (
    <div className="stack">
      <Charge q={valo}>
        {(v) => (
          <div className="kpis">
            <Kpi label="Valeur totale du stock" value={xof(v.total)} />
            {v.lignes.map((l) => <Kpi key={l.perimetre} label={l.perimetre} value={xof(l.valeur)} />)}
          </div>
        )}
      </Charge>
      <Card title="Stock par lieu" flush>
        <Charge q={soldes}>
          {(rows) => (
            <Table rows={rows} vide="Aucun stock" cols={[
              { titre: 'Article', render: (s) => <><strong>{s.article_code}</strong> · {s.designation}</> },
              { titre: 'Lieu', render: (s) => s.lieu }, { titre: 'Quantité', num: true, render: (s) => `${nombre(s.quantite)} ${s.unite}` },
              { titre: 'Coût moyen', num: true, render: (s) => xof(s.cout_moyen) }, { titre: 'Valeur', num: true, render: (s) => xof(s.valeur) },
            ]} />
          )}
        </Charge>
      </Card>
    </div>
  )
}

/* ---------------------------------------------------------------- mouvements */
function Mouvements() {
  const { can, agenceId } = useSession()
  const [type, setType] = useState('')
  const [entree, setEntree] = useState(false)
  const [transfert, setTransfert] = useState(false)
  const liste = useFetch(() => api.get<Mouvement[]>('/api/stock/mouvements', { type: type || undefined, agence_id: null }), [type, agenceId])
  return (
    <Card flush actions={can('stock:mouvoir') && <span className="row"><Button onClick={() => setTransfert(true)}>Transférer</Button><Button variant="primary" onClick={() => setEntree(true)}>Entrée en stock</Button></span>}>
      <div className="card-b row">
        <Field label="Type"><Select value={type} onChange={(e) => setType(e.target.value)}><option value="">Tous</option>{Object.entries(LIB_MVT).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
      </div>
      <Alert tone="info">Les mouvements s’ajoutent sans jamais être modifiés ni supprimés ; une erreur se corrige par un mouvement inverse.</Alert>
      <Charge q={liste}>
        {(rows) => (
          <Table rows={rows} vide="Aucun mouvement" cols={[
            { titre: 'Date', render: (m) => fdate(m.date_mouvement) }, { titre: 'Type', render: (m) => <Badge tone={m.type === 'entree' ? 'ok' : m.type === 'rebut' ? 'bad' : 'info'}>{LIB_MVT[m.type] ?? m.type}</Badge> },
            { titre: 'Article', render: (m) => <><strong>{m.article_code}</strong> · {m.designation}</> }, { titre: 'Lieu', render: (m) => m.lieu },
            { titre: 'Quantité', num: true, render: (m) => `${m.quantite > 0 ? '+' : ''}${nombre(m.quantite)} ${m.unite}` }, { titre: 'Valeur', num: true, render: (m) => xof(m.valeur) },
            { titre: 'Détail', render: (m) => [m.reference_facture, m.motif, m.piece_numero && `pièce ${m.piece_numero}`].filter(Boolean).join(' · ') },
            { titre: 'Par', render: (m) => m.cree_par_nom ?? '' },
          ]} />
        )}
      </Charge>
      {entree && <EntreeModal onClose={() => setEntree(false)} onFait={() => { setEntree(false); liste.reload() }} />}
      {transfert && <TransfertModal onClose={() => setTransfert(false)} onFait={() => { setTransfert(false); liste.reload() }} />}
    </Card>
  )
}

function useFormulaire() {
  const articles = useFetch(() => api.get<Article[]>('/api/stock/articles', { type: 'consommable' }), [])
  const destinations = useFetch(() => api.get<Destination[]>('/api/stock/destinations'), [])
  return { articles: articles.data ?? [], destinations: destinations.data ?? [] }
}

function EntreeModal({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const { articles, destinations } = useFormulaire()
  const { run, busy } = useAction()
  const [f, setF] = useState({ article: '', lieu: '', quantite: '', cout: '', date: aujourdhui(), facture: '' })
  const lieu = destinations.find((d) => cle(d) === f.lieu)
  return (
    <FormModal titre="Entrée en stock" onClose={onClose} busy={busy} large
      onSubmit={() => lieu && void run(() => api.post('/api/stock/entrees', {
        article_id: Number(f.article), lieu: ref(lieu), quantite: Number(f.quantite), cout_unitaire: Number(f.cout), date_mouvement: f.date, reference_facture: f.facture || null,
      }), 'Entrée enregistrée', onFait)}>
      <Field label="Article"><Select value={f.article} onChange={(e) => setF({ ...f, article: e.target.value })} required><option value="">— choisir —</option>{articles.filter((a) => a.actif).map((a) => <option key={a.id} value={a.id}>{a.code} · {a.designation}</option>)}</Select></Field>
      <LieuSelect label="Lieu de réception" destinations={destinations} valeur={f.lieu} onChange={(v) => setF({ ...f, lieu: v })} types={['siege', 'agence']} />
      <div className="row">
        <Field label="Quantité"><Input type="number" min={0.001} step="any" value={f.quantite} onChange={(e) => setF({ ...f, quantite: e.target.value })} required /></Field>
        <Field label="Coût unitaire (F)"><Input type="number" min={1} step="any" value={f.cout} onChange={(e) => setF({ ...f, cout: e.target.value })} required /></Field>
      </div>
      <div className="row">
        <Field label="Date"><Input type="date" value={f.date} max={aujourdhui()} onChange={(e) => setF({ ...f, date: e.target.value })} required /></Field>
        <Field label="Facture / bon de livraison"><Input value={f.facture} onChange={(e) => setF({ ...f, facture: e.target.value })} /></Field>
      </div>
    </FormModal>
  )
}

function TransfertModal({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const { articles, destinations } = useFormulaire()
  const { run, busy } = useAction()
  const [f, setF] = useState({ article: '', source: '', destination: '', quantite: '', motif: '' })
  const src = destinations.find((d) => cle(d) === f.source)
  const dst = destinations.find((d) => cle(d) === f.destination)
  return (
    <FormModal titre="Transfert de stock" onClose={onClose} busy={busy} large
      onSubmit={() => src && dst && void run(() => api.post('/api/stock/transferts', {
        article_id: Number(f.article), source: ref(src), destination: ref(dst), quantite: Number(f.quantite), motif: f.motif.trim(),
      }), 'Transfert enregistré', onFait)}>
      <Field label="Article"><Select value={f.article} onChange={(e) => setF({ ...f, article: e.target.value })} required><option value="">— choisir —</option>{articles.filter((a) => a.actif).map((a) => <option key={a.id} value={a.id}>{a.code} · {a.designation}</option>)}</Select></Field>
      <div className="row">
        <LieuSelect label="De" destinations={destinations} valeur={f.source} onChange={(v) => setF({ ...f, source: v })} />
        <LieuSelect label="Vers" destinations={destinations} valeur={f.destination} onChange={(v) => setF({ ...f, destination: v })} />
      </div>
      <Field label="Quantité"><Input type="number" min={0.001} step="any" value={f.quantite} onChange={(e) => setF({ ...f, quantite: e.target.value })} required /></Field>
      <Field label="Motif"><Input value={f.motif} minLength={5} onChange={(e) => setF({ ...f, motif: e.target.value })} required /></Field>
    </FormModal>
  )
}

/* ---------------------------------------------------------------- demandes : sortie, rebut, inventaire */
function Demandes() {
  const { can, user, agenceId } = useSession()
  const { run, busy } = useAction()
  const [statut, setStatut] = useState('')
  const [nouvelle, setNouvelle] = useState(false)
  const [rejet, setRejet] = useState<Demande | null>(null)
  const liste = useFetch(() => api.get<Demande[]>('/api/stock/demandes', { statut: statut || undefined }), [statut, agenceId])
  return (
    <Card flush actions={can('stock:mouvoir') && <Button variant="primary" onClick={() => setNouvelle(true)}>Nouvelle demande</Button>}>
      <div className="card-b row">
        <Field label="Statut"><Select value={statut} onChange={(e) => setStatut(e.target.value)}><option value="">Tous</option>{Object.entries(LIB_DEMANDE_STATUT).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
      </div>
      <Alert tone="info">Une sortie, un rebut ou un ajustement d’inventaire ne prend effet que lorsqu’une autre personne que le demandeur le valide.</Alert>
      <Charge q={liste}>
        {(rows) => (
          <Table rows={rows} vide="Aucune demande" cols={[
            { titre: 'N°', render: (d) => d.id }, { titre: 'Type', render: (d) => LIB_DEMANDE[d.type] ?? d.type },
            { titre: 'Objet', render: (d) => (d.immobilisation_numero ?? `${d.article_code} · ${d.designation} · ${d.lieu}`) },
            { titre: 'Quantité', num: true, render: (d) => (d.quantite === null ? '—' : d.type === 'inventaire' ? `compté : ${nombre(d.quantite)}` : nombre(d.quantite)) },
            { titre: 'Motif', render: (d) => d.motif }, { titre: 'Demandeur', render: (d) => d.demande_par_nom },
            { titre: 'Statut', render: (d) => <><Badge tone={TON_DEMANDE[d.statut]}>{LIB_DEMANDE_STATUT[d.statut]}</Badge>{d.decide_par_nom && <span className="muted"> par {d.decide_par_nom}{d.motif_decision ? ` — ${d.motif_decision}` : ''}</span>}</> },
            { titre: 'Décision', render: (d) => d.statut === 'en_attente' && can('stock:valider') && d.demande_par !== user?.id
              ? <span className="row"><Button small variant="primary" disabled={busy} onClick={() => void run(() => api.post(`/api/stock/demandes/${d.id}/decider`, { valider: true }), 'Demande validée', liste.reload)}>Valider</Button>
                <Button small variant="danger" onClick={() => setRejet(d)}>Rejeter</Button></span>
              : d.statut === 'en_attente' && d.demande_par === user?.id ? <span className="muted">à valider par un autre</span> : null },
          ]} />
        )}
      </Charge>
      {nouvelle && <DemandeModal onClose={() => setNouvelle(false)} onFait={() => { setNouvelle(false); liste.reload() }} />}
      {rejet && <RejetModal demande={rejet} onClose={() => setRejet(null)} onFait={() => { setRejet(null); liste.reload() }} />}
    </Card>
  )
}

function DemandeModal({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const { articles, destinations } = useFormulaire()
  const { run, busy } = useAction()
  const [f, setF] = useState({ type: 'sortie', article: '', lieu: '', quantite: '', motif: '', date: aujourdhui() })
  const lieu = destinations.find((d) => cle(d) === f.lieu)
  return (
    <FormModal titre="Nouvelle demande" onClose={onClose} busy={busy} large valider="Envoyer pour validation"
      onSubmit={() => lieu && void run(() => api.post('/api/stock/demandes', {
        type: f.type, article_id: Number(f.article), lieu: ref(lieu), quantite: Number(f.quantite), date_effet: f.date, motif: f.motif.trim(),
      }), 'Demande envoyée', onFait)}>
      <Field label="Nature">
        <Select value={f.type} onChange={(e) => setF({ ...f, type: e.target.value })}>
          <option value="sortie">Sortie de stock (consommation, remise)</option><option value="rebut">Mise au rebut (perte, casse, péremption)</option><option value="inventaire">Inventaire (quantité comptée)</option>
        </Select>
      </Field>
      <Field label="Article"><Select value={f.article} onChange={(e) => setF({ ...f, article: e.target.value })} required><option value="">— choisir —</option>{articles.filter((a) => a.actif).map((a) => <option key={a.id} value={a.id}>{a.code} · {a.designation}</option>)}</Select></Field>
      <LieuSelect label="Lieu" destinations={destinations} valeur={f.lieu} onChange={(v) => setF({ ...f, lieu: v })} />
      <div className="row">
        <Field label={f.type === 'inventaire' ? 'Quantité comptée' : 'Quantité'} hint={f.type === 'inventaire' ? 'L’écart avec le stock théorique est calculé à la validation' : undefined}>
          <Input type="number" min={f.type === 'inventaire' ? 0 : 0.001} step="any" value={f.quantite} onChange={(e) => setF({ ...f, quantite: e.target.value })} required />
        </Field>
        <Field label="Date d’effet"><Input type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} required /></Field>
      </div>
      <Field label="Motif"><Input value={f.motif} minLength={5} onChange={(e) => setF({ ...f, motif: e.target.value })} required /></Field>
    </FormModal>
  )
}

function RejetModal({ demande, onClose, onFait }: { demande: Demande; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [motif, setMotif] = useState('')
  return (
    <FormModal titre={`Rejeter la demande n° ${demande.id}`} onClose={onClose} busy={busy} valider="Rejeter"
      onSubmit={() => void run(() => api.post(`/api/stock/demandes/${demande.id}/decider`, { valider: false, motif: motif.trim() }), 'Demande rejetée', onFait)}>
      <Field label="Motif du rejet"><Input value={motif} minLength={5} onChange={(e) => setMotif(e.target.value)} required /></Field>
    </FormModal>
  )
}

/* ---------------------------------------------------------------- alertes */
function Alertes() {
  const { agenceId } = useSession()
  const liste = useFetch(() => api.get<Alerte[]>('/api/stock/alertes'), [agenceId])
  return (
    <Card title="Articles sous le seuil d’alerte" flush>
      <Charge q={liste}>
        {(rows) => (
          <Table rows={rows} vide="Aucune alerte : tous les stocks sont au-dessus de leur seuil" cols={[
            { titre: 'Périmètre', render: (a) => a.perimetre }, { titre: 'Article', render: (a) => <><strong>{a.article_code}</strong> · {a.designation}</> },
            { titre: 'En stock', num: true, render: (a) => `${nombre(a.quantite)} ${a.unite}` }, { titre: 'Seuil', num: true, render: (a) => nombre(a.seuil_alerte) },
            { titre: 'Niveau', render: (a) => (a.rupture ? <Badge tone="bad">Rupture</Badge> : <Badge tone="warn">Sous le seuil</Badge>) },
          ]} />
        )}
      </Charge>
    </Card>
  )
}

/* ---------------------------------------------------------------- immobilisations affectées */
function Immobilisations() {
  const { can, agenceId } = useSession()
  const [statut, setStatut] = useState('')
  const [creation, setCreation] = useState(false)
  const [ouvert, setOuvert] = useState<Unite | null>(null)
  const liste = useFetch(() => api.get<Unite[]>('/api/stock/immobilisations', { statut: statut || undefined }), [statut, agenceId])
  return (
    <Card flush actions={can('immobilisation:gerer') && <Button variant="primary" onClick={() => setCreation(true)}>Enregistrer une unité</Button>}>
      <div className="card-b row">
        <Field label="Statut"><Select value={statut} onChange={(e) => setStatut(e.target.value)}><option value="">Tous</option><option value="en_service">En service</option><option value="en_maintenance">En maintenance</option><option value="hors_service">Hors service</option><option value="sortie">Sortie</option></Select></Field>
      </div>
      <Charge q={liste}>
        {(rows) => (
          <Table rows={rows} onRowClick={setOuvert} vide="Aucune unité enregistrée" cols={[
            { titre: 'Numéro', render: (u) => <strong>{u.numero}</strong> }, { titre: 'Désignation', render: (u) => u.designation },
            { titre: 'Article', render: (u) => u.article_code }, { titre: 'N° de série', render: (u) => u.numero_serie ?? '' },
            { titre: 'Affecté à', render: (u) => (u.affecte_a ? `${u.affecte_a} (depuis ${fdate(u.affecte_depuis ?? '')})` : <span className="muted">non affecté</span>) },
            { titre: 'Valeur nette', num: true, render: (u) => xof(u.valeur_nette) }, { titre: 'Statut', render: (u) => <Badge tone={TON_IMMO[u.statut] ?? 'neutre'}>{u.statut.replace('_', ' ')}</Badge> },
          ]} />
        )}
      </Charge>
      {creation && <UniteModal onClose={() => setCreation(false)} onFait={() => { setCreation(false); liste.reload() }} />}
      {ouvert && <UniteDetail unite={ouvert} onClose={() => setOuvert(null)} onFait={() => { setOuvert(null); liste.reload() }} />}
    </Card>
  )
}

function UniteModal({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const { agences, agenceId, user } = useSession()
  const articles = useFetch(() => api.get<Article[]>('/api/stock/articles', { type: 'immobilisable' }), [])
  const agents = useFetch(() => api.get<Destination[]>('/api/stock/destinations'), [])
  const { run, busy } = useAction()
  const [f, setF] = useState({ article: '', designation: '', acquisition: aujourdhui(), service: aujourdhui(), valeur: '', serie: '', agent: '', agence: String(agenceId ?? user?.agence_id ?? '') })
  const agentsAgence = (agents.data ?? []).filter((d) => d.type === 'agent' && String(d.agence_id) === f.agence)
  return (
    <FormModal titre="Enregistrer une unité immobilisée" onClose={onClose} busy={busy} large
      onSubmit={() => void run(() => api.post('/api/stock/immobilisations', {
        article_id: Number(f.article), designation: f.designation.trim(), date_acquisition: f.acquisition, date_mise_en_service: f.service, valeur_acquisition: Number(f.valeur),
        numero_serie: f.serie || null, utilisateur_id: f.agent ? Number(f.agent) : null, agence_id: f.agence ? Number(f.agence) : null,
      }), 'Unité enregistrée au registre', onFait)}>
      <Field label="Article"><Select value={f.article} onChange={(e) => setF({ ...f, article: e.target.value })} required><option value="">— choisir —</option>{articles.data?.filter((a) => a.actif).map((a) => <option key={a.id} value={a.id}>{a.code} · {a.designation}</option>)}</Select></Field>
      <Field label="Désignation de l’unité"><Input value={f.designation} minLength={3} onChange={(e) => setF({ ...f, designation: e.target.value })} required /></Field>
      <div className="row">
        <Field label="Date d’acquisition"><Input type="date" value={f.acquisition} onChange={(e) => setF({ ...f, acquisition: e.target.value })} required /></Field>
        <Field label="Mise en service"><Input type="date" value={f.service} min={f.acquisition} onChange={(e) => setF({ ...f, service: e.target.value })} required /></Field>
      </div>
      <div className="row">
        <Field label="Valeur d’acquisition (F)"><Input type="number" min={1} value={f.valeur} onChange={(e) => setF({ ...f, valeur: e.target.value })} required /></Field>
        <Field label="N° de série / IMEI"><Input value={f.serie} onChange={(e) => setF({ ...f, serie: e.target.value })} /></Field>
      </div>
      <div className="row">
        {agences.length > 1 && <Field label="Agence"><Select value={f.agence} onChange={(e) => setF({ ...f, agence: e.target.value, agent: '' })} required><option value="">— choisir —</option>{agences.map((a) => <option key={a.id} value={a.id}>{a.libelle}</option>)}</Select></Field>}
        <Field label="Affecter à un agent (facultatif)"><Select value={f.agent} onChange={(e) => setF({ ...f, agent: e.target.value })}><option value="">Non affecté</option>{agentsAgence.map((d) => <option key={d.utilisateur_id} value={d.utilisateur_id ?? ''}>{d.libelle}</option>)}</Select></Field>
      </div>
    </FormModal>
  )
}

function UniteDetail({ unite, onClose, onFait }: { unite: Unite; onClose: () => void; onFait: () => void }) {
  const { can } = useSession()
  const { run, busy } = useAction()
  const agents = useFetch(() => api.get<Destination[]>('/api/stock/destinations'), [])
  const hist = useFetch(() => api.get<{ id: number; agent: string; date_debut: string; date_fin: string | null; motif: string | null }[]>(`/api/stock/immobilisations/${unite.id}/affectations`), [unite.id])
  const [agent, setAgent] = useState('')
  const [rebut, setRebut] = useState('')
  const possibles = (agents.data ?? []).filter((d) => d.type === 'agent' && d.agence_id === unite.agence_id)
  const actif = unite.statut !== 'sortie'
  return (
    <FormModal titre={`${unite.numero} · ${unite.designation}`} onClose={onClose} busy={busy} valider="Fermer" onSubmit={onClose} large>
      <p className="muted" style={{ margin: 0 }}>{unite.article_designation} · valeur {xof(unite.valeur_acquisition)} · valeur nette {xof(unite.valeur_nette)}{unite.affecte_a ? ` · affecté à ${unite.affecte_a}` : ' · non affecté'}</p>
      {actif && can('stock:mouvoir') && (
        <div className="row">
          <Field label="Affecter à"><Select value={agent} onChange={(e) => setAgent(e.target.value)}><option value="">— agent —</option>{possibles.map((d) => <option key={d.utilisateur_id} value={d.utilisateur_id ?? ''}>{d.libelle}</option>)}</Select></Field>
          <Button variant="primary" disabled={busy || !agent} onClick={() => void run(() => api.post(`/api/stock/immobilisations/${unite.id}/affecter`, { utilisateur_id: Number(agent) }), 'Affectation enregistrée', onFait)}>Affecter</Button>
          {unite.affecte_a && <Button disabled={busy} onClick={() => void run(() => api.post(`/api/stock/immobilisations/${unite.id}/restituer`, {}), 'Restitution enregistrée', onFait)}>Restituer</Button>}
        </div>
      )}
      <strong>Historique des affectations</strong>
      <Charge q={hist}>{(rows) => <Table rows={rows} vide="Jamais affecté" cols={[
        { titre: 'Agent', render: (h) => h.agent }, { titre: 'Du', render: (h) => fdate(h.date_debut) }, { titre: 'Au', render: (h) => (h.date_fin ? fdate(h.date_fin) : 'en cours') }, { titre: 'Motif', render: (h) => h.motif ?? '' }]} />}</Charge>
      {actif && can('stock:mouvoir') && (
        <div className="row">
          <Field label="Mise au rebut (validée par une autre personne)"><Input value={rebut} placeholder="Motif (5 caractères minimum)" onChange={(e) => setRebut(e.target.value)} /></Field>
          <Button variant="danger" disabled={busy || rebut.trim().length < 5} onClick={() => void run(() => api.post('/api/stock/demandes', { type: 'rebut_immobilisation', immobilisation_id: unite.id, motif: rebut.trim() }), 'Demande de mise au rebut envoyée', onFait)}>Demander la mise au rebut</Button>
        </div>
      )}
    </FormModal>
  )
}
