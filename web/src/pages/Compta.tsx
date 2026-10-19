import { useEffect, useState } from 'react'
import { api } from '../lib/api'
import { telechargerCsv } from '../lib/csv'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Modal, Page, Select, Statut, Table, Tabs, useAction, useFetch } from '../components/ui'

interface BalanceLigne { compte: string; libelle: string; debit: number; credit: number; solde_debiteur: number; solde_crediteur: number }
interface Piece { id: number; numero: string; date_piece: string; libelle: string; evenement: string | null; origine: string; journal: string; total: number }
interface PieceDet extends Piece { ecritures: { ligne: number; compte_code: string; compte: string; debit: number; credit: number; libelle: string | null }[] }
interface Compte { code: string; libelle: string; classe: string; imputable: boolean }
interface Exercice { id: number; code: string; date_debut: string; date_fin: string; statut: string }

const AN = new Date().getFullYear()
const JOURNAUX = [['OD', 'Opérations diverses'], ['CAI', 'Caisse'], ['EPA', 'Épargne'], ['CRE', 'Crédits'], ['AGT', 'Agents'], ['PAI', 'Paie']]

export default function Compta() {
  const { agenceId } = useSession()
  const [onglet, setOnglet] = useState('balance')
  const [du, setDu] = useState(`${AN}-01-01`)
  const [au, setAu] = useState(`${AN}-12-31`)
  return (
    <Page title="Comptabilité" subtitle="Référentiel comptable des SFD de l'UMOA">
      <Tabs actif={onglet} onChange={setOnglet} tabs={[
        { id: 'balance', titre: 'Balance' }, { id: 'bilan', titre: 'Bilan' }, { id: 'grand-livre', titre: 'Grand livre' }, { id: 'pieces', titre: 'Pièces' },
        { id: 'plan', titre: 'Plan de comptes' }, { id: 'exercices', titre: 'Exercices' },
      ]} />
      {onglet === 'bilan' && <Bilan key={`${au}${agenceId}`} au={au} onAu={setAu} />}
      {['balance', 'grand-livre', 'pieces'].includes(onglet) && (
        <Card><div className="row">
          <Field label="Du"><Input type="date" value={du} onChange={(e) => setDu(e.target.value)} /></Field>
          <Field label="Au"><Input type="date" value={au} onChange={(e) => setAu(e.target.value)} /></Field>
        </div></Card>
      )}
      {onglet === 'balance' && <Balance key={`${du}${au}${agenceId}`} du={du} au={au} />}
      {onglet === 'grand-livre' && <GrandLivre key={`${du}${au}${agenceId}`} du={du} au={au} />}
      {onglet === 'pieces' && <Pieces key={`${du}${au}${agenceId}`} du={du} au={au} />}
      {onglet === 'plan' && <Plan />}
      {onglet === 'exercices' && <Exercices />}
    </Page>
  )
}

function Balance({ du, au }: { du: string; au: string }) {
  const q = useFetch(() => api.get<{ lignes: BalanceLigne[]; total_debit: number; total_credit: number }>('/api/compta/balance', { du, au }), [du, au])
  const resultat = useFetch(() => api.get<{ resultat: number }>('/api/compta/resultat', { du, au }), [du, au])
  return (
    <Card title={`Balance du ${fdate(du)} au ${fdate(au)}`} flush actions={<>
      {resultat.data && <Badge tone={resultat.data.resultat >= 0 ? 'ok' : 'bad'}>Résultat : {xof(resultat.data.resultat)}</Badge>}
      {q.data && <Button small onClick={() => telechargerCsv(`balance-${du}-${au}`, ['Compte', 'Libellé', 'Débit', 'Crédit', 'Solde débiteur', 'Solde créditeur'],
        q.data!.lignes.map((l) => [l.compte, l.libelle, l.debit, l.credit, l.solde_debiteur, l.solde_crediteur]))}>Exporter en CSV</Button>}</>}>
      <Charge q={q}>
        {(b) => (
          <>
            <Table rows={b.lignes} vide="Aucune écriture sur la période" cols={[
              { titre: 'Compte', render: (l) => l.compte },
              { titre: 'Libellé', render: (l) => l.libelle },
              { titre: 'Débit', num: true, render: (l) => xof(l.debit) },
              { titre: 'Crédit', num: true, render: (l) => xof(l.credit) },
              { titre: 'Solde débiteur', num: true, render: (l) => (l.solde_debiteur ? xof(l.solde_debiteur) : '') },
              { titre: 'Solde créditeur', num: true, render: (l) => (l.solde_crediteur ? xof(l.solde_crediteur) : '') },
            ]} />
            {b.lignes.length > 0 && (
              <div className="card-b"><strong>Totaux :</strong> débit {xof(b.total_debit)} · crédit {xof(b.total_credit)} {b.total_debit === b.total_credit ? <Badge tone="ok">Équilibrée</Badge> : <Badge tone="bad">Déséquilibrée</Badge>}</div>
            )}
          </>
        )}
      </Charge>
    </Card>
  )
}

interface BilanLigne { cote: string; classe: string; code: string; libelle: string; montant: number }

function Bilan({ au, onAu }: { au: string; onAu: (v: string) => void }) {
  const q = useFetch(() => api.get<{ actif: BilanLigne[]; passif: BilanLigne[]; total_actif: number; total_passif: number }>('/api/compta/bilan', { au }), [au])
  const bloc = (titre: string, lignes: BilanLigne[], total: number) => (
    <Card title={titre} flush>
      <Table rows={lignes} vide="Aucune écriture" cols={[
        { titre: 'Compte', render: (l) => l.code },
        { titre: 'Libellé', render: (l) => l.code === 'RES' ? <em>{l.libelle}</em> : l.libelle },
        { titre: 'Montant', num: true, render: (l) => xof(l.montant) },
      ]} />
      <div className="card-b"><strong>Total : {xof(total)}</strong></div>
    </Card>
  )
  return (
    <div className="stack">
      <Card><div className="row"><Field label="Situation au"><Input type="date" value={au} onChange={(e) => onAu(e.target.value || au)} /></Field></div></Card>
      <Charge q={q}>
        {(b) => (
          <>
            <div className="grid-2">{bloc('Actif', b.actif, b.total_actif)}{bloc('Passif', b.passif, b.total_passif)}</div>
            <div className="actions">
              {b.total_actif === b.total_passif ? <Badge tone="ok">Équilibré</Badge> : <Badge tone="bad">Déséquilibré</Badge>}
              <Button small onClick={() => telechargerCsv(`bilan-${au}`, ['Côté', 'Compte', 'Libellé', 'Montant'], [...b.actif, ...b.passif].map((l) => [l.cote, l.code, l.libelle, l.montant]))}>Exporter en CSV</Button>
            </div>
            <Alert tone="warn">Bilan simplifié par compte de niveau 2, issu des écritures jusqu'à la date : document de travail, non réglementaire. Le résultat de l'exercice (ligne RES) est ajouté pour équilibrer ; un résultat négatif figure à l'actif.</Alert>
          </>
        )}
      </Charge>
    </div>
  )
}

function GrandLivre({ du, au }: { du: string; au: string }) {
  const [code, setCode] = useState('')
  const [valide, setValide] = useState('')
  const comptes = useFetch(() => api.get<Compte[]>('/api/compta/comptes', { q: code, imputable: true, limit: 8 }), [code])
  const q = useFetch(() => (valide ? api.get<{ date_piece: string; numero: string; libelle: string; debit: number; credit: number; solde_cumule: number }[]>('/api/compta/grand-livre', { compte: valide, du, au }) : Promise.resolve([])), [valide, du, au])
  return (
    <div className="stack">
      <Card><div className="row">
        <Field label="Compte" hint="Code ou mot du libellé (ex. 1011, épargne)">
          <Input value={code} onChange={(e) => setCode(e.target.value)} placeholder="1011" />
        </Field>
        <div className="actions">{(comptes.data ?? []).map((c) => <Button key={c.code} small variant={valide === c.code ? 'primary' : undefined} onClick={() => setValide(c.code)} title={c.libelle}>{c.code}</Button>)}</div>
      </div></Card>
      {valide && (
        <Card title={`Grand livre — compte ${valide}`} flush>
          <Charge q={q}>
            {(rows) => (
              <Table rows={rows} vide="Aucune écriture sur ce compte" cols={[
                { titre: 'Date', render: (l) => fdate(l.date_piece) },
                { titre: 'Pièce', render: (l) => l.numero },
                { titre: 'Libellé', render: (l) => l.libelle },
                { titre: 'Débit', num: true, render: (l) => (l.debit ? xof(l.debit) : '') },
                { titre: 'Crédit', num: true, render: (l) => (l.credit ? xof(l.credit) : '') },
                { titre: 'Solde cumulé', num: true, render: (l) => xof(l.solde_cumule) },
              ]} />
            )}
          </Charge>
        </Card>
      )}
    </div>
  )
}

function Pieces({ du, au }: { du: string; au: string }) {
  const { can } = useSession()
  const q = useFetch(() => api.get<Piece[]>('/api/compta/pieces', { du, au, limit: 200 }), [du, au])
  const [ouverte, setOuverte] = useState<number | null>(null)
  const [nouvelle, setNouvelle] = useState(false)
  return (
    <Card title="Pièces comptables" flush actions={can('compta:write') && <Button variant="primary" onClick={() => setNouvelle(true)}>Nouvelle pièce</Button>}>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} onRowClick={(p) => setOuverte(p.id)} vide="Aucune pièce sur la période" cols={[
            { titre: 'Date', render: (p) => fdate(p.date_piece) },
            { titre: 'Numéro', render: (p) => p.numero },
            { titre: 'Journal', render: (p) => p.journal },
            { titre: 'Libellé', render: (p) => p.libelle },
            { titre: 'Origine', render: (p) => <Badge tone={p.origine === 'auto' ? 'info' : p.origine === 'contrepassation' ? 'warn' : 'neutre'}>{p.origine === 'auto' ? 'Automatique' : p.origine === 'contrepassation' ? 'Contrepassation' : 'Saisie'}</Badge> },
            { titre: 'Montant', num: true, render: (p) => xof(p.total) },
          ]} />
        )}
      </Charge>
      {ouverte !== null && <DetailPiece id={ouverte} onClose={() => setOuverte(null)} onFait={() => { setOuverte(null); q.reload() }} />}
      {nouvelle && <NouvellePiece onClose={() => setNouvelle(false)} onFait={() => { setNouvelle(false); q.reload() }} />}
    </Card>
  )
}

function DetailPiece({ id, onClose, onFait }: { id: number; onClose: () => void; onFait: () => void }) {
  const { can } = useSession()
  const q = useFetch(() => api.get<PieceDet>(`/api/compta/pieces/${id}`), [id])
  const { run, busy } = useAction()
  return (
    <Modal titre="Pièce comptable" onClose={onClose} large>
      <Charge q={q}>
        {(p) => (
          <div className="stack">
            <p style={{ margin: 0 }}><strong>{p.numero}</strong> · {fdate(p.date_piece)} · journal {p.journal} · {p.libelle}</p>
            <Table rows={p.ecritures} cols={[
              { titre: 'Compte', render: (e) => <>{e.compte_code}<div className="muted">{e.compte}</div></> },
              { titre: 'Débit', num: true, render: (e) => (e.debit ? xof(e.debit) : '') },
              { titre: 'Crédit', num: true, render: (e) => (e.credit ? xof(e.credit) : '') },
            ]} />
            {can('compta:write') && p.origine !== 'contrepassation' && (
              <div className="actions"><Button variant="danger" disabled={busy} onClick={() => void run(() => api.post(`/api/compta/pieces/${id}/contrepasser`, { date: aujourdhui(), motif: 'Correction' }), 'Pièce contrepassée', onFait)}>Contrepasser cette pièce</Button></div>
            )}
          </div>
        )}
      </Charge>
    </Modal>
  )
}

function NouvellePiece({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ journal: 'OD', date: aujourdhui(), libelle: '' })
  const [lignes, setLignes] = useState([{ compte: '', debit: '', credit: '' }, { compte: '', debit: '', credit: '' }])
  const maj = (i: number, v: Partial<(typeof lignes)[number]>) => setLignes(lignes.map((l, j) => (j === i ? { ...l, ...v } : l)))
  const d = lignes.reduce((s, l) => s + (Number(l.debit) || 0), 0)
  const c = lignes.reduce((s, l) => s + (Number(l.credit) || 0), 0)
  const equilibre = d > 0 && d === c
  return (
    <FormModal titre="Nouvelle pièce comptable" onClose={onClose} busy={busy} valider="Enregistrer la pièce" large
      onSubmit={() => equilibre && void run(() => api.post('/api/compta/pieces', {
        journal: f.journal, date_piece: f.date, libelle: f.libelle,
        lignes: lignes.filter((l) => l.compte).map((l) => ({ compte_code: l.compte.trim(), debit: Number(l.debit) || 0, credit: Number(l.credit) || 0 })),
      }), 'Pièce enregistrée', onFait)}>
      <Field label="Journal"><Select value={f.journal} onChange={(e) => setF({ ...f, journal: e.target.value })}>{JOURNAUX.map(([k, v]) => <option key={k} value={k}>{k} — {v}</option>)}</Select></Field>
      <Field label="Date"><Input type="date" value={f.date} onChange={(e) => setF({ ...f, date: e.target.value })} required /></Field>
      <Field label="Libellé"><Input value={f.libelle} onChange={(e) => setF({ ...f, libelle: e.target.value })} required /></Field>
      <div style={{ gridColumn: '1 / -1' }} className="stack">
        {lignes.map((l, i) => (
          <div key={i} className="row">
            <Field label={`Compte ${i + 1}`}><Input value={l.compte} onChange={(e) => maj(i, { compte: e.target.value })} placeholder="ex. 6212" /></Field>
            <Field label="Débit (F)"><Input type="number" min={0} value={l.debit} onChange={(e) => maj(i, { debit: e.target.value, credit: e.target.value ? '' : l.credit })} /></Field>
            <Field label="Crédit (F)"><Input type="number" min={0} value={l.credit} onChange={(e) => maj(i, { credit: e.target.value, debit: e.target.value ? '' : l.debit })} /></Field>
          </div>
        ))}
        <div className="actions">
          <Button small onClick={() => setLignes([...lignes, { compte: '', debit: '', credit: '' }])}>Ajouter une ligne</Button>
          {equilibre ? <Badge tone="ok">Équilibrée : {xof(d)}</Badge> : <Alert tone="warn">Débit {xof(d)} · crédit {xof(c)} : la pièce doit être équilibrée.</Alert>}
        </div>
        <p className="muted" style={{ margin: 0 }}>Seuls les comptes sans sous-compte reçoivent des écritures (onglet « Plan de comptes »).</p>
      </div>
    </FormModal>
  )
}

function Plan() {
  const [q, setQ] = useState('')
  const [qd, setQd] = useState('')
  const [classe, setClasse] = useState('')
  useEffect(() => { const t = setTimeout(() => setQd(q), 250); return () => clearTimeout(t) }, [q])
  const r = useFetch(() => api.get<Compte[]>('/api/compta/comptes', { q: qd, classe, limit: 200 }), [qd, classe])
  return (
    <Card flush>
      <div className="card-b row">
        <Field label="Recherche"><Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Code ou libellé" /></Field>
        <Field label="Classe"><Select value={classe} onChange={(e) => setClasse(e.target.value)}><option value="">Toutes</option>{['1', '2', '3', '4', '5', '6', '7', '9'].map((c) => <option key={c} value={c}>Classe {c}</option>)}</Select></Field>
      </div>
      <Charge q={r}>
        {(rows) => (
          <Table rows={rows} vide="Aucun compte" cols={[
            { titre: 'Code', render: (c) => <strong>{c.code}</strong> },
            { titre: 'Libellé', render: (c) => c.libelle },
            { titre: 'Imputable', render: (c) => (c.imputable ? <Badge tone="ok">Oui</Badge> : <Badge>Titre</Badge>) },
          ]} />
        )}
      </Charge>
    </Card>
  )
}

function Exercices() {
  const { can } = useSession()
  const q = useFetch(() => api.get<Exercice[]>('/api/compta/exercices'), [])
  const { run, busy } = useAction()
  const [nouveau, setNouveau] = useState(false)
  return (
    <Card title="Exercices comptables" flush actions={can('compta:write') && <Button onClick={() => setNouveau(true)}>Nouvel exercice</Button>}>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucun exercice : créez-en un avant toute écriture" cols={[
            { titre: 'Code', render: (e) => <strong>{e.code}</strong> },
            { titre: 'Du', render: (e) => fdate(e.date_debut) },
            { titre: 'Au', render: (e) => fdate(e.date_fin) },
            { titre: 'Statut', render: (e) => <Statut s={e.statut} /> },
            { titre: '', render: (e) => e.statut === 'ouvert' && can('compta:write') && <Button small variant="danger" disabled={busy} onClick={() => { if (window.confirm(`Clôturer l'exercice ${e.code} ? Plus aucune écriture ne sera possible.`)) void run(() => api.post(`/api/compta/exercices/${e.id}/cloturer`), 'Exercice clôturé', q.reload) }}>Clôturer</Button> },
          ]} />
        )}
      </Charge>
      {nouveau && <NouvelExercice onClose={() => setNouveau(false)} onFait={() => { setNouveau(false); q.reload() }} />}
    </Card>
  )
}

function NouvelExercice({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ code: String(AN), debut: `${AN}-01-01`, fin: `${AN}-12-31` })
  return (
    <FormModal titre="Nouvel exercice" onClose={onClose} busy={busy} valider="Créer"
      onSubmit={() => void run(() => api.post('/api/compta/exercices', { code: f.code, date_debut: f.debut, date_fin: f.fin }), 'Exercice créé', onFait)}>
      <Field label="Code"><Input value={f.code} maxLength={10} onChange={(e) => setF({ ...f, code: e.target.value })} required /></Field>
      <Field label="Début"><Input type="date" value={f.debut} onChange={(e) => setF({ ...f, debut: e.target.value })} required /></Field>
      <Field label="Fin"><Input type="date" value={f.fin} onChange={(e) => setF({ ...f, fin: e.target.value })} required /></Field>
    </FormModal>
  )
}
