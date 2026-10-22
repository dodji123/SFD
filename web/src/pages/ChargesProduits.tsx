import { useEffect, useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Kpi, Page, Select, Table, Tabs, useAction, useFetch } from '../components/ui'

interface Mois { mois: number; produits: number; charges: number; produits_prevus: number; charges_prevues: number; resultat: number }
interface Synthese { annee: number; mensuel: Mois[]; total: { produits: number; charges: number; produits_prevus: number; charges_prevues: number; resultat: number } }
interface LigneBudget { agence_id: number; annee: number; mois: number; categorie: string; code_operation: string; libelle: string; prevu: number; realise: number; ecart: number; taux: number | null; depassement: boolean }
interface Alerte { agence_id: number; type: string; reference: string; detail: string; montant: number }
interface Tiers { id: number; nom: string; type: string; telephone: string | null; adresse: string | null; identifiant_fiscal: string | null; actif: boolean; agence: string | null }
interface Recurrente { id: number; operation: string; categorie: string; montant: number; tiers: string | null; libelle: string | null; periodicite: string; jour_du_mois: number; prochaine_date: string; date_fin: string | null; actif: boolean; derniere_generation: string | null }
interface OperationStandard { code: string; libelle: string; famille: string; categorie: string }

const MOIS = ['janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet', 'août', 'septembre', 'octobre', 'novembre', 'décembre']
const TYPES_TIERS: Record<string, string> = { fournisseur: 'Fournisseur', bailleur: 'Bailleur', prestataire: 'Prestataire', administration: 'Administration', autre: 'Autre' }
const PERIODES: Record<string, string> = { mensuelle: 'Mensuelle', trimestrielle: 'Trimestrielle', annuelle: 'Annuelle' }
const LIB_ALERTE: Record<string, string> = { depassement_budget: 'Dépassement de budget', operation_a_valider: 'Opération en attente de validation', recurrente_en_retard: 'Opération récurrente en retard' }

/** Charges et produits : synthèse, budget prévu / réalisé, tiers, opérations récurrentes et alertes. */
export default function ChargesProduits() {
  const [onglet, setOnglet] = useState('synthese')
  const [annee, setAnnee] = useState(new Date().getFullYear())
  return (
    <Page title="Charges et produits" subtitle="Suivi des charges et des produits, budget mensuel, tiers et opérations récurrentes">
      <div className="row">
        <Field label="Année"><Input type="number" min={2000} max={2100} value={annee} onChange={(e) => setAnnee(Number(e.target.value) || new Date().getFullYear())} /></Field>
      </div>
      <Tabs actif={onglet} onChange={setOnglet} tabs={[{ id: 'synthese', titre: 'Synthèse' }, { id: 'budget', titre: 'Budget prévu / réalisé' }, { id: 'tiers', titre: 'Tiers' }, { id: 'recurrentes', titre: 'Opérations récurrentes' }]} />
      {onglet === 'synthese' && <SyntheseAnnee annee={annee} />}
      {onglet === 'budget' && <BudgetAnnee annee={annee} />}
      {onglet === 'tiers' && <ListeTiers />}
      {onglet === 'recurrentes' && <Recurrentes />}
    </Page>
  )
}

function SyntheseAnnee({ annee }: { annee: number }) {
  const { agenceId } = useSession()
  const q = useFetch(() => api.get<Synthese>('/api/charges-produits/synthese', { annee }), [annee, agenceId])
  const alertes = useFetch(() => api.get<Alerte[]>('/api/charges-produits/alertes'), [agenceId])
  return (
    <div className="stack">
      {(alertes.data?.length ?? 0) > 0 && (
        <Card title={`Alertes (${alertes.data?.length})`} flush>
          <Table rows={alertes.data ?? []} cols={[{ titre: 'Type', render: (a) => <Badge tone="warn">{LIB_ALERTE[a.type] ?? a.type}</Badge> }, { titre: 'Référence', render: (a) => a.reference }, { titre: 'Détail', render: (a) => a.detail }, { titre: 'Montant', num: true, render: (a) => xof(a.montant) }]} />
        </Card>
      )}
      <Charge q={q}>
        {(s) => (
          <>
            <div className="grid-kpi">
              <Kpi label="Produits" value={xof(s.total.produits)} />
              <Kpi label="Charges" value={xof(s.total.charges)} />
              <Kpi label="Résultat" value={xof(s.total.resultat)} />
              <Kpi label="Charges prévues" value={xof(s.total.charges_prevues)} />
            </div>
            <Card title={`Évolution ${s.annee}`} flush>
              <Table rows={s.mensuel} vide="Aucune opération ni budget cette année" cols={[
                { titre: 'Mois', render: (m) => MOIS[m.mois - 1] }, { titre: 'Produits', num: true, render: (m) => xof(m.produits) }, { titre: 'Produits prévus', num: true, render: (m) => xof(m.produits_prevus) },
                { titre: 'Charges', num: true, render: (m) => xof(m.charges) }, { titre: 'Charges prévues', num: true, render: (m) => xof(m.charges_prevues) },
                { titre: 'Résultat', num: true, render: (m) => <strong>{xof(m.resultat)}</strong> },
              ]} />
            </Card>
          </>
        )}
      </Charge>
    </div>
  )
}

function BudgetAnnee({ annee }: { annee: number }) {
  const { can, agenceId } = useSession()
  const [mois, setMois] = useState('')
  const [categorie, setCategorie] = useState('')
  const [depassement, setDepassement] = useState('')
  const [saisie, setSaisie] = useState(false)
  const q = useFetch(() => api.get<LigneBudget[]>('/api/budget-charges-produits', { annee, mois, categorie, depassement }), [annee, mois, categorie, depassement, agenceId])
  return (
    <Card flush actions={can('budget:gerer') && <Button variant="primary" onClick={() => setSaisie(true)}>Saisir le budget</Button>}>
      <div className="card-b row">
        <Field label="Mois"><Select value={mois} onChange={(e) => setMois(e.target.value)}><option value="">Tous</option>{MOIS.map((m, i) => <option key={m} value={i + 1}>{m}</option>)}</Select></Field>
        <Field label="Nature"><Select value={categorie} onChange={(e) => setCategorie(e.target.value)}><option value="">Toutes</option><option value="charge">Charges</option><option value="produit">Produits</option></Select></Field>
        <Field label="Dépassement"><Select value={depassement} onChange={(e) => setDepassement(e.target.value)}><option value="">Tous</option><option value="true">Charges en dépassement</option></Select></Field>
      </div>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucune ligne de budget ni opération" cols={[
            { titre: 'Mois', render: (l) => MOIS[l.mois - 1] }, { titre: 'Nature', render: (l) => (l.categorie === 'charge' ? 'Charge' : 'Produit') }, { titre: 'Opération', render: (l) => l.libelle },
            { titre: 'Prévu', num: true, render: (l) => xof(l.prevu) }, { titre: 'Réalisé', num: true, render: (l) => xof(l.realise) }, { titre: 'Écart', num: true, render: (l) => xof(l.ecart) },
            { titre: 'Taux', num: true, render: (l) => (l.taux === null ? '—' : `${l.taux} %`) },
            { titre: '', render: (l) => (l.depassement ? <Badge tone="bad">Dépassement</Badge> : null) },
          ]} />
        )}
      </Charge>
      {saisie && <SaisieBudget annee={annee} onClose={() => setSaisie(false)} onFait={() => { setSaisie(false); q.reload() }} />}
    </Card>
  )
}

function SaisieBudget({ annee, onClose, onFait }: { annee: number; onClose: () => void; onFait: () => void }) {
  const { agenceId } = useSession()
  const catalogue = useFetch(() => api.get<OperationStandard[]>('/api/operations-standard', { actif: 'true' }), [])
  const { run, busy } = useAction()
  const [f, setF] = useState({ mois: String(new Date().getMonth() + 1), code: '', montant: '', tousLesMois: false })
  const eligibles = (catalogue.data ?? []).filter((o) => o.categorie === 'charge' || o.categorie === 'produit')
  return (
    <FormModal titre={`Budget ${annee}`} onClose={onClose} busy={busy} valider="Enregistrer"
      onSubmit={() => void run(() => api.put('/api/budget-charges-produits', {
        annee, agence_id: agenceId,
        lignes: (f.tousLesMois ? Array.from({ length: 12 }, (_, i) => i + 1) : [Number(f.mois)]).map((m) => ({ mois: m, code_operation: f.code, montant_prevu: Number(f.montant) })),
      }), 'Budget enregistré', onFait)}>
      <Field label="Opération (charge ou produit)"><Select value={f.code} onChange={(e) => setF({ ...f, code: e.target.value })} required><option value="">— choisir —</option>{eligibles.map((o) => <option key={o.code} value={o.code}>{o.libelle}</option>)}</Select></Field>
      <Field label="Montant prévu (F)"><Input type="number" min={0} value={f.montant} onChange={(e) => setF({ ...f, montant: e.target.value })} required /></Field>
      <Field label="Mois"><Select value={f.mois} disabled={f.tousLesMois} onChange={(e) => setF({ ...f, mois: e.target.value })}>{MOIS.map((m, i) => <option key={m} value={i + 1}>{m}</option>)}</Select></Field>
      <label className="row" style={{ gap: 8, alignItems: 'center' }}><input type="checkbox" checked={f.tousLesMois} onChange={(e) => setF({ ...f, tousLesMois: e.target.checked })} /> Appliquer ce montant à chacun des 12 mois</label>
    </FormModal>
  )
}

function ListeTiers() {
  const { can, agenceId } = useSession()
  const [q, setQ] = useState('')
  const [qd, setQd] = useState('')
  const [type, setType] = useState('')
  const [actif, setActif] = useState('')
  const [modale, setModale] = useState<Tiers | 'nouveau' | null>(null)
  useEffect(() => { const t = setTimeout(() => setQd(q), 250); return () => clearTimeout(t) }, [q])
  const liste = useFetch(() => api.get<Tiers[]>('/api/tiers', { q: qd, type, actif }), [qd, type, actif, agenceId])
  return (
    <Card flush actions={can('charge:gerer') && <Button variant="primary" onClick={() => setModale('nouveau')}>Nouveau tiers</Button>}>
      <div className="card-b row">
        <Field label="Recherche"><Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Nom ou identifiant fiscal" /></Field>
        <Field label="Type"><Select value={type} onChange={(e) => setType(e.target.value)}><option value="">Tous</option>{Object.entries(TYPES_TIERS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
        <Field label="État"><Select value={actif} onChange={(e) => setActif(e.target.value)}><option value="">Tous</option><option value="true">Actifs</option><option value="false">Inactifs</option></Select></Field>
      </div>
      <Charge q={liste}>
        {(rows) => (
          <Table rows={rows} vide="Aucun tiers" onRowClick={(t) => { if (can('charge:gerer')) setModale(t) }} cols={[
            { titre: 'Nom', render: (t) => t.nom }, { titre: 'Type', render: (t) => TYPES_TIERS[t.type] ?? t.type }, { titre: 'Téléphone', render: (t) => t.telephone ?? '' },
            { titre: 'Identifiant fiscal', render: (t) => t.identifiant_fiscal ?? '' }, { titre: 'Portée', render: (t) => t.agence ?? 'Toutes les agences' },
            { titre: 'État', render: (t) => <Badge tone={t.actif ? 'ok' : 'neutre'}>{t.actif ? 'Actif' : 'Inactif'}</Badge> },
          ]} />
        )}
      </Charge>
      {modale && <EditionTiers t={modale === 'nouveau' ? null : modale} onClose={() => setModale(null)} onFait={() => { setModale(null); liste.reload() }} />}
    </Card>
  )
}

function EditionTiers({ t, onClose, onFait }: { t: Tiers | null; onClose: () => void; onFait: () => void }) {
  const { agenceId, user } = useSession()
  const { run, busy } = useAction()
  const [f, setF] = useState({ nom: t?.nom ?? '', type: t?.type ?? 'fournisseur', telephone: t?.telephone ?? '', adresse: t?.adresse ?? '', fiscal: t?.identifiant_fiscal ?? '', actif: t?.actif ?? true, commun: false })
  return (
    <FormModal titre={t ? `Modifier ${t.nom}` : 'Nouveau tiers'} onClose={onClose} busy={busy} valider="Enregistrer"
      onSubmit={() => void run(() => (t
        ? api.patch(`/api/tiers/${t.id}`, { nom: f.nom, telephone: f.telephone || null, adresse: f.adresse || null, identifiant_fiscal: f.fiscal || null, actif: f.actif })
        : api.post('/api/tiers', { nom: f.nom, type: f.type, telephone: f.telephone || null, adresse: f.adresse || null, identifiant_fiscal: f.fiscal || null, agence_id: f.commun ? null : agenceId })), 'Tiers enregistré', onFait)}>
      <Field label="Nom"><Input value={f.nom} onChange={(e) => setF({ ...f, nom: e.target.value })} required minLength={2} /></Field>
      {!t && <Field label="Type"><Select value={f.type} onChange={(e) => setF({ ...f, type: e.target.value })}>{Object.entries(TYPES_TIERS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>}
      <div className="row">
        <Field label="Téléphone"><Input value={f.telephone} onChange={(e) => setF({ ...f, telephone: e.target.value })} /></Field>
        <Field label="Identifiant fiscal"><Input value={f.fiscal} onChange={(e) => setF({ ...f, fiscal: e.target.value })} /></Field>
      </div>
      <Field label="Adresse"><Input value={f.adresse} onChange={(e) => setF({ ...f, adresse: e.target.value })} /></Field>
      {t && <Field label="État"><Select value={f.actif ? 'oui' : 'non'} onChange={(e) => setF({ ...f, actif: e.target.value === 'oui' })}><option value="oui">Actif</option><option value="non">Inactif</option></Select></Field>}
      {!t && user?.agence_id === null && <label className="row" style={{ gap: 8, alignItems: 'center' }}><input type="checkbox" checked={f.commun} onChange={(e) => setF({ ...f, commun: e.target.checked })} /> Tiers commun à toutes les agences</label>}
    </FormModal>
  )
}

function Recurrentes() {
  const { can, agenceId, user } = useSession()
  const [actif, setActif] = useState('true')
  const [nouveau, setNouveau] = useState(false)
  const { run, busy } = useAction()
  const liste = useFetch(() => api.get<Recurrente[]>('/api/operations-recurrentes', { actif }), [actif, agenceId])
  return (
    <Card flush actions={can('charge:gerer') && (
      <span className="row">
        {user?.agence_id === null && <Button disabled={busy} onClick={() => void run(async () => { const r = await api.post<{ operations_creees: number }>('/api/operations-recurrentes/generer', {}); window.alert(`${r.operations_creees} opération(s) créée(s)`) }, undefined, liste.reload)}>Générer les échéances dues</Button>}
        <Button variant="primary" onClick={() => setNouveau(true)}>Nouvelle opération récurrente</Button>
      </span>
    )}>
      <Alert tone="info">Les opérations récurrentes sont des opérations hors caisse (loyer facturé, abonnement…). Chaque échéance crée une opération normale, soumise au seuil de validation ; le rejeu ne crée jamais de doublon.</Alert>
      <div className="card-b row"><Field label="État"><Select value={actif} onChange={(e) => setActif(e.target.value)}><option value="">Toutes</option><option value="true">Actives</option><option value="false">Terminées ou suspendues</option></Select></Field></div>
      <Charge q={liste}>
        {(rows) => (
          <Table rows={rows} vide="Aucune opération récurrente" cols={[
            { titre: 'Opération', render: (r) => <><strong>{r.operation}</strong><div className="muted">{r.libelle ?? ''}</div></> }, { titre: 'Tiers', render: (r) => r.tiers ?? '' },
            { titre: 'Montant', num: true, render: (r) => xof(r.montant) }, { titre: 'Périodicité', render: (r) => `${PERIODES[r.periodicite]} (le ${r.jour_du_mois})` },
            { titre: 'Prochaine échéance', render: (r) => fdate(r.prochaine_date) }, { titre: 'Fin', render: (r) => (r.date_fin ? fdate(r.date_fin) : '—') },
            { titre: 'État', render: (r) => <Badge tone={r.actif ? 'ok' : 'neutre'}>{r.actif ? 'Active' : 'Arrêtée'}</Badge> },
            { titre: '', render: (r) => can('charge:gerer') && <Button small disabled={busy} onClick={() => void run(() => api.patch(`/api/operations-recurrentes/${r.id}`, { actif: !r.actif }), r.actif ? 'Suspendue' : 'Réactivée', liste.reload)}>{r.actif ? 'Suspendre' : 'Réactiver'}</Button> },
          ]} />
        )}
      </Charge>
      {nouveau && <NouvelleRecurrente onClose={() => setNouveau(false)} onFait={() => { setNouveau(false); liste.reload() }} />}
    </Card>
  )
}

function NouvelleRecurrente({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const { agenceId } = useSession()
  const catalogue = useFetch(() => api.get<OperationStandard[]>('/api/operations-standard', { famille: 'hors_caisse', actif: 'true' }), [])
  const tiers = useFetch(() => api.get<Tiers[]>('/api/tiers', { actif: 'true' }), [agenceId])
  const { run, busy } = useAction()
  const [f, setF] = useState({ code: '', montant: '', periodicite: 'mensuelle', jour: '1', debut: aujourdhui(), fin: '', tiers: '', libelle: '' })
  return (
    <FormModal titre="Nouvelle opération récurrente" onClose={onClose} busy={busy} valider="Enregistrer" large
      onSubmit={() => void run(() => api.post('/api/operations-recurrentes', {
        code_operation: f.code, montant: Number(f.montant), periodicite: f.periodicite, jour_du_mois: Number(f.jour), prochaine_date: f.debut, date_fin: f.fin || null,
        tiers_id: f.tiers ? Number(f.tiers) : null, libelle: f.libelle.trim() || null, agence_id: agenceId,
      }), 'Opération récurrente enregistrée', onFait)}>
      <Field label="Opération hors caisse"><Select value={f.code} onChange={(e) => setF({ ...f, code: e.target.value })} required><option value="">— choisir —</option>{catalogue.data?.map((o) => <option key={o.code} value={o.code}>{o.libelle}</option>)}</Select></Field>
      <div className="row">
        <Field label="Montant (F)"><Input type="number" min={1} value={f.montant} onChange={(e) => setF({ ...f, montant: e.target.value })} required /></Field>
        <Field label="Périodicité"><Select value={f.periodicite} onChange={(e) => setF({ ...f, periodicite: e.target.value })}>{Object.entries(PERIODES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
        <Field label="Jour du mois (1 à 28)"><Input type="number" min={1} max={28} value={f.jour} onChange={(e) => setF({ ...f, jour: e.target.value })} required /></Field>
      </div>
      <div className="row">
        <Field label="Première échéance"><Input type="date" value={f.debut} onChange={(e) => setF({ ...f, debut: e.target.value })} required /></Field>
        <Field label="Dernière échéance (facultatif)"><Input type="date" value={f.fin} min={f.debut} onChange={(e) => setF({ ...f, fin: e.target.value })} /></Field>
      </div>
      <Field label="Tiers"><Select value={f.tiers} onChange={(e) => setF({ ...f, tiers: e.target.value })}><option value="">—</option>{tiers.data?.map((t) => <option key={t.id} value={t.id}>{t.nom}</option>)}</Select></Field>
      <Field label="Libellé"><Input value={f.libelle} onChange={(e) => setF({ ...f, libelle: e.target.value })} placeholder="Loyer du bureau principal" /></Field>
    </FormModal>
  )
}
