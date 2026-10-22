import { useEffect, useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Modal, Page, Select, Table, Tabs, useAction, useFetch } from '../components/ui'

interface OperationStandard {
  code: string; libelle: string; famille: string; categorie: string; sens: string; compte_debit: string | null; compte_credit: string | null; journal_code: string
  justificatif_obligatoire: boolean; seuil_validation: number | null; comptes_valides: boolean; actif: boolean; nb_utilisations: number
}
interface OperationGenerale {
  id: number; code_operation: string; operation: string; famille: string; categorie: string; sens: string; date_operation: string; montant: number; tiers: string | null
  reference_justificatif: string | null; libelle: string | null; caisse: string | null; statut: string; saisi_par_nom: string | null; decide_par_nom: string | null; commentaire_decision: string | null
  seuil_validation: number | null
}
interface Caisse { id: number; code: string; type: string; agence_id: number }
interface Destination { id: number; code: string; type: string; agence: string; agence_id: number }
interface Transfert {
  id: number; reference: string; caisse_source: string; caisse_dest: string; montant: number; motif: string | null; statut: string; date_envoi: string; envoye_par_nom: string | null
  recu_par_nom: string | null; montant_recu: number | null; ecart: number | null; commentaire_reception: string | null; en_retard: boolean
}

const FAMILLES: Record<string, string> = { caisse: 'De caisse', hors_caisse: 'Hors caisse' }
const CATEGORIES: Record<string, string> = { charge: 'Charge', produit: 'Produit', immobilisation: 'Immobilisation', regularisation: 'Régularisation', autre: 'Autre' }
const STATUTS_OP: Record<string, { texte: string; tone: 'ok' | 'warn' | 'bad' | 'neutre' }> = { a_valider: { texte: 'À valider', tone: 'warn' }, valide: { texte: 'Validée', tone: 'ok' }, rejete: { texte: 'Rejetée', tone: 'bad' }, annule: { texte: 'Annulée', tone: 'neutre' } }
const STATUTS_TF: Record<string, { texte: string; tone: 'ok' | 'warn' | 'bad' }> = { envoye: { texte: 'En transit', tone: 'warn' }, recu: { texte: 'Reçu', tone: 'ok' }, refuse: { texte: 'Refusé', tone: 'bad' } }

/** Opérations standard (de caisse / hors caisse), saisie des opérations et transferts de fonds entre caisses. */
export default function OperationsCaisse() {
  const [onglet, setOnglet] = useState('operations')
  return (
    <Page title="Opérations et transferts" subtitle="Opérations standard de caisse et hors caisse, validation, transferts de fonds entre caisses">
      <Tabs actif={onglet} onChange={setOnglet} tabs={[{ id: 'operations', titre: 'Opérations' }, { id: 'catalogue', titre: 'Paramétrage des opérations' }, { id: 'transferts', titre: 'Transferts de fonds' }]} />
      {onglet === 'operations' && <Operations />}
      {onglet === 'catalogue' && <Catalogue />}
      {onglet === 'transferts' && <Transferts />}
    </Page>
  )
}

// ------------------------------------------------------------------ opérations saisies
function Operations() {
  const { can, agenceId } = useSession()
  const [famille, setFamille] = useState('')
  const [categorie, setCategorie] = useState('')
  const [statut, setStatut] = useState('')
  const [q, setQ] = useState('')
  const [qd, setQd] = useState('')
  const [du, setDu] = useState('')
  const [au, setAu] = useState('')
  const [saisie, setSaisie] = useState(false)
  const [ouvert, setOuvert] = useState<OperationGenerale | null>(null)
  useEffect(() => { const t = setTimeout(() => setQd(q), 250); return () => clearTimeout(t) }, [q])
  const liste = useFetch(() => api.get<OperationGenerale[]>('/api/operations-generales', { famille, categorie, statut, q: qd, du, au }), [famille, categorie, statut, qd, du, au, agenceId])
  return (
    <Card flush actions={can('operation:saisir') && <Button variant="primary" onClick={() => setSaisie(true)}>Nouvelle opération</Button>}>
      <div className="card-b row">
        <Field label="Recherche"><Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Opération, tiers, justificatif" /></Field>
        <Field label="Famille"><Select value={famille} onChange={(e) => setFamille(e.target.value)}><option value="">Toutes</option>{Object.entries(FAMILLES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
        <Field label="Catégorie"><Select value={categorie} onChange={(e) => setCategorie(e.target.value)}><option value="">Toutes</option>{Object.entries(CATEGORIES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
        <Field label="Statut"><Select value={statut} onChange={(e) => setStatut(e.target.value)}><option value="">Tous</option>{Object.entries(STATUTS_OP).map(([k, v]) => <option key={k} value={k}>{v.texte}</option>)}</Select></Field>
        <Field label="Du"><Input type="date" value={du} onChange={(e) => setDu(e.target.value)} /></Field>
        <Field label="Au"><Input type="date" value={au} onChange={(e) => setAu(e.target.value)} /></Field>
      </div>
      <Charge q={liste}>
        {(rows) => (
          <Table rows={rows} onRowClick={setOuvert} vide="Aucune opération" cols={[
            { titre: 'Date', render: (o) => fdate(o.date_operation) }, { titre: 'Opération', render: (o) => o.operation },
            { titre: 'Famille', render: (o) => <Badge tone={o.famille === 'caisse' ? 'info' : 'neutre'}>{FAMILLES[o.famille]}</Badge> },
            { titre: 'Caisse', render: (o) => o.caisse ?? '—' }, { titre: 'Tiers', render: (o) => o.tiers ?? '' }, { titre: 'Justificatif', render: (o) => o.reference_justificatif ?? '' },
            { titre: 'Montant', num: true, render: (o) => xof(o.montant) },
            { titre: 'Statut', render: (o) => <Badge tone={STATUTS_OP[o.statut]?.tone ?? 'neutre'}>{STATUTS_OP[o.statut]?.texte ?? o.statut}</Badge> },
            { titre: 'Saisie par', render: (o) => o.saisi_par_nom ?? '' },
          ]} />
        )}
      </Charge>
      {saisie && <SaisieOperation onClose={() => setSaisie(false)} onFait={() => { setSaisie(false); liste.reload() }} />}
      {ouvert && <DetailOperation o={ouvert} onClose={() => setOuvert(null)} onFait={() => { setOuvert(null); liste.reload() }} />}
    </Card>
  )
}

function SaisieOperation({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const { agenceId } = useSession()
  const catalogue = useFetch(() => api.get<OperationStandard[]>('/api/operations-standard', { actif: 'true' }), [])
  const caisses = useFetch(() => api.get<Caisse[]>('/api/caisses'), [agenceId])
  const tiersListe = useFetch(() => api.get<{ id: number; nom: string }[]>('/api/tiers', { actif: 'true' }), [agenceId])
  const { run, busy } = useAction()
  const [f, setF] = useState({ code: '', montant: '', tiers_id: '', tiers: '', reference: '', libelle: '', caisse_id: '', date: aujourdhui() })
  const [cle] = useState(() => `op-${crypto.randomUUID()}`)
  const op = catalogue.data?.find((o) => o.code === f.code)
  const montant = Number(f.montant)
  const auDessusDuSeuil = op !== undefined && op.seuil_validation !== null && montant >= op.seuil_validation
  return (
    <FormModal titre="Nouvelle opération" onClose={onClose} busy={busy} valider="Enregistrer" large
      onSubmit={() => void run(() => api.post('/api/operations-generales', {
        code_operation: f.code, montant, date_operation: f.date, tiers: f.tiers.trim() || null, tiers_id: f.tiers_id ? Number(f.tiers_id) : null, reference_justificatif: f.reference.trim() || null, libelle: f.libelle.trim() || null,
        caisse_id: op?.famille === 'caisse' ? Number(f.caisse_id) : null, agence_id: agenceId, cle,
      }), auDessusDuSeuil ? 'Opération enregistrée : elle attend la validation d’un second responsable' : 'Opération enregistrée', onFait)}>
      <Field label="Opération">
        <Select value={f.code} onChange={(e) => setF({ ...f, code: e.target.value })} required>
          <option value="">— choisir —</option>
          {(['caisse', 'hors_caisse'] as const).map((fam) => <optgroup key={fam} label={FAMILLES[fam]}>{catalogue.data?.filter((o) => o.famille === fam).map((o) => <option key={o.code} value={o.code}>{o.libelle}</option>)}</optgroup>)}
        </Select>
      </Field>
      {op && (
        <Alert tone="info">
          {FAMILLES[op.famille]} · {CATEGORIES[op.categorie]} · {op.famille === 'caisse' ? (op.sens === 'entree' ? 'encaissement' : 'décaissement') : 'aucun mouvement d’espèces'}
          {op.justificatif_obligatoire ? ' · justificatif obligatoire' : ''}{op.seuil_validation !== null ? ` · validation par un second responsable dès ${xof(op.seuil_validation)}` : ''}{!op.comptes_valides ? ' · comptes en attente de validation par le comptable' : ''}
        </Alert>
      )}
      {op?.famille === 'caisse' && (
        <Field label="Caisse" hint="Sa session du jour doit être ouverte">
          <Select value={f.caisse_id} onChange={(e) => setF({ ...f, caisse_id: e.target.value })} required><option value="">— choisir —</option>{caisses.data?.map((k) => <option key={k.id} value={k.id}>{k.code}</option>)}</Select>
        </Field>
      )}
      <div className="row">
        <Field label="Montant (F)"><Input type="number" min={1} value={f.montant} onChange={(e) => setF({ ...f, montant: e.target.value })} required /></Field>
        <Field label="Date"><Input type="date" value={f.date} max={aujourdhui()} onChange={(e) => setF({ ...f, date: e.target.value })} required /></Field>
      </div>
      <div className="row">
        <Field label="Tiers du registre"><Select value={f.tiers_id} onChange={(e) => setF({ ...f, tiers_id: e.target.value })}><option value="">—</option>{tiersListe.data?.map((t) => <option key={t.id} value={t.id}>{t.nom}</option>)}</Select></Field>
        <Field label="Ou tiers libre"><Input value={f.tiers} onChange={(e) => setF({ ...f, tiers: e.target.value })} /></Field>
      </div>
      <Field label="Référence du justificatif (facture, quittance…)"><Input value={f.reference} onChange={(e) => setF({ ...f, reference: e.target.value })} required={!!op?.justificatif_obligatoire} /></Field>
      <Field label="Libellé complémentaire"><Input value={f.libelle} onChange={(e) => setF({ ...f, libelle: e.target.value })} /></Field>
    </FormModal>
  )
}

function DetailOperation({ o, onClose, onFait }: { o: OperationGenerale; onClose: () => void; onFait: () => void }) {
  const { can } = useSession()
  const { run, busy } = useAction()
  const [commentaire, setCommentaire] = useState('')
  const caisses = useFetch(() => api.get<Caisse[]>('/api/caisses'), [])
  const [caisse, setCaisse] = useState('')
  const decider = (valide: boolean) => void run(() => api.post(`/api/operations-generales/${o.id}/decider`, { valide, commentaire: commentaire.trim() || null, caisse_id: caisse ? Number(caisse) : null }), valide ? 'Opération validée' : 'Opération rejetée', onFait)
  return (
    <Modal titre={o.operation} onClose={onClose} footer={<Button onClick={onClose}>Fermer</Button>}>
      <div className="stack">
        <p style={{ margin: 0 }}>{FAMILLES[o.famille]} · {CATEGORIES[o.categorie]} · {xof(o.montant)} le {fdate(o.date_operation)} <Badge tone={STATUTS_OP[o.statut]?.tone ?? 'neutre'}>{STATUTS_OP[o.statut]?.texte ?? o.statut}</Badge></p>
        {o.tiers && <p style={{ margin: 0 }}>Tiers : {o.tiers}</p>}
        {o.reference_justificatif && <p style={{ margin: 0 }}>Justificatif : {o.reference_justificatif}</p>}
        <p style={{ margin: 0 }} className="muted">Saisie par {o.saisi_par_nom ?? '—'}{o.decide_par_nom ? ` · décision de ${o.decide_par_nom}${o.commentaire_decision ? ` — ${o.commentaire_decision}` : ''}` : ''}</p>
        {o.statut === 'a_valider' && can('operation:valider') && (
          <div className="stack">
            <Alert tone="warn">Au-dessus du seuil ({xof(o.seuil_validation ?? 0)}) : le saisisseur ne peut pas valider sa propre opération.</Alert>
            {o.famille === 'caisse' && <Field label="Caisse (si la session d’origine est fermée)"><Select value={caisse} onChange={(e) => setCaisse(e.target.value)}><option value="">Session d’origine</option>{caisses.data?.map((k) => <option key={k.id} value={k.id}>{k.code}</option>)}</Select></Field>}
            <Field label="Commentaire (obligatoire pour un rejet)"><Input value={commentaire} onChange={(e) => setCommentaire(e.target.value)} /></Field>
            <div className="row"><Button variant="primary" disabled={busy} onClick={() => decider(true)}>Valider</Button><Button variant="danger" disabled={busy} onClick={() => decider(false)}>Rejeter</Button></div>
          </div>
        )}
      </div>
    </Modal>
  )
}

// ------------------------------------------------------------------ catalogue
function Catalogue() {
  const { can } = useSession()
  const [famille, setFamille] = useState('')
  const [categorie, setCategorie] = useState('')
  const [actif, setActif] = useState('')
  const [q, setQ] = useState('')
  const [qd, setQd] = useState('')
  const [edit, setEdit] = useState<OperationStandard | 'nouveau' | null>(null)
  const { run, busy } = useAction()
  useEffect(() => { const t = setTimeout(() => setQd(q), 250); return () => clearTimeout(t) }, [q])
  const liste = useFetch(() => api.get<OperationStandard[]>('/api/operations-standard', { famille, categorie, actif, q: qd }), [famille, categorie, actif, qd])
  return (
    <Card flush actions={can('operation:param') && <Button variant="primary" onClick={() => setEdit('nouveau')}>Nouvelle opération standard</Button>}>
      <Alert tone="info">Les opérations « de caisse » déplacent des espèces dans une session ouverte ; les opérations « hors caisse » n’en déplacent pas (virement, facture à payer, dotation). Les comptes alimentent les règles comptables ; le comptable doit les valider.</Alert>
      <div className="card-b row">
        <Field label="Recherche"><Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Code ou libellé" /></Field>
        <Field label="Famille"><Select value={famille} onChange={(e) => setFamille(e.target.value)}><option value="">Toutes</option>{Object.entries(FAMILLES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
        <Field label="Catégorie"><Select value={categorie} onChange={(e) => setCategorie(e.target.value)}><option value="">Toutes</option>{Object.entries(CATEGORIES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
        <Field label="État"><Select value={actif} onChange={(e) => setActif(e.target.value)}><option value="">Tous</option><option value="true">Actives</option><option value="false">Inactives</option></Select></Field>
      </div>
      <Charge q={liste}>
        {(rows) => (
          <Table rows={rows} vide="Aucune opération standard" cols={[
            { titre: 'Opération', render: (o) => <><strong>{o.libelle}</strong><div className="muted">{o.code}</div></> },
            { titre: 'Famille', render: (o) => <Badge tone={o.famille === 'caisse' ? 'info' : 'neutre'}>{FAMILLES[o.famille]}</Badge> }, { titre: 'Catégorie', render: (o) => CATEGORIES[o.categorie] },
            { titre: 'Sens', render: (o) => (o.sens === 'entree' ? 'Entrée' : 'Sortie') }, { titre: 'Débit / crédit', render: (o) => (o.compte_debit ? `${o.compte_debit} / ${o.compte_credit}` : '—') },
            { titre: 'Justificatif', render: (o) => (o.justificatif_obligatoire ? 'Obligatoire' : '') }, { titre: 'Validation dès', num: true, render: (o) => (o.seuil_validation === null ? '—' : xof(o.seuil_validation)) },
            { titre: 'Comptes', render: (o) => (o.compte_debit ? <Badge tone={o.comptes_valides ? 'ok' : 'warn'}>{o.comptes_valides ? 'Validés' : 'À valider'}</Badge> : <Badge tone="bad">Non paramétrés</Badge>) },
            { titre: 'Usages', num: true, render: (o) => o.nb_utilisations },
            { titre: '', render: (o) => (
              <span className="row">
                {can('operation:param') && <Button small onClick={() => setEdit(o)}>Modifier</Button>}
                {can('operation:comptes-valider') && o.compte_debit && !o.comptes_valides && <Button small variant="primary" disabled={busy} onClick={() => void run(() => api.post(`/api/operations-standard/${o.code}/valider-comptes`), 'Comptes validés', liste.reload)}>Valider les comptes</Button>}
              </span>
            ) },
          ]} />
        )}
      </Charge>
      {edit && <EditionOperation o={edit === 'nouveau' ? null : edit} onClose={() => setEdit(null)} onFait={() => { setEdit(null); liste.reload() }} />}
    </Card>
  )
}

function EditionOperation({ o, onClose, onFait }: { o: OperationStandard | null; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({
    code: o?.code ?? '', libelle: o?.libelle ?? '', famille: o?.famille ?? 'caisse', categorie: o?.categorie ?? 'charge', sens: o?.sens ?? 'sortie', debit: o?.compte_debit ?? '', credit: o?.compte_credit ?? '',
    journal: o?.journal_code ?? 'OD', justificatif: o?.justificatif_obligatoire ?? false, seuil: o?.seuil_validation == null ? '' : String(o.seuil_validation), actif: o?.actif ?? true,
  })
  const corps = { libelle: f.libelle, compte_debit: f.debit.trim() || null, compte_credit: f.credit.trim() || null, journal_code: f.journal, justificatif_obligatoire: f.justificatif }
  return (
    <FormModal titre={o ? `Modifier « ${o.libelle} »` : 'Nouvelle opération standard'} onClose={onClose} busy={busy} valider="Enregistrer" large
      onSubmit={() => void run(() => (o
        ? api.patch(`/api/operations-standard/${o.code}`, { ...corps, seuil_validation: f.seuil === '' ? null : Number(f.seuil), sans_seuil: f.seuil === '', actif: f.actif })
        : api.post('/api/operations-standard', { ...corps, code: f.code, famille: f.famille, categorie: f.categorie, sens: f.sens, seuil_validation: f.seuil === '' ? null : Number(f.seuil) })), 'Opération enregistrée', onFait)}>
      {!o && <Field label="Code" hint="minuscules, chiffres et _"><Input value={f.code} pattern="[a-z0-9_]{2,30}" onChange={(e) => setF({ ...f, code: e.target.value })} required /></Field>}
      <Field label="Libellé"><Input value={f.libelle} onChange={(e) => setF({ ...f, libelle: e.target.value })} required minLength={3} /></Field>
      {!o && (
        <div className="row">
          <Field label="Famille"><Select value={f.famille} onChange={(e) => setF({ ...f, famille: e.target.value })}>{Object.entries(FAMILLES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
          <Field label="Catégorie"><Select value={f.categorie} onChange={(e) => setF({ ...f, categorie: e.target.value })}>{Object.entries(CATEGORIES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
          <Field label="Sens"><Select value={f.sens} onChange={(e) => setF({ ...f, sens: e.target.value })}><option value="entree">Entrée</option><option value="sortie">Sortie</option></Select></Field>
        </div>
      )}
      <div className="row">
        <Field label="Compte débité" hint={f.famille === 'caisse' && f.sens === 'entree' ? 'Entrée de caisse : 1011' : undefined}><Input value={f.debit} onChange={(e) => setF({ ...f, debit: e.target.value })} /></Field>
        <Field label="Compte crédité" hint={f.famille === 'caisse' && f.sens === 'sortie' ? 'Sortie de caisse : 1011' : undefined}><Input value={f.credit} onChange={(e) => setF({ ...f, credit: e.target.value })} /></Field>
        <Field label="Journal"><Input value={f.journal} maxLength={6} onChange={(e) => setF({ ...f, journal: e.target.value.toUpperCase() })} /></Field>
      </div>
      <div className="row">
        <Field label="Validation par un second responsable dès (F)" hint="Vide : jamais"><Input type="number" min={0} value={f.seuil} onChange={(e) => setF({ ...f, seuil: e.target.value })} /></Field>
        <Field label="Justificatif"><Select value={f.justificatif ? 'oui' : 'non'} onChange={(e) => setF({ ...f, justificatif: e.target.value === 'oui' })}><option value="non">Facultatif</option><option value="oui">Obligatoire</option></Select></Field>
        {o && <Field label="État"><Select value={f.actif ? 'oui' : 'non'} onChange={(e) => setF({ ...f, actif: e.target.value === 'oui' })}><option value="oui">Active</option><option value="non">Inactive</option></Select></Field>}
      </div>
      {o && <Alert tone="warn">Modifier les comptes remet leur validation par le comptable à zéro.</Alert>}
    </FormModal>
  )
}

// ------------------------------------------------------------------ transferts de fonds
function Transferts() {
  const { can, agenceId } = useSession()
  const [statut, setStatut] = useState('')
  const [retard, setRetard] = useState('')
  const [envoi, setEnvoi] = useState(false)
  const [action, setAction] = useState<{ t: Transfert; mode: 'recevoir' | 'refuser' } | null>(null)
  const liste = useFetch(() => api.get<Transfert[]>('/api/transferts-fonds', { statut, en_retard: retard }), [statut, retard, agenceId])
  return (
    <Card flush actions={can('caisse:write') && <Button variant="primary" onClick={() => setEnvoi(true)}>Envoyer des fonds</Button>}>
      <Alert tone="info">Un envoi sort l’argent de la caisse d’origine (fonds en transit). La caisse destinataire le réceptionne — par un autre utilisateur — en constatant l’éventuel écart, ou le refuse : les fonds reviennent alors à l’origine.</Alert>
      <div className="card-b row">
        <Field label="Statut"><Select value={statut} onChange={(e) => setStatut(e.target.value)}><option value="">Tous</option>{Object.entries(STATUTS_TF).map(([k, v]) => <option key={k} value={k}>{v.texte}</option>)}</Select></Field>
        <Field label="Retard"><Select value={retard} onChange={(e) => setRetard(e.target.value)}><option value="">Tous</option><option value="true">En retard de réception</option></Select></Field>
      </div>
      <Charge q={liste}>
        {(rows) => (
          <Table rows={rows} vide="Aucun transfert" cols={[
            { titre: 'Référence', render: (t) => t.reference }, { titre: 'Envoi', render: (t) => fdate(t.date_envoi) },
            { titre: 'De → vers', render: (t) => `${t.caisse_source} → ${t.caisse_dest}` }, { titre: 'Montant', num: true, render: (t) => xof(t.montant) },
            { titre: 'Reçu', num: true, render: (t) => (t.montant_recu === null ? '—' : `${xof(t.montant_recu)}${t.ecart ? ` (écart ${xof(t.ecart)})` : ''}`) },
            { titre: 'Statut', render: (t) => <><Badge tone={STATUTS_TF[t.statut]?.tone ?? 'warn'}>{STATUTS_TF[t.statut]?.texte ?? t.statut}</Badge>{t.en_retard && <> <Badge tone="bad">En retard</Badge></>}</> },
            { titre: 'Par', render: (t) => `${t.envoye_par_nom ?? ''}${t.recu_par_nom ? ` → ${t.recu_par_nom}` : ''}` }, { titre: 'Motif', render: (t) => t.commentaire_reception ?? t.motif ?? '' },
            { titre: '', render: (t) => t.statut === 'envoye' && can('caisse:write') && (
              <span className="row"><Button small variant="primary" onClick={() => setAction({ t, mode: 'recevoir' })}>Réceptionner</Button><Button small variant="danger" onClick={() => setAction({ t, mode: 'refuser' })}>Refuser</Button></span>
            ) },
          ]} />
        )}
      </Charge>
      {envoi && <EnvoiFonds onClose={() => setEnvoi(false)} onFait={() => { setEnvoi(false); liste.reload() }} />}
      {action && <ActionTransfert {...action} onClose={() => setAction(null)} onFait={() => { setAction(null); liste.reload() }} />}
    </Card>
  )
}

function EnvoiFonds({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const { user, agenceId } = useSession()
  const caisses = useFetch(() => api.get<Caisse[]>('/api/caisses'), [agenceId])
  const destinations = useFetch(() => api.get<Destination[]>('/api/transferts-fonds/destinations'), [])
  const { run, busy } = useAction()
  const [f, setF] = useState({ source: '', dest: '', montant: '', motif: '' })
  return (
    <FormModal titre="Envoyer des fonds" onClose={onClose} busy={busy} valider="Envoyer"
      onSubmit={() => void run(() => api.post('/api/transferts-fonds', { caisse_source_id: Number(f.source), caisse_dest_id: Number(f.dest), montant: Number(f.montant), motif: f.motif.trim() || null }), 'Fonds envoyés : en attente de réception', onFait)}>
      <Field label="Caisse d’origine" hint="Sa session du jour doit être ouverte"><Select value={f.source} onChange={(e) => setF({ ...f, source: e.target.value })} required><option value="">— choisir —</option>{caisses.data?.map((k) => <option key={k.id} value={k.id}>{k.code}</option>)}</Select></Field>
      <Field label="Caisse destinataire"><Select value={f.dest} onChange={(e) => setF({ ...f, dest: e.target.value })} required><option value="">— choisir —</option>{destinations.data?.filter((d) => String(d.id) !== f.source).map((d) => <option key={d.id} value={d.id}>{d.agence} — {d.code}</option>)}</Select></Field>
      <Field label="Montant (F)"><Input type="number" min={1} value={f.montant} onChange={(e) => setF({ ...f, montant: e.target.value })} required /></Field>
      <Field label="Motif"><Input value={f.motif} onChange={(e) => setF({ ...f, motif: e.target.value })} placeholder="Approvisionnement, dépôt au coffre…" /></Field>
      <p className="muted" style={{ margin: 0 }}>Envoyé par {user?.nom}. Un autre utilisateur devra réceptionner.</p>
    </FormModal>
  )
}

function ActionTransfert({ t, mode, onClose, onFait }: { t: Transfert; mode: 'recevoir' | 'refuser'; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [montant, setMontant] = useState(String(t.montant))
  const [texte, setTexte] = useState('')
  const ecart = Number(montant) - t.montant
  return (
    <FormModal titre={mode === 'recevoir' ? `Réceptionner ${t.reference}` : `Refuser ${t.reference}`} onClose={onClose} busy={busy} valider={mode === 'recevoir' ? 'Confirmer la réception' : 'Refuser et renvoyer les fonds'}
      onSubmit={() => void run(() => (mode === 'recevoir'
        ? api.post(`/api/transferts-fonds/${t.id}/recevoir`, { montant_recu: Number(montant), commentaire: texte.trim() || null })
        : api.post(`/api/transferts-fonds/${t.id}/refuser`, { motif: texte.trim() })), mode === 'recevoir' ? 'Fonds réceptionnés' : 'Transfert refusé : fonds retournés', onFait)}>
      <p style={{ margin: 0 }}>{xof(t.montant)} envoyés de {t.caisse_source} vers {t.caisse_dest} par {t.envoye_par_nom}.</p>
      {mode === 'recevoir' && (
        <>
          <Field label="Montant réellement reçu (F)"><Input type="number" min={0} value={montant} onChange={(e) => setMontant(e.target.value)} required /></Field>
          {ecart !== 0 && <Alert tone="warn">Écart de {xof(ecart)} : une explication est obligatoire ; il est comptabilisé comme {ecart < 0 ? 'manquant' : 'excédent'} de caisse.</Alert>}
        </>
      )}
      <Field label={mode === 'recevoir' ? 'Commentaire' : 'Motif du refus (5 caractères minimum)'}><Input value={texte} onChange={(e) => setTexte(e.target.value)} required={mode === 'refuser' || ecart !== 0} minLength={mode === 'refuser' || ecart !== 0 ? 5 : 0} /></Field>
    </FormModal>
  )
}
