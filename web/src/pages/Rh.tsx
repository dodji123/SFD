import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Modal, Page, Select, Statut, Table, Tabs, useAction, useFetch } from '../components/ui'

interface Employe { id: number; matricule: string; nom: string; poste: string | null; date_embauche: string; statut: string; salaire_base: number | null }
interface Bulletin { id: number; periode: string; matricule: string; nom: string; salaire_base: number; commission_nette: number; brut: number; retenues: number; retenue_avance: number; charges_patronales: number; net_a_payer: number; statut: string }
interface BulletinDet extends Bulletin { lignes: { code: string; libelle: string; type: string; base: number | null; taux: number | null; montant: number }[] }
interface Commission { id: number; collectrice: string; periode_debut: string; periode_fin: string; production: number; taux: number; commission_brute: number; retenue_agent: number; commission_nette: number; statut: string }
interface Rubrique { id: number; code: string; libelle: string; type: string; mode: string; valeur: number; base: string; actif: boolean }
interface Collectrice { id: number; matricule: string; nom: string }

const TYPES_RUBRIQUE: Record<string, string> = { gain: 'Gain', retenue_salariale: 'Retenue salariale', charge_patronale: 'Charge patronale' }

export default function Rh() {
  const { agenceId } = useSession()
  const [onglet, setOnglet] = useState('employes')
  return (
    <Page title="RH et paie" subtitle="Employés, contrats, bulletins de paie et commissions de collectrices">
      <Tabs actif={onglet} onChange={setOnglet} tabs={[{ id: 'employes', titre: 'Employés' }, { id: 'bulletins', titre: 'Bulletins' }, { id: 'commissions', titre: 'Commissions' }, { id: 'rubriques', titre: 'Rubriques de paie' }]} />
      {onglet === 'employes' && <Employes key={agenceId} />}
      {onglet === 'bulletins' && <Bulletins key={agenceId} />}
      {onglet === 'commissions' && <Commissions key={agenceId} />}
      {onglet === 'rubriques' && <Rubriques key={agenceId} />}
    </Page>
  )
}

function Employes() {
  const { can } = useSession()
  const q = useFetch(() => api.get<Employe[]>('/api/employes'), [])
  const [modale, setModale] = useState<null | 'nouveau' | { type: 'contrat' | 'avance'; e: Employe }>(null)
  const fin = () => { setModale(null); q.reload() }
  return (
    <Card flush actions={can('rh:write') && <Button variant="primary" onClick={() => setModale('nouveau')}>Nouvel employé</Button>}>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucun employé" cols={[
            { titre: 'Matricule', render: (e) => e.matricule },
            { titre: 'Nom', render: (e) => <strong>{e.nom}</strong> },
            { titre: 'Poste', render: (e) => e.poste ?? '—' },
            { titre: 'Embauche', render: (e) => fdate(e.date_embauche) },
            { titre: 'Salaire de base', num: true, render: (e) => (e.salaire_base === null ? <Badge tone="warn">Sans contrat</Badge> : xof(e.salaire_base)) },
            { titre: '', render: (e) => can('rh:write') && (
              <span className="actions"><Button small onClick={() => setModale({ type: 'contrat', e })}>Contrat</Button><Button small onClick={() => setModale({ type: 'avance', e })}>Avance</Button></span>
            ) },
          ]} />
        )}
      </Charge>
      {modale === 'nouveau' && <NouvelEmploye onClose={() => setModale(null)} onFait={fin} />}
      {modale && typeof modale === 'object' && modale.type === 'contrat' && <Contrat e={modale.e} onClose={() => setModale(null)} onFait={fin} />}
      {modale && typeof modale === 'object' && modale.type === 'avance' && <Avance e={modale.e} onClose={() => setModale(null)} onFait={fin} />}
    </Card>
  )
}

function NouvelEmploye({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const colls = useFetch(() => api.get<Collectrice[]>('/api/collectrices'), [])
  const [f, setF] = useState({ matricule: '', nom: '', poste: '', date_embauche: aujourdhui(), collectrice_id: '' })
  const maj = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  return (
    <FormModal titre="Nouvel employé" onClose={onClose} busy={busy} valider="Créer"
      onSubmit={() => void run(() => api.post('/api/employes', { ...f, poste: f.poste || null, collectrice_id: f.collectrice_id ? Number(f.collectrice_id) : null }), 'Employé créé', onFait)}>
      <Field label="Matricule"><Input value={f.matricule} onChange={maj('matricule')} maxLength={20} required autoFocus /></Field>
      <Field label="Nom"><Input value={f.nom} onChange={maj('nom')} required /></Field>
      <Field label="Poste"><Input value={f.poste} onChange={maj('poste')} /></Field>
      <Field label="Date d'embauche"><Input type="date" value={f.date_embauche} onChange={maj('date_embauche')} required /></Field>
      <Field label="Collectrice liée" hint="Sa commission entre dans son bulletin">
        <Select value={f.collectrice_id} onChange={maj('collectrice_id')}><option value="">— aucune —</option>{(colls.data ?? []).map((c) => <option key={c.id} value={c.id}>{c.matricule} — {c.nom}</option>)}</Select>
      </Field>
    </FormModal>
  )
}

function Contrat({ e, onClose, onFait }: { e: Employe; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ type: 'cdi', debut: aujourdhui(), fin: '', salaire: '' })
  return (
    <FormModal titre={`Contrat — ${e.nom}`} onClose={onClose} busy={busy} valider="Enregistrer"
      onSubmit={() => void run(() => api.post(`/api/employes/${e.id}/contrats`, { type: f.type, date_debut: f.debut, date_fin: f.fin || null, salaire_base: Number(f.salaire) }), 'Contrat enregistré', onFait)}>
      <Field label="Type"><Select value={f.type} onChange={(ev) => setF({ ...f, type: ev.target.value })}><option value="cdi">CDI</option><option value="cdd">CDD</option><option value="stage">Stage</option><option value="journalier">Journalier</option></Select></Field>
      <Field label="Salaire de base (F)"><Input type="number" min={0} value={f.salaire} onChange={(ev) => setF({ ...f, salaire: ev.target.value })} required autoFocus /></Field>
      <Field label="Début"><Input type="date" value={f.debut} onChange={(ev) => setF({ ...f, debut: ev.target.value })} required /></Field>
      <Field label="Fin" hint="Vide : durée indéterminée"><Input type="date" value={f.fin} onChange={(ev) => setF({ ...f, fin: ev.target.value })} /></Field>
    </FormModal>
  )
}

function Avance({ e, onClose, onFait }: { e: Employe; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ montant: '', date: aujourdhui() })
  return (
    <FormModal titre={`Avance sur salaire — ${e.nom}`} onClose={onClose} busy={busy} valider="Enregistrer"
      onSubmit={() => void run(() => api.post(`/api/employes/${e.id}/avances`, { montant: Number(f.montant), date_avance: f.date }), 'Avance enregistrée', onFait)}>
      <Field label="Montant (F)" hint="Retenue sur les prochains bulletins"><Input type="number" min={1} value={f.montant} onChange={(ev) => setF({ ...f, montant: ev.target.value })} required autoFocus /></Field>
      <Field label="Date"><Input type="date" value={f.date} onChange={(ev) => setF({ ...f, date: ev.target.value })} required /></Field>
    </FormModal>
  )
}

function Bulletins() {
  const { can } = useSession()
  const [mois, setMois] = useState(aujourdhui().slice(0, 7))
  const q = useFetch(() => api.get<Bulletin[]>('/api/bulletins', { periode: `${mois}-01` }), [mois])
  const { run, busy } = useAction()
  const [ouvert, setOuvert] = useState<number | null>(null)
  return (
    <div className="stack">
      <Card><div className="row">
        <Field label="Mois"><Input type="month" value={mois} onChange={(e) => setMois(e.target.value || aujourdhui().slice(0, 7))} /></Field>
        {can('rh:write') && <Button variant="primary" disabled={busy} onClick={() => void run(async () => {
          const r = await api.post<{ bulletins_generes: number }>('/api/bulletins/generer-agence', { periode: `${mois}-01` })
          if (r.bulletins_generes === 0) throw new Error('Aucun bulletin à générer (déjà générés, ou employés sans contrat)')
        }, 'Bulletins générés', q.reload)}>Générer les bulletins du mois</Button>}
      </div></Card>
      <Card flush>
        <Charge q={q}>
          {(rows) => (
            <Table rows={rows} onRowClick={(b) => setOuvert(b.id)} vide="Aucun bulletin pour ce mois" cols={[
              { titre: 'Employé', render: (b) => <><strong>{b.nom}</strong><div className="muted">{b.matricule}</div></> },
              { titre: 'Brut', num: true, render: (b) => xof(b.brut) },
              { titre: 'Retenues', num: true, render: (b) => xof(b.retenues + b.retenue_avance) },
              { titre: 'Net à payer', num: true, render: (b) => <strong>{xof(b.net_a_payer)}</strong> },
              { titre: 'Statut', render: (b) => <Statut s={b.statut} /> },
            ]} />
          )}
        </Charge>
      </Card>
      {ouvert !== null && <DetailBulletin id={ouvert} onClose={() => setOuvert(null)} onFait={() => { q.reload() }} />}
    </div>
  )
}

function DetailBulletin({ id, onClose, onFait }: { id: number; onClose: () => void; onFait: () => void }) {
  const { can } = useSession()
  const q = useFetch(() => api.get<BulletinDet>(`/api/bulletins/${id}`), [id])
  const { run, busy } = useAction()
  return (
    <Modal titre="Bulletin de paie" onClose={onClose} large>
      <Charge q={q}>
        {(b) => (
          <div className="stack">
            <p style={{ margin: 0 }}><strong>{b.nom}</strong> ({b.matricule}) · période {fdate(b.periode)} · <Statut s={b.statut} /></p>
            <Table rows={b.lignes} cols={[
              { titre: 'Rubrique', render: (l) => l.libelle },
              { titre: 'Type', render: (l) => TYPES_RUBRIQUE[l.type] ?? l.type },
              { titre: 'Base', num: true, render: (l) => (l.base !== null ? xof(l.base) : '') },
              { titre: 'Taux', num: true, render: (l) => (l.taux !== null ? `${Math.round(l.taux * 10000) / 100} %` : '') },
              { titre: 'Montant', num: true, render: (l) => xof(l.montant) },
            ]} />
            <div className="grid-kpi">
              <div className="card kpi"><div className="v">{xof(b.brut)}</div><div className="l">Brut</div></div>
              <div className="card kpi"><div className="v">{xof(b.retenues + b.retenue_avance)}</div><div className="l">Retenues (avance : {xof(b.retenue_avance)})</div></div>
              <div className="card kpi"><div className="v">{xof(b.net_a_payer)}</div><div className="l">Net à payer</div></div>
              <div className="card kpi"><div className="v">{xof(b.charges_patronales)}</div><div className="l">Charges patronales</div></div>
            </div>
            {b.statut === 'brouillon' && can('rh:write') && <div className="actions"><Button variant="primary" disabled={busy} onClick={() => void run(() => api.post(`/api/bulletins/${id}/valider`), 'Bulletin validé', () => { q.reload(); onFait() })}>Valider le bulletin</Button></div>}
          </div>
        )}
      </Charge>
    </Modal>
  )
}

function Commissions() {
  const { can } = useSession()
  const q = useFetch(() => api.get<Commission[]>('/api/commissions'), [])
  const [calc, setCalc] = useState(false)
  return (
    <Card flush actions={can('rh:write') && <Button variant="primary" onClick={() => setCalc(true)}>Calculer une commission</Button>}>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucune commission calculée" cols={[
            { titre: 'Collectrice', render: (c) => <strong>{c.collectrice}</strong> },
            { titre: 'Période', render: (c) => `${fdate(c.periode_debut)} → ${fdate(c.periode_fin)}` },
            { titre: 'Production', num: true, render: (c) => xof(c.production) },
            { titre: 'Taux', num: true, render: (c) => `${Math.round(c.taux * 10000) / 100} %` },
            { titre: 'Brute', num: true, render: (c) => xof(c.commission_brute) },
            { titre: 'Retenue agent', num: true, render: (c) => xof(c.retenue_agent) },
            { titre: 'Nette', num: true, render: (c) => <strong>{xof(c.commission_nette)}</strong> },
            { titre: 'Statut', render: (c) => <Statut s={c.statut} /> },
          ]} />
        )}
      </Charge>
      {calc && <CalculCommission onClose={() => setCalc(false)} onFait={() => { setCalc(false); q.reload() }} />}
    </Card>
  )
}

function CalculCommission({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const colls = useFetch(() => api.get<Collectrice[]>('/api/collectrices'), [])
  const { run, busy } = useAction()
  const debut = aujourdhui().slice(0, 8) + '01'
  const [f, setF] = useState({ c: '', du: debut, au: aujourdhui() })
  return (
    <FormModal titre="Calculer la commission d'une collectrice" onClose={onClose} busy={busy} valider="Calculer"
      onSubmit={() => void run(() => api.post('/api/commissions/calculer', { collectrice_id: Number(f.c), du: f.du, au: f.au }), 'Commission calculée', onFait)}>
      <Field label="Collectrice"><Select value={f.c} onChange={(e) => setF({ ...f, c: e.target.value })} required><option value="">— choisir —</option>{(colls.data ?? []).map((c) => <option key={c.id} value={c.id}>{c.matricule} — {c.nom}</option>)}</Select></Field>
      <Field label="Du"><Input type="date" value={f.du} onChange={(e) => setF({ ...f, du: e.target.value })} required /></Field>
      <Field label="Au"><Input type="date" value={f.au} onChange={(e) => setF({ ...f, au: e.target.value })} required /></Field>
      <p className="muted" style={{ gridColumn: '1 / -1', margin: 0 }}>Production × taux de commission, nette de la retenue sur le compte de l'agent (plafonnée).</p>
    </FormModal>
  )
}

function Rubriques() {
  const { can } = useSession()
  const q = useFetch(() => api.get<Rubrique[]>('/api/rubriques-paie'), [])
  const [nouveau, setNouveau] = useState(false)
  return (
    <div className="stack">
      <Alert tone="info">Les taux de cotisations sociales et d'impôt sur salaire ne sont pas préchargés : à saisir ici selon la réglementation en vigueur.</Alert>
      <Card flush actions={can('rh:write') && <Button variant="primary" onClick={() => setNouveau(true)}>Nouvelle rubrique</Button>}>
        <Charge q={q}>
          {(rows) => (
            <Table rows={rows} vide="Aucune rubrique" cols={[
              { titre: 'Code', render: (r) => r.code },
              { titre: 'Libellé', render: (r) => r.libelle },
              { titre: 'Type', render: (r) => TYPES_RUBRIQUE[r.type] ?? r.type },
              { titre: 'Valeur', num: true, render: (r) => (r.mode === 'fixe' ? xof(r.valeur) : `${Math.round(r.valeur * 10000) / 100} % du ${r.base === 'brut' ? 'brut' : 'salaire de base'}`) },
            ]} />
          )}
        </Charge>
        {nouveau && <NouvelleRubrique onClose={() => setNouveau(false)} onFait={() => { setNouveau(false); q.reload() }} />}
      </Card>
    </div>
  )
}

function NouvelleRubrique({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ code: '', libelle: '', type: 'retenue_salariale', mode: 'pourcentage', valeur: '', base: 'brut' })
  const maj = (k: keyof typeof f) => (e: { target: { value: string } }) => setF({ ...f, [k]: e.target.value })
  return (
    <FormModal titre="Nouvelle rubrique de paie" onClose={onClose} busy={busy} valider="Créer"
      onSubmit={() => void run(() => api.post('/api/rubriques-paie', { ...f, valeur: f.mode === 'pourcentage' ? Number(f.valeur) / 100 : Number(f.valeur) }), 'Rubrique créée', onFait)}>
      <Field label="Code"><Input value={f.code} onChange={maj('code')} maxLength={20} required autoFocus /></Field>
      <Field label="Libellé"><Input value={f.libelle} onChange={maj('libelle')} required /></Field>
      <Field label="Type"><Select value={f.type} onChange={maj('type')}>{Object.entries(TYPES_RUBRIQUE).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
      <Field label="Mode"><Select value={f.mode} onChange={maj('mode')}><option value="pourcentage">Pourcentage</option><option value="fixe">Montant fixe</option></Select></Field>
      <Field label={f.mode === 'pourcentage' ? 'Taux (%)' : 'Montant (F)'}><Input type="number" step="0.01" min={0} value={f.valeur} onChange={maj('valeur')} required /></Field>
      {f.mode === 'pourcentage' && <Field label="Base de calcul"><Select value={f.base} onChange={maj('base')}><option value="brut">Salaire brut</option><option value="salaire_base">Salaire de base</option></Select></Field>}
    </FormModal>
  )
}
