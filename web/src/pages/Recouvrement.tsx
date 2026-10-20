import { useState } from 'react'
import { api } from '../lib/api'
import { date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Modal, Money, Page, Select, Table, Tabs, useAction, useFetch } from '../components/ui'

interface Dossier {
  id: number; credit: string; client: string; statut: string; ouvert_le: string; agent: string | null
  montant_du_ouverture: number; capital_restant: number | null; jours_retard: number; montant_accorde: number
  actions?: Action[]; radiation?: { capital_restant: number; motif: string; date_radiation: string } | null
}
interface Action { id: number; date_action: string; type: string; resultat: string | null; montant_promis: number | null; date_promesse: string | null; valeur_estimee: number | null; utilisateur: string | null }
interface EnRetard { id: number; numero: string; client: string; capital_restant: number; jours_retard: number }
interface Doc {
  institution: { raison_sociale: string; sigle: string | null; adresse: string | null; ville: string | null; telephone: string | null; pied_de_page: string | null }
  agence: { libelle: string } | null
  credit: Record<string, any>
  echeances?: { no_echeance: number; date_prevue: string; capital: number; interet: number }[]
  garantie_compte?: { montant_bloque: number; compte: string } | null
  garants?: { nom: string; montant_caution: number }[]
  comite?: { seance: string; motif: string; conditions: string | null; montant_accorde: number } | null
  totaux?: { capital: number; interets: number; penalites: number }
}

const STATUT: Record<string, { texte: string; tone: 'ok' | 'warn' | 'bad' | 'info' | 'neutre' }> = {
  amiable: { texte: 'À l\'amiable', tone: 'info' }, mise_en_demeure: { texte: 'Mise en demeure', tone: 'warn' }, garanties: { texte: 'Garanties', tone: 'warn' },
  regle: { texte: 'Réglé', tone: 'ok' }, perte: { texte: 'Passé en perte', tone: 'bad' },
}
const ACTIONS: Record<string, string> = {
  relance: 'Relance', appel: 'Appel', visite: 'Visite du client', accord_amiable: 'Accord amiable', mise_en_demeure: 'Mise en demeure',
  mise_en_demeure_aval: 'Mise en demeure des avals', saisie_salaire: 'Saisie sur salaire', vente_garantie: 'Vente de garantie',
}

export default function Recouvrement() {
  const [vue, setVue] = useState('dossiers')
  const [dossier, setDossier] = useState<number | null>(null)
  if (dossier !== null) return <Page title="Dossier de recouvrement"><DossierVue id={dossier} retour={() => setDossier(null)} /></Page>
  return (
    <Page title="Recouvrement" subtitle="Amiable, mise en demeure, garanties, passage en perte, rééchelonnement, documents de crédit">
      <Tabs actif={vue} onChange={setVue} tabs={[{ id: 'dossiers', titre: 'Dossiers' }, { id: 'retard', titre: 'Crédits en retard' }, { id: 'documents', titre: 'Contrat et certificat' }]} />
      {vue === 'dossiers' && <Dossiers ouvrir={setDossier} />}
      {vue === 'retard' && <EnRetardListe ouvrir={setDossier} />}
      {vue === 'documents' && <Documents />}
    </Page>
  )
}

function Dossiers({ ouvrir }: { ouvrir: (id: number) => void }) {
  const [statut, setStatut] = useState('')
  const q = useFetch(() => api.get<Dossier[]>('/api/recouvrement/dossiers', { statut }), [statut])
  return (
    <Card flush actions={<Select value={statut} onChange={(e) => setStatut(e.target.value)} aria-label="Statut"><option value="">Tous</option>{Object.entries(STATUT).map(([k, v]) => <option key={k} value={k}>{v.texte}</option>)}</Select>}>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucun dossier" onRowClick={(d) => ouvrir(d.id)} cols={[
            { titre: 'Crédit', render: (d) => <strong>{d.credit}</strong> },
            { titre: 'Client', render: (d) => d.client },
            { titre: 'Statut', render: (d) => <Badge tone={STATUT[d.statut]?.tone}>{STATUT[d.statut]?.texte}</Badge> },
            { titre: 'Retard', render: (d) => `${d.jours_retard} j` },
            { titre: 'Capital restant', render: (d) => <Money v={d.capital_restant} /> },
            { titre: 'Agent', render: (d) => d.agent ?? '—' },
            { titre: 'Ouvert le', render: (d) => fdate(d.ouvert_le) },
          ]} />
        )}
      </Charge>
    </Card>
  )
}

function EnRetardListe({ ouvrir }: { ouvrir: (id: number) => void }) {
  const { can } = useSession()
  const q = useFetch(() => api.get<EnRetard[]>('/api/recouvrement/credits-en-retard'), [])
  const { run, busy } = useAction()
  const [reech, setReech] = useState<EnRetard | null>(null)
  const [nb, setNb] = useState('6')
  return (
    <Card flush>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucun crédit en retard sans dossier" cols={[
            { titre: 'Crédit', render: (c) => <strong>{c.numero}</strong> },
            { titre: 'Client', render: (c) => c.client },
            { titre: 'Retard', render: (c) => `${c.jours_retard} j` },
            { titre: 'Capital restant', render: (c) => <Money v={c.capital_restant} /> },
            { titre: '', render: (c) => (
              <span className="actions">
                {can('recouvrement:write') && <Button small variant="primary" disabled={busy} onClick={() => void run(async () => { const d = await api.post<{ id: number }>('/api/recouvrement/dossiers', { credit_id: c.id }); ouvrir(d.id) }, 'Dossier ouvert')}>Ouvrir un dossier</Button>}
                {can('credit:request') && <Button small onClick={() => setReech(c)}>Rééchelonner</Button>}
              </span>
            ) },
          ]} />
        )}
      </Charge>
      {reech && (
        <FormModal titre={`Rééchelonner ${reech.numero}`} onClose={() => setReech(null)} busy={busy} valider="Créer la demande"
          onSubmit={() => void run(() => api.post(`/api/recouvrement/credits/${reech.id}/reechelonner`, { nb_echeances: Number(nb) }), 'Demande de rééchelonnement créée : à faire décider par le comité', () => { setReech(null); q.reload() })}>
          <Alert tone="info">Le rééchelonnement est un nouveau dossier de crédit pour le capital restant ({xof(reech.capital_restant)}), décidé par le comité. Le crédit d'origine reste inchangé jusqu'à son règlement.</Alert>
          <Field label="Nombre d'échéances"><Input type="number" min={1} max={240} value={nb} onChange={(e) => setNb(e.target.value)} required /></Field>
        </FormModal>
      )}
    </Card>
  )
}

function DossierVue({ id, retour }: { id: number; retour: () => void }) {
  const { can } = useSession()
  const q = useFetch(() => api.get<Dossier>(`/api/recouvrement/dossiers/${id}`), [id])
  const { run, busy } = useAction()
  const [action, setAction] = useState(false)
  const [perte, setPerte] = useState(false)
  const [f, setF] = useState({ type: 'relance', resultat: '', montant: '', promesse: '', valeur: '' })
  const [motif, setMotif] = useState('')
  return (
    <Charge q={q}>
      {(d) => {
        const ouvert = d.statut !== 'regle' && d.statut !== 'perte'
        return (
          <div className="stack">
            <div className="row" style={{ gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
              <Button small onClick={retour}>← Dossiers</Button><strong>{d.credit}</strong> {d.client}
              <Badge tone={STATUT[d.statut]?.tone}>{STATUT[d.statut]?.texte}</Badge>
              <span className="muted">{d.jours_retard} jours de retard · capital restant {xof(d.capital_restant)}</span>
              <span className="spacer" />
              {ouvert && can('recouvrement:write') && <Button small variant="primary" onClick={() => setAction(true)}>Ajouter une action</Button>}
              {ouvert && can('recouvrement:write') && <Button small disabled={busy} onClick={() => void run(() => api.post(`/api/recouvrement/dossiers/${id}/cloturer`), 'Dossier clos : crédit soldé', q.reload)}>Clore (crédit soldé)</Button>}
              {d.statut !== 'amiable' && ouvert && can('recouvrement:perte') && <Button small variant="danger" onClick={() => setPerte(true)}>Passer en perte</Button>}
            </div>
            {d.radiation && <Alert tone="warn">Passé en perte le {fdate(d.radiation.date_radiation)} — capital radié {xof(d.radiation.capital_restant)} : {d.radiation.motif}. Le passage en charges comptable reste à faire manuellement.</Alert>}
            <Card title="Actions menées" flush>
              <Table rows={d.actions ?? []} vide="Aucune action" cols={[
                { titre: 'Date', render: (a) => fdate(a.date_action) },
                { titre: 'Action', render: (a) => ACTIONS[a.type] ?? a.type },
                { titre: 'Résultat', render: (a) => a.resultat ?? '' },
                { titre: 'Promesse', render: (a) => (a.montant_promis ? `${xof(a.montant_promis)} le ${fdate(a.date_promesse)}` : '') },
                { titre: 'Valeur estimée', render: (a) => (a.valeur_estimee ? xof(a.valeur_estimee) : '') },
                { titre: 'Par', render: (a) => a.utilisateur ?? '' },
              ]} />
            </Card>
            {action && (
              <FormModal titre="Nouvelle action" onClose={() => setAction(false)} busy={busy}
                onSubmit={() => void run(() => api.post(`/api/recouvrement/dossiers/${id}/actions`, {
                  type: f.type, resultat: f.resultat || null, montant_promis: f.montant ? Number(f.montant) : null, date_promesse: f.promesse || null, valeur_estimee: f.valeur ? Number(f.valeur) : null,
                }), 'Action enregistrée', () => { setAction(false); q.reload() })}>
                <Alert tone="info">Ordre à respecter : relances / visites à l'amiable, puis mise en demeure, puis avals et réalisation des garanties.</Alert>
                <Field label="Type"><Select value={f.type} onChange={(e) => setF({ ...f, type: e.target.value })}>{Object.entries(ACTIONS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
                <Field label="Résultat"><Input value={f.resultat} onChange={(e) => setF({ ...f, resultat: e.target.value })} /></Field>
                {f.type === 'accord_amiable' && <><Field label="Montant promis"><Input type="number" min={1} value={f.montant} onChange={(e) => setF({ ...f, montant: e.target.value })} required /></Field><Field label="Date promise"><Input type="date" value={f.promesse} onChange={(e) => setF({ ...f, promesse: e.target.value })} required /></Field></>}
                {f.type === 'vente_garantie' && <Field label="Valeur estimée" hint="Évaluation de la valeur réelle avant vente"><Input type="number" min={1} value={f.valeur} onChange={(e) => setF({ ...f, valeur: e.target.value })} required /></Field>}
              </FormModal>
            )}
            {perte && (
              <FormModal titre="Passage en perte" onClose={() => setPerte(false)} busy={busy} valider="Passer en perte"
                onSubmit={() => void run(() => api.post(`/api/recouvrement/dossiers/${id}/perte`, { motif }), 'Passage en perte enregistré', () => { setPerte(false); q.reload() })}>
                <Alert tone="warn">Exige : mise en demeure faite, visite du client, retard minimal paramétré, et un approbateur autre que l'agent de recouvrement.</Alert>
                <Field label="Motif" hint="10 caractères au moins"><Input value={motif} onChange={(e) => setMotif(e.target.value)} minLength={10} required autoFocus /></Field>
              </FormModal>
            )}
          </div>
        )
      }}
    </Charge>
  )
}

function Documents() {
  const [numero, setNumero] = useState('')
  const [doc, setDoc] = useState<{ type: 'contrat' | 'certificat'; data: Doc } | null>(null)
  const { run, busy } = useAction()
  const credits = useFetch(() => api.get<{ id: number; numero: string; client: string }[]>('/api/credits'), [])
  const charger = (type: 'contrat' | 'certificat') => {
    const c = credits.data?.find((x) => x.numero === numero)
    if (!c) return
    void run(async () => setDoc({ type, data: await api.get<Doc>(`/api/documents-credit/${c.id}/${type === 'contrat' ? 'contrat' : 'certificat-cloture'}`) }))
  }
  return (
    <Card>
      <div className="row" style={{ gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
        <Select value={numero} onChange={(e) => setNumero(e.target.value)} aria-label="Crédit"><option value="">— crédit —</option>{credits.data?.map((c) => <option key={c.id} value={c.numero}>{c.numero} · {c.client}</option>)}</Select>
        <Button variant="primary" disabled={busy || !numero} onClick={() => charger('contrat')}>Contrat de crédit</Button>
        <Button disabled={busy || !numero} onClick={() => charger('certificat')}>Certificat de clôture</Button>
      </div>
      {doc && (
        <Modal titre={doc.type === 'contrat' ? 'Contrat de crédit' : 'Certificat de clôture'} onClose={() => setDoc(null)} large footer={<><Button onClick={() => setDoc(null)}>Fermer</Button><Button variant="primary" onClick={() => window.print()}>Imprimer</Button></>}>
          <DocumentCredit d={doc.data} type={doc.type} />
        </Modal>
      )}
    </Card>
  )
}

function DocumentCredit({ d, type }: { d: Doc; type: 'contrat' | 'certificat' }) {
  const i = d.institution
  const c = d.credit
  return (
    <div className="piece-doc" style={{ padding: 16, border: '1px solid var(--line, #d1d5db)', borderRadius: 8, background: '#fff', color: '#111' }}>
      <div style={{ borderBottom: '2px solid #111', paddingBottom: 8 }}>
        <div style={{ fontSize: 18, fontWeight: 700 }}>{i.raison_sociale}{i.sigle ? ` (${i.sigle})` : ''}</div>
        <div style={{ fontSize: 12 }}>{[i.adresse, i.ville].filter(Boolean).join(', ')}{i.telephone ? ` — Tél. ${i.telephone}` : ''}{d.agence ? ` — Agence ${d.agence.libelle}` : ''}</div>
      </div>
      <h2 style={{ textAlign: 'center' }}>{type === 'contrat' ? `CONTRAT DE CRÉDIT N° ${c.numero}` : `CERTIFICAT DE CLÔTURE — CRÉDIT N° ${c.numero}`}</h2>
      {type === 'contrat' ? (
        <>
          <p>Entre {i.raison_sociale} et <strong>{c.client}</strong> (n° {c.client_numero}), il est convenu un crédit de <strong>{xof(c.montant_accorde)}</strong> au taux annuel de {(Number(c.taux) * 100).toFixed(2)} %, débloqué le {fdate(c.date_deblocage)}, remboursable en {c.nb_echeances} échéances ({c.mode_remboursement}). Frais de dossier : {xof(c.frais_dossier)}.</p>
          {d.comite && <p>Décision du comité de crédit (séance {d.comite.seance}) : {d.comite.motif}{d.comite.conditions ? ` — conditions suspensives : ${d.comite.conditions}` : ''}.</p>}
          {d.garantie_compte && <p>Garantie : {xof(d.garantie_compte.montant_bloque)} bloqués sur le compte {d.garantie_compte.compte}.</p>}
          {d.garants && d.garants.length > 0 && <p>Cautions : {d.garants.map((g) => `${g.nom} (${xof(g.montant_caution)})`).join(' ; ')}.</p>}
          <table className="t" style={{ width: '100%' }}>
            <thead><tr><th>#</th><th>Date</th><th className="num">Capital</th><th className="num">Intérêts</th></tr></thead>
            <tbody>{d.echeances?.map((e) => <tr key={e.no_echeance}><td>{e.no_echeance}</td><td>{fdate(e.date_prevue)}</td><td className="num">{xof(e.capital)}</td><td className="num">{xof(e.interet)}</td></tr>)}</tbody>
          </table>
          <p>Le non-paiement d'une échéance expose l'emprunteur aux pénalités de retard et, après relances et mise en demeure, à la réalisation des garanties.</p>
          <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 40 }}><div>L'emprunteur<div style={{ height: 48 }} /></div><div style={{ textAlign: 'right' }}>Pour l'institution<div style={{ height: 48 }} /></div></div>
        </>
      ) : (
        <>
          <p>L'institution certifie que <strong>{c.client}</strong> (n° {c.client_numero}) a entièrement remboursé le crédit n° {c.numero} de {xof(c.montant_accorde)}, débloqué le {fdate(c.date_deblocage)} et soldé le {fdate(c.date_solde)}.</p>
          <p>Capital remboursé : {xof(d.totaux?.capital)} — intérêts payés : {xof(d.totaux?.interets)} — pénalités payées : {xof(d.totaux?.penalites)}.</p>
          <p>Aucune somme n'est due au titre de ce crédit.</p>
          <div style={{ textAlign: 'right', marginTop: 40 }}>Le responsable<div style={{ height: 48 }} /></div>
        </>
      )}
      {i.pied_de_page && <div style={{ marginTop: 16, borderTop: '1px solid #999', paddingTop: 6, fontSize: 11, textAlign: 'center' }}>{i.pied_de_page}</div>}
    </div>
  )
}
