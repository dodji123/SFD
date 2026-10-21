import { useEffect, useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, dateHeure, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { BoutonScanner, lireQr } from '../components/Qr'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Modal, Page, Select, Table, useAction, useFetch } from '../components/ui'

interface Ecart { id?: number; no_ligne: number; date_collecte: string | null; montant_livret: number | null; montant_systeme: number | null; nature: string; note: string | null }
interface Controle {
  id: number; cycle_id: number; cycle: string; client: string; client_numero: string; produit: string; controleur: string; date_controle: string
  etat_livret: string; nb_lignes_constatees: number | null; total_constate: number | null; nb_lignes_systeme: number; total_systeme: number; ecart_montant: number | null
  commentaire: string | null; statut: string; decide_par_nom: string | null; decide_le: string | null; commentaire_decision: string | null
  nb_ecarts_lignes: number; ecarts?: Ecart[]
}
interface CycleLigne { id: number; numero: string; client: string; produit: string; nb_lignes: number; montant_collecte: number }

const ETATS: Record<string, string> = { conforme: 'Conforme', incomplet: 'Incomplet', abime: 'Abîmé', perdu: 'Perdu', non_presente: 'Non présenté' }
const NATURES: Record<string, string> = { absente_systeme: 'Sur le livret, absente du système', absente_livret: 'Dans le système, absente du livret', montant_different: 'Montant différent' }
const STATUTS: Record<string, { texte: string; tone: 'warn' | 'ok' | 'bad' }> = { a_valider: { texte: 'À valider', tone: 'warn' }, valide: { texte: 'Validé', tone: 'ok' }, rejete: { texte: 'Rejeté', tone: 'bad' } }

/** Contrôle des livrets sur le terrain : constats des contrôleurs, rapprochement avec le système, validation par un responsable. */
export default function ControleLivrets() {
  const { can, agenceId } = useSession()
  const [statut, setStatut] = useState('a_valider')
  const [etat, setEtat] = useState('')
  const [avecEcart, setAvecEcart] = useState('')
  const [controleur, setControleur] = useState('')
  const [q, setQ] = useState('')
  const [du, setDu] = useState('')
  const [au, setAu] = useState('')
  const [qd, setQd] = useState('')
  const [ouvert, setOuvert] = useState<number | null>(null)
  const [nouveau, setNouveau] = useState(false)
  useEffect(() => { const t = setTimeout(() => setQd(q), 250); return () => clearTimeout(t) }, [q])
  const liste = useFetch(() => api.get<Controle[]>('/api/controles-livrets', { statut, etat, avec_ecart: avecEcart, controleur: controleur.trim(), q: qd, du, au }), [statut, etat, avecEcart, controleur, qd, du, au, agenceId])
  return (
    <Page title="Contrôle des livrets" subtitle="Constats faits sur le terrain, rapprochés du système et validés par un responsable">
      <Card flush actions={can('livret:controler') && <Button variant="primary" onClick={() => setNouveau(true)}>Nouveau contrôle</Button>}>
        <div className="card-b row">
          <Field label="Recherche"><Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Cycle, client, numéro, produit" /></Field>
          <BoutonScanner onLu={(t) => setQ(lireQr(t).numero)} />
          <Field label="Statut"><Select value={statut} onChange={(e) => setStatut(e.target.value)}><option value="">Tous</option>{Object.entries(STATUTS).map(([k, v]) => <option key={k} value={k}>{v.texte}</option>)}</Select></Field>
          <Field label="État du livret"><Select value={etat} onChange={(e) => setEtat(e.target.value)}><option value="">Tous</option>{Object.entries(ETATS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
          <Field label="Écarts"><Select value={avecEcart} onChange={(e) => setAvecEcart(e.target.value)}><option value="">Tous</option><option value="true">Avec écart ou anomalie</option><option value="false">Sans écart</option></Select></Field>
          <Field label="Contrôleur"><Input value={controleur} onChange={(e) => setControleur(e.target.value)} placeholder="Nom" /></Field>
          <Field label="Du"><Input type="date" value={du} onChange={(e) => setDu(e.target.value)} /></Field>
          <Field label="Au"><Input type="date" value={au} onChange={(e) => setAu(e.target.value)} /></Field>
        </div>
        <Charge q={liste}>
          {(rows) => (
            <Table rows={rows} onRowClick={(c) => setOuvert(c.id)} vide="Aucun contrôle" cols={[
              { titre: 'Date', render: (c) => fdate(c.date_controle) },
              { titre: 'Cycle', render: (c) => c.cycle },
              { titre: 'Client', render: (c) => `${c.client} (${c.client_numero})` },
              { titre: 'Produit', render: (c) => c.produit },
              { titre: 'État', render: (c) => <Badge tone={c.etat_livret === 'conforme' ? 'ok' : 'warn'}>{ETATS[c.etat_livret] ?? c.etat_livret}</Badge> },
              { titre: 'Écart', num: true, render: (c) => (c.ecart_montant === null ? '—' : xof(c.ecart_montant)) },
              { titre: 'Lignes en écart', num: true, render: (c) => c.nb_ecarts_lignes },
              { titre: 'Contrôleur', render: (c) => c.controleur },
              { titre: 'Statut', render: (c) => <Badge tone={STATUTS[c.statut]?.tone ?? 'neutre'}>{STATUTS[c.statut]?.texte ?? c.statut}</Badge> },
            ]} />
          )}
        </Charge>
      </Card>
      {ouvert !== null && <DetailControle id={ouvert} onClose={() => setOuvert(null)} onChange={liste.reload} />}
      {nouveau && <NouveauControle onClose={() => setNouveau(false)} onFait={() => { setNouveau(false); liste.reload() }} />}
    </Page>
  )
}

function DetailControle({ id, onClose, onChange }: { id: number; onClose: () => void; onChange: () => void }) {
  const { can } = useSession()
  const q = useFetch(() => api.get<Controle>(`/api/controles-livrets/${id}`), [id])
  const { run, busy } = useAction()
  const [commentaire, setCommentaire] = useState('')
  const decider = (valide: boolean) => void run(() => api.post(`/api/controles-livrets/${id}/decider`, { valide, commentaire: commentaire.trim() || null }),
    valide ? 'Contrôle validé' : 'Contrôle rejeté', () => { q.reload(); onChange() })
  return (
    <Modal titre="Contrôle de livret" onClose={onClose} large footer={<Button onClick={onClose}>Fermer</Button>}>
      <Charge q={q}>
        {(c) => (
          <div className="stack">
            <p style={{ margin: 0 }}><strong>{c.cycle}</strong> · {c.client} ({c.client_numero}) · {c.produit} — contrôlé le {fdate(c.date_controle)} par {c.controleur} <Badge tone={STATUTS[c.statut]?.tone ?? 'neutre'}>{STATUTS[c.statut]?.texte ?? c.statut}</Badge></p>
            <Table rows={[c]} cols={[
              { titre: 'État du livret', render: (x) => ETATS[x.etat_livret] ?? x.etat_livret },
              { titre: 'Lignes constatées', num: true, render: (x) => x.nb_lignes_constatees ?? '—' },
              { titre: 'Lignes système', num: true, render: (x) => x.nb_lignes_systeme },
              { titre: 'Total constaté', num: true, render: (x) => (x.total_constate === null ? '—' : xof(x.total_constate)) },
              { titre: 'Total système', num: true, render: (x) => xof(x.total_systeme) },
              { titre: 'Écart', num: true, render: (x) => (x.ecart_montant === null ? '—' : xof(x.ecart_montant)) },
            ]} />
            {c.commentaire && <p style={{ margin: 0 }}>Commentaire du contrôleur : {c.commentaire}</p>}
            {(c.ecarts?.length ?? 0) > 0 && (
              <Table rows={c.ecarts ?? []} cols={[
                { titre: 'Ligne', num: true, render: (e) => e.no_ligne }, { titre: 'Date', render: (e) => (e.date_collecte ? fdate(e.date_collecte) : '—') },
                { titre: 'Nature', render: (e) => NATURES[e.nature] ?? e.nature },
                { titre: 'Livret', num: true, render: (e) => (e.montant_livret === null ? '—' : xof(e.montant_livret)) },
                { titre: 'Système', num: true, render: (e) => (e.montant_systeme === null ? '—' : xof(e.montant_systeme)) },
                { titre: 'Note', render: (e) => e.note ?? '' },
              ]} />
            )}
            {c.statut !== 'a_valider' && <Alert tone="info">{STATUTS[c.statut]?.texte} par {c.decide_par_nom} le {dateHeure(c.decide_le)}{c.commentaire_decision ? ` — ${c.commentaire_decision}` : ''}. Un contrôle décidé ne se modifie plus.</Alert>}
            {c.statut === 'a_valider' && can('livret:valider') && (
              <div className="stack">
                <Field label="Commentaire de décision (obligatoire pour un rejet)"><Input value={commentaire} onChange={(e) => setCommentaire(e.target.value)} /></Field>
                <div className="row">
                  <Button variant="primary" disabled={busy} onClick={() => decider(true)}>Valider</Button>
                  <Button variant="danger" disabled={busy} onClick={() => decider(false)}>Rejeter</Button>
                </div>
                <p className="muted" style={{ margin: 0 }}>Le contrôleur ne peut pas valider son propre contrôle.</p>
              </div>
            )}
          </div>
        )}
      </Charge>
    </Modal>
  )
}

function NouveauControle({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [recherche, setRecherche] = useState('')
  const [cycle, setCycle] = useState<CycleLigne | null>(null)
  const [trouves, setTrouves] = useState<CycleLigne[]>([])
  const [f, setF] = useState({ etat_livret: 'conforme', nb: '', total: '', commentaire: '', date_controle: aujourdhui() })
  const [ecarts, setEcarts] = useState<Ecart[]>([])
  const [cle] = useState(() => `web-${crypto.randomUUID()}`)
  useEffect(() => {
    if (recherche.trim().length < 2 || cycle) { setTrouves([]); return }
    let ok = true
    const t = setTimeout(() => { api.get<CycleLigne[]>('/api/cycles', { q: recherche.trim(), statut: 'en_cours', limit: 8 }).then((d) => ok && setTrouves(d)).catch(() => ok && setTrouves([])) }, 250)
    return () => { ok = false; clearTimeout(t) }
  }, [recherche, cycle])
  const sansChiffres = f.etat_livret === 'perdu' || f.etat_livret === 'non_presente'
  const majEcart = (i: number, p: Partial<Ecart>) => setEcarts((l) => l.map((e, k) => (k === i ? { ...e, ...p } : e)))
  return (
    <FormModal titre="Nouveau contrôle de livret" onClose={onClose} busy={busy || !cycle} large valider="Enregistrer le contrôle"
      onSubmit={() => { if (!cycle) return; void run(() => api.post('/api/controles-livrets', {
        cycle_id: cycle.id, etat_livret: f.etat_livret, cle, date_controle: f.date_controle, commentaire: f.commentaire.trim() || null,
        nb_lignes_constatees: sansChiffres ? null : Number(f.nb), total_constate: sansChiffres ? null : Number(f.total),
        ecarts: sansChiffres ? [] : ecarts.map((e) => ({ ...e, date_collecte: e.date_collecte || null, note: e.note || null })),
      }), 'Contrôle enregistré : à valider par un responsable', onFait) }}>
      <div className="row">
        <Field label="Cycle (numéro, client ou produit)"><Input value={cycle ? `${cycle.numero} — ${cycle.client}` : recherche} readOnly={!!cycle} onChange={(e) => setRecherche(e.target.value)} placeholder="Scanner ou saisir" /></Field>
        {cycle ? <Button type="button" onClick={() => { setCycle(null); setRecherche('') }}>Changer</Button> : <BoutonScanner onLu={(t) => setRecherche(lireQr(t).numero)} />}
      </div>
      {trouves.length > 0 && (
        <ul role="listbox" aria-label="Cycles trouvés" style={{ margin: 0, padding: 0, listStyle: 'none' }}>
          {trouves.map((c) => <li key={c.id} role="option" aria-selected={false} tabIndex={0} style={{ padding: '6px 10px', cursor: 'pointer' }} onClick={() => setCycle(c)} onKeyDown={(e) => { if (e.key === 'Enter') setCycle(c) }}>{c.numero} — {c.client} ({c.produit})</li>)}
        </ul>
      )}
      {cycle && <Alert tone="info">Système : {cycle.nb_lignes} ligne(s) pour {xof(cycle.montant_collecte)}. Comparez au livret papier.</Alert>}
      <Field label="État du livret"><Select value={f.etat_livret} onChange={(e) => setF({ ...f, etat_livret: e.target.value })}>{Object.entries(ETATS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
      {!sansChiffres && (
        <div className="row">
          <Field label="Lignes constatées"><Input type="number" min={0} value={f.nb} onChange={(e) => setF({ ...f, nb: e.target.value })} required /></Field>
          <Field label="Total constaté (F)"><Input type="number" min={0} value={f.total} onChange={(e) => setF({ ...f, total: e.target.value })} required /></Field>
        </div>
      )}
      <Field label="Date du contrôle"><Input type="date" value={f.date_controle} max={aujourdhui()} onChange={(e) => setF({ ...f, date_controle: e.target.value })} required /></Field>
      <Field label="Commentaire" hint="Obligatoire dès qu'il y a un écart ou que le livret n'est pas conforme"><Input value={f.commentaire} onChange={(e) => setF({ ...f, commentaire: e.target.value })} /></Field>
      {!sansChiffres && (
        <div className="stack">
          <strong>Lignes en écart</strong>
          {ecarts.map((e, i) => (
            <div key={i} className="row">
              <Field label="N° ligne"><Input type="number" min={1} value={e.no_ligne} onChange={(x) => majEcart(i, { no_ligne: Number(x.target.value) })} /></Field>
              <Field label="Nature"><Select value={e.nature} onChange={(x) => majEcart(i, { nature: x.target.value, montant_livret: null, montant_systeme: null })}>{Object.entries(NATURES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
              {e.nature !== 'absente_livret' && <Field label="Montant livret (F)"><Input type="number" min={0} value={e.montant_livret ?? ''} onChange={(x) => majEcart(i, { montant_livret: x.target.value === '' ? null : Number(x.target.value) })} /></Field>}
              {e.nature !== 'absente_systeme' && <Field label="Montant système (F)"><Input type="number" min={0} value={e.montant_systeme ?? ''} onChange={(x) => majEcart(i, { montant_systeme: x.target.value === '' ? null : Number(x.target.value) })} /></Field>}
              <Button type="button" small variant="danger" onClick={() => setEcarts((l) => l.filter((_, k) => k !== i))}>Retirer</Button>
            </div>
          ))}
          <div><Button type="button" small onClick={() => setEcarts((l) => [...l, { no_ligne: l.length + 1, date_collecte: null, montant_livret: null, montant_systeme: null, nature: 'absente_systeme', note: null }])}>Ajouter une ligne en écart</Button></div>
        </div>
      )}
    </FormModal>
  )
}
