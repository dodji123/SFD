import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Modal, Page, Select, Table, Tabs, useAction, useFetch } from '../components/ui'

interface Immo {
  id: number; numero: string; designation: string; categorie: string; categorie_libelle: string; date_mise_en_service: string; valeur_acquisition: number
  cumul_amortissement: number; valeur_nette: number; statut: string; totalement_amortie: boolean; agence_id: number; localisation: string | null
  date_sortie: string | null; type_sortie: string | null; valeur_cession: number | null
}
interface Amort { annee: number; mois: number; montant: number; cumul_apres: number }
interface Intervention {
  id: number; immobilisation_numero: string; immobilisation: string; type: string; statut: string; priorite: string; description: string
  tiers_nom: string | null; cout_total: number; agence_id: number; ouverte: boolean; age_jours: number
}
interface Categorie { code: string; libelle: string; duree_annees: number | null }
interface Alerte { agence_id: number; type: string; reference: string; detail: string; echeance: string | null }
interface Cout { numero: string; designation: string; valeur_acquisition: number; nb_interventions: number; cout_total: number; cout_reparations: number }

const STATUT_IMMO: Record<string, { texte: string; tone: 'ok' | 'warn' | 'bad' | 'neutre' }> = {
  en_service: { texte: 'En service', tone: 'ok' }, en_maintenance: { texte: 'En maintenance', tone: 'warn' }, hors_service: { texte: 'Hors service', tone: 'bad' }, sortie: { texte: 'Sortie', tone: 'neutre' },
}
const STATUT_INTERV: Record<string, { texte: string; tone: 'ok' | 'warn' | 'bad' | 'neutre' }> = {
  signalee: { texte: 'Signalée', tone: 'bad' }, planifiee: { texte: 'Planifiée', tone: 'warn' }, en_cours: { texte: 'En cours', tone: 'warn' }, terminee: { texte: 'Terminée', tone: 'ok' }, annulee: { texte: 'Annulée', tone: 'neutre' },
}
const LIB_ALERTE: Record<string, string> = {
  maintenance_en_retard: 'Maintenance en retard', maintenance_a_prevoir: 'Maintenance à prévoir', reparation_longue: 'Réparation trop longue', panne_urgente: 'Panne urgente non prise en charge',
  garantie_proche_fin: 'Garantie proche de la fin', totalement_amortie: 'Totalement amortie, toujours en service',
}

/** Immobilisations, maintenance, réparations et alertes. */
export default function Immobilisations() {
  const [onglet, setOnglet] = useState('registre')
  return (
    <Page title="Immobilisations et maintenance" subtitle="Registre des biens, amortissements, pannes, réparations et alertes">
      <Tabs actif={onglet} onChange={setOnglet} tabs={[
        { id: 'registre', titre: 'Registre' }, { id: 'interventions', titre: 'Pannes et interventions' }, { id: 'alertes', titre: 'Alertes et coûts' },
      ]} />
      {onglet === 'registre' && <Registre />}
      {onglet === 'interventions' && <Interventions />}
      {onglet === 'alertes' && <AlertesEtCouts />}
    </Page>
  )
}

function Registre() {
  const { can, agenceId } = useSession()
  const { run, busy } = useAction()
  const [statut, setStatut] = useState('')
  const [q, setQ] = useState('')
  const [creation, setCreation] = useState(false)
  const [ouvert, setOuvert] = useState<Immo | null>(null)
  const liste = useFetch(() => api.get<Immo[]>('/api/immobilisations', { statut, q }), [statut, q, agenceId])
  return (
    <Card flush actions={can('immobilisation:gerer') && <span className="row">
      <Button disabled={busy} onClick={() => void run(() => api.post('/api/immobilisations/amortissements/calculer', {}), 'Amortissements constatés', liste.reload)}>Constater les amortissements</Button>
      <Button variant="primary" onClick={() => setCreation(true)}>Nouvelle immobilisation</Button></span>}>
      <div className="card-b row">
        <Field label="Recherche"><Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Désignation ou numéro" /></Field>
        <Field label="Statut"><Select value={statut} onChange={(e) => setStatut(e.target.value)}><option value="">Tous</option>{Object.entries(STATUT_IMMO).map(([k, v]) => <option key={k} value={k}>{v.texte}</option>)}</Select></Field>
      </div>
      <Charge q={liste}>
        {(rows) => (
          <Table rows={rows} onRowClick={setOuvert} vide="Aucune immobilisation" cols={[
            { titre: 'Numéro', render: (i) => <strong>{i.numero}</strong> }, { titre: 'Désignation', render: (i) => i.designation },
            { titre: 'Catégorie', render: (i) => i.categorie_libelle }, { titre: 'Mise en service', render: (i) => fdate(i.date_mise_en_service) },
            { titre: 'Valeur', num: true, render: (i) => xof(i.valeur_acquisition) }, { titre: 'Valeur nette', num: true, render: (i) => xof(i.valeur_nette) },
            { titre: 'Statut', render: (i) => <><Badge tone={STATUT_IMMO[i.statut]?.tone ?? 'neutre'}>{STATUT_IMMO[i.statut]?.texte ?? i.statut}</Badge>{i.totalement_amortie && i.statut !== 'sortie' && <> <Badge tone="warn">Amortie</Badge></>}</> },
          ]} />
        )}
      </Charge>
      {creation && <CreationImmo onClose={() => setCreation(false)} onFait={() => { setCreation(false); liste.reload() }} />}
      {ouvert && <DetailImmo id={ouvert.id} onClose={() => setOuvert(null)} onFait={() => { setOuvert(null); liste.reload() }} />}
    </Card>
  )
}

function CreationImmo({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const categories = useFetch(() => api.get<Categorie[]>('/api/categories-immobilisation'), [])
  const { run, busy } = useAction()
  const [f, setF] = useState({ designation: '', categorie: '', acquisition: aujourdhui(), service: aujourdhui(), valeur: '', residuelle: '0', localisation: '', garantie: '' })
  return (
    <FormModal titre="Nouvelle immobilisation" onClose={onClose} busy={busy} valider="Enregistrer" large
      onSubmit={() => void run(() => api.post('/api/immobilisations', {
        designation: f.designation.trim(), categorie: f.categorie, date_acquisition: f.acquisition, date_mise_en_service: f.service, valeur_acquisition: Number(f.valeur),
        valeur_residuelle: Number(f.residuelle || 0), localisation: f.localisation || null, date_fin_garantie: f.garantie || null,
      }), 'Immobilisation enregistrée', onFait)}>
      <Field label="Désignation"><Input value={f.designation} minLength={3} onChange={(e) => setF({ ...f, designation: e.target.value })} required /></Field>
      <Field label="Catégorie">
        <Select value={f.categorie} onChange={(e) => setF({ ...f, categorie: e.target.value })} required><option value="">— choisir —</option>{categories.data?.map((c) => <option key={c.code} value={c.code}>{c.libelle}{c.duree_annees ? ` (${c.duree_annees} ans)` : ' (non amortissable)'}</option>)}</Select>
      </Field>
      <div className="row">
        <Field label="Date d'acquisition"><Input type="date" value={f.acquisition} onChange={(e) => setF({ ...f, acquisition: e.target.value })} required /></Field>
        <Field label="Mise en service"><Input type="date" value={f.service} min={f.acquisition} onChange={(e) => setF({ ...f, service: e.target.value })} required /></Field>
      </div>
      <div className="row">
        <Field label="Valeur d'acquisition (F)"><Input type="number" min={1} value={f.valeur} onChange={(e) => setF({ ...f, valeur: e.target.value })} required /></Field>
        <Field label="Valeur résiduelle (F)"><Input type="number" min={0} value={f.residuelle} onChange={(e) => setF({ ...f, residuelle: e.target.value })} /></Field>
      </div>
      <Field label="Localisation"><Input value={f.localisation} onChange={(e) => setF({ ...f, localisation: e.target.value })} /></Field>
      <Field label="Fin de garantie (facultatif)"><Input type="date" value={f.garantie} onChange={(e) => setF({ ...f, garantie: e.target.value })} /></Field>
    </FormModal>
  )
}

function DetailImmo({ id, onClose, onFait }: { id: number; onClose: () => void; onFait: () => void }) {
  const { can } = useSession()
  const d = useFetch(() => api.get<Immo & { amortissements: Amort[]; interventions: Intervention[] }>(`/api/immobilisations/${id}`), [id])
  const [panne, setPanne] = useState(false)
  const [sortie, setSortie] = useState(false)
  return (
    <Modal titre="Immobilisation" onClose={onClose} large footer={<Button onClick={onClose}>Fermer</Button>}>
      <Charge q={d}>
        {(i) => (
          <div className="stack">
            <p style={{ margin: 0 }}><strong>{i.numero}</strong> · {i.designation} · <Badge tone={STATUT_IMMO[i.statut]?.tone ?? 'neutre'}>{STATUT_IMMO[i.statut]?.texte ?? i.statut}</Badge></p>
            <p style={{ margin: 0 }} className="muted">Valeur {xof(i.valeur_acquisition)} · amortissements {xof(i.cumul_amortissement)} · valeur nette {xof(i.valeur_nette)}{i.localisation ? ` · ${i.localisation}` : ''}</p>
            {i.statut !== 'sortie' && can('maintenance:signaler') && (
              <div className="row"><Button onClick={() => setPanne(true)}>Signaler une panne</Button>{can('immobilisation:gerer') && <Button variant="danger" onClick={() => setSortie(true)}>Sortir de l’inventaire</Button>}</div>
            )}
            {i.statut === 'sortie' && <Alert tone="info">Sortie le {fdate(i.date_sortie ?? '')} ({i.type_sortie}{i.valeur_cession ? `, cession ${xof(i.valeur_cession)}` : ''}).</Alert>}
            <strong>Dotations</strong>
            <Table rows={i.amortissements} vide="Aucune dotation constatée" cols={[
              { titre: 'Mois', render: (a) => `${String(a.mois).padStart(2, '0')}/${a.annee}` }, { titre: 'Dotation', num: true, render: (a) => xof(a.montant) },
              { titre: 'Cumul', num: true, render: (a) => xof(a.cumul_apres) }]} />
            <strong>Interventions</strong>
            <Table rows={i.interventions} vide="Aucune intervention" cols={[
              { titre: 'Type', render: (x) => (x.type === 'corrective' ? 'Réparation' : 'Préventive') },
              { titre: 'Statut', render: (x) => <Badge tone={STATUT_INTERV[x.statut]?.tone ?? 'neutre'}>{STATUT_INTERV[x.statut]?.texte ?? x.statut}</Badge> },
              { titre: 'Description', render: (x) => x.description }, { titre: 'Coût', num: true, render: (x) => xof(x.cout_total) }]} />
            {panne && <PanneModal immo={i.id} onClose={() => setPanne(false)} onFait={() => { setPanne(false); onFait() }} />}
            {sortie && <SortieModal immo={i.id} onClose={() => setSortie(false)} onFait={() => { setSortie(false); onFait() }} />}
          </div>
        )}
      </Charge>
    </Modal>
  )
}

function PanneModal({ immo, onClose, onFait }: { immo: number; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ description: '', priorite: 'normale', horsService: false })
  return (
    <FormModal titre="Signaler une panne" onClose={onClose} busy={busy} valider="Signaler"
      onSubmit={() => void run(() => api.post(`/api/immobilisations/${immo}/pannes`, { description: f.description.trim(), priorite: f.priorite, hors_service: f.horsService }), 'Panne signalée', onFait)}>
      <Field label="Description"><Input value={f.description} minLength={5} onChange={(e) => setF({ ...f, description: e.target.value })} required /></Field>
      <Field label="Priorité"><Select value={f.priorite} onChange={(e) => setF({ ...f, priorite: e.target.value })}><option value="basse">Basse</option><option value="normale">Normale</option><option value="haute">Haute</option><option value="urgente">Urgente</option></Select></Field>
      <label className="row" style={{ gap: 8, alignItems: 'center' }}><input type="checkbox" checked={f.horsService} onChange={(e) => setF({ ...f, horsService: e.target.checked })} /> Le bien ne peut plus servir jusqu’à réparation</label>
    </FormModal>
  )
}

function SortieModal({ immo, onClose, onFait }: { immo: number; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ date: aujourdhui(), type: 'rebut', cession: '', motif: '' })
  return (
    <FormModal titre="Sortir de l’inventaire" onClose={onClose} busy={busy} valider="Confirmer la sortie"
      onSubmit={() => void run(() => api.post(`/api/immobilisations/${immo}/sortie`, { date_sortie: f.date, type_sortie: f.type, valeur_cession: f.type === 'cession' ? Number(f.cession) : null, motif: f.motif.trim() }), 'Sortie enregistrée', onFait)}>
      <Alert tone="warn">La sortie clôt les amortissements et les plans de maintenance. Une intervention encore ouverte bloque la sortie.</Alert>
      <Field label="Date de sortie"><Input type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} required /></Field>
      <Field label="Type"><Select value={f.type} onChange={(e) => setF({ ...f, type: e.target.value })}><option value="cession">Cession (vente)</option><option value="rebut">Rebut</option><option value="perte">Perte ou vol</option></Select></Field>
      {f.type === 'cession' && <Field label="Prix de cession (F)"><Input type="number" min={0} value={f.cession} onChange={(e) => setF({ ...f, cession: e.target.value })} required /></Field>}
      <Field label="Motif"><Input value={f.motif} minLength={5} onChange={(e) => setF({ ...f, motif: e.target.value })} required /></Field>
    </FormModal>
  )
}

function Interventions() {
  const { can, agenceId } = useSession()
  const [ouvertes, setOuvertes] = useState('true')
  const [terminer, setTerminer] = useState<Intervention | null>(null)
  const { run, busy } = useAction()
  const liste = useFetch(() => api.get<Intervention[]>('/api/interventions', { ouvertes }), [ouvertes, agenceId])
  const demarrer = (x: Intervention) => void run(() => api.post(`/api/interventions/${x.id}/demarrer`, {}), 'Intervention démarrée', liste.reload)
  return (
    <Card flush>
      <div className="card-b row">
        <Field label="État"><Select value={ouvertes} onChange={(e) => setOuvertes(e.target.value)}><option value="true">En cours de traitement</option><option value="">Toutes</option></Select></Field>
      </div>
      <Charge q={liste}>
        {(rows) => (
          <Table rows={rows} vide="Aucune intervention" cols={[
            { titre: 'Bien', render: (x) => <><strong>{x.immobilisation_numero}</strong><div className="muted">{x.immobilisation}</div></> },
            { titre: 'Type', render: (x) => (x.type === 'corrective' ? 'Réparation' : 'Préventive') },
            { titre: 'Priorité', render: (x) => x.priorite }, { titre: 'Description', render: (x) => x.description },
            { titre: 'Statut', render: (x) => <Badge tone={STATUT_INTERV[x.statut]?.tone ?? 'neutre'}>{STATUT_INTERV[x.statut]?.texte ?? x.statut}</Badge> },
            { titre: 'Depuis', num: true, render: (x) => `${x.age_jours} j` },
            { titre: 'Prestataire', render: (x) => x.tiers_nom ?? '' },
            { titre: '', render: (x) => can('maintenance:gerer') && x.ouverte && (
              <span className="row">
                {(x.statut === 'signalee' || x.statut === 'planifiee') && <Button small disabled={busy} onClick={() => demarrer(x)}>Démarrer</Button>}
                {x.statut === 'en_cours' && <Button small variant="primary" onClick={() => setTerminer(x)}>Terminer</Button>}
              </span>
            ) },
          ]} />
        )}
      </Charge>
      {terminer && <TerminerModal x={terminer} onClose={() => setTerminer(null)} onFait={() => { setTerminer(null); liste.reload() }} />}
    </Card>
  )
}

function TerminerModal({ x, onClose, onFait }: { x: Intervention; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ resultat: '', main: '0', pieces: '0', facture: '' })
  const cout = Number(f.main || 0) + Number(f.pieces || 0)
  return (
    <FormModal titre={`Terminer : ${x.immobilisation_numero}`} onClose={onClose} busy={busy} valider="Terminer l’intervention"
      onSubmit={() => void run(() => api.post(`/api/interventions/${x.id}/terminer`, {
        date_fin: aujourdhui(), resultat: f.resultat.trim(), cout_main_oeuvre: Number(f.main || 0), cout_pieces: Number(f.pieces || 0), reference_facture: f.facture.trim() || null,
      }), 'Intervention terminée', onFait)}>
      <Field label="Résultat"><Input value={f.resultat} minLength={5} onChange={(e) => setF({ ...f, resultat: e.target.value })} required /></Field>
      <div className="row">
        <Field label="Main-d'œuvre (F)"><Input type="number" min={0} value={f.main} onChange={(e) => setF({ ...f, main: e.target.value })} /></Field>
        <Field label="Pièces (F)"><Input type="number" min={0} value={f.pieces} onChange={(e) => setF({ ...f, pieces: e.target.value })} /></Field>
      </div>
      {cout > 0 && <Field label="Référence de la facture du prestataire"><Input value={f.facture} onChange={(e) => setF({ ...f, facture: e.target.value })} required /></Field>}
      {cout > 0 && <Alert tone="info">Coût {xof(cout)} : une dépense « entretien et réparation à payer » est créée automatiquement.</Alert>}
    </FormModal>
  )
}

function AlertesEtCouts() {
  const { agenceId } = useSession()
  const alertes = useFetch(() => api.get<Alerte[]>('/api/immobilisations-alertes'), [agenceId])
  const couts = useFetch(() => api.get<Cout[]>('/api/immobilisations-couts'), [agenceId])
  return (
    <div className="stack">
      <Card title={`Alertes (${alertes.data?.length ?? 0})`} flush>
        <Charge q={alertes}>
          {(rows) => (
            <Table rows={rows} vide="Aucune alerte" cols={[
              { titre: 'Type', render: (a) => <Badge tone="warn">{LIB_ALERTE[a.type] ?? a.type}</Badge> }, { titre: 'Bien', render: (a) => a.reference },
              { titre: 'Détail', render: (a) => a.detail }, { titre: 'Échéance', render: (a) => (a.echeance ? fdate(a.echeance) : '') }]} />
          )}
        </Charge>
      </Card>
      <Card title="Coût de maintenance par bien" flush>
        <Charge q={couts}>
          {(rows) => (
            <Table rows={rows} vide="Aucun coût" cols={[
              { titre: 'Bien', render: (c) => <><strong>{c.numero}</strong><div className="muted">{c.designation}</div></> },
              { titre: 'Interventions', num: true, render: (c) => c.nb_interventions }, { titre: 'Réparations', num: true, render: (c) => xof(c.cout_reparations) },
              { titre: 'Coût total', num: true, render: (c) => <strong>{xof(c.cout_total)}</strong> }, { titre: 'Valeur d’acquisition', num: true, render: (c) => xof(c.valeur_acquisition) }]} />
          )}
        </Charge>
      </Card>
    </div>
  )
}
