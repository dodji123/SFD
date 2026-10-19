import { useState } from 'react'
import { Link } from 'react-router-dom'
import { api } from '../lib/api'
import { date as fdate } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Page, Select, Table, Tabs, useAction, useFetch } from '../components/ui'

interface Alerte {
  id: number; client_id: number; client_numero: string; client: string; type: 'sanction' | 'ppe'; score: number; statut: 'a_examiner' | 'confirmee' | 'ecartee'
  note: string | null; nom_liste: string; source: string; reference: string | null; pays: string | null; decide_par: string | null
}
interface ResumeListe { source: string; categorie: string; entrees: number }
interface PieceARenouveler { piece_id: number; client_id: number; client_numero: string; nom: string; type: string; numero: string; date_expiration: string }

export default function Conformite() {
  const { can } = useSession()
  const [onglet, setOnglet] = useState('alertes')
  return (
    <Page title="Conformité LBC/FT" subtitle="Alertes de rapprochement avec les listes de sanctions et de personnes politiquement exposées, pièces à renouveler">
      <Tabs actif={onglet} onChange={setOnglet} tabs={[
        { id: 'alertes', titre: 'Alertes' }, { id: 'listes', titre: 'Listes de surveillance' }, { id: 'pieces', titre: 'Pièces à renouveler' },
      ]} />
      {onglet === 'alertes' && <Alertes peutTrancher={can('lbc:write')} />}
      {onglet === 'listes' && <Listes peutImporter={can('lbc:listes')} />}
      {onglet === 'pieces' && <Pieces />}
    </Page>
  )
}

function Alertes({ peutTrancher }: { peutTrancher: boolean }) {
  const [statut, setStatut] = useState('a_examiner')
  const q = useFetch(() => api.get<Alerte[]>('/api/lbc/alertes', statut ? { statut } : undefined), [statut])
  const [choix, setChoix] = useState<Alerte | null>(null)
  return (
    <Card flush actions={<Select value={statut} onChange={(e) => setStatut(e.target.value)}>
      <option value="a_examiner">À examiner</option><option value="confirmee">Confirmées</option><option value="ecartee">Écartées</option><option value="">Toutes</option>
    </Select>}>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucune alerte" cols={[
            { titre: 'Client', render: (a) => <><Link to={`/clients/${a.client_id}`}><strong>{a.client}</strong></Link><div className="muted">{a.client_numero}</div></> },
            { titre: 'Type', render: (a) => <Badge tone={a.type === 'sanction' ? 'bad' : 'warn'}>{a.type === 'sanction' ? 'Sanction' : 'PPE'}</Badge> },
            { titre: 'Entrée de liste', render: (a) => <>{a.nom_liste}<div className="muted">{a.source}{a.pays ? ' · ' + a.pays : ''}{a.reference ? ' · ' + a.reference : ''}</div></> },
            { titre: 'Similarité', num: true, render: (a) => `${Math.round(a.score * 100)} %` },
            { titre: 'Statut', render: (a) => (a.statut === 'a_examiner' ? <Badge tone="warn">À examiner</Badge> : <><Badge tone={a.statut === 'confirmee' ? 'bad' : 'ok'}>{a.statut === 'confirmee' ? 'Confirmée' : 'Écartée'}</Badge><div className="muted">{a.decide_par}{a.note ? ' — ' + a.note : ''}</div></>) },
            { titre: '', render: (a) => peutTrancher && a.statut === 'a_examiner' && <Button small onClick={() => setChoix(a)}>Trancher</Button> },
          ]} />
        )}
      </Charge>
      {choix && <Decision alerte={choix} onClose={() => setChoix(null)} onFait={() => { setChoix(null); q.reload() }} />}
    </Card>
  )
}

function Decision({ alerte, onClose, onFait }: { alerte: Alerte; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ decision: 'ecartee', note: '' })
  return (
    <FormModal titre={`Alerte — ${alerte.client}`} onClose={onClose} busy={busy} valider="Enregistrer la décision"
      onSubmit={() => void run(() => api.post(`/api/lbc/alertes/${alerte.id}/traiter`, { decision: f.decision, note: f.note || null }), 'Décision enregistrée', onFait)}>
      <div style={{ gridColumn: '1 / -1' }}>
        <Alert tone="info">Le client « {alerte.client} » ressemble à « {alerte.nom_liste} » ({alerte.source}) à {Math.round(alerte.score * 100)} %. Comparez date de naissance, pays et filiation avant de décider.</Alert>
      </div>
      <Field label="Décision">
        <Select value={f.decision} onChange={(e) => setF({ ...f, decision: e.target.value })}>
          <option value="ecartee">Écarter (homonyme)</option><option value="confirmee">Confirmer la correspondance</option>
        </Select>
      </Field>
      <Field label="Justification" hint={f.decision === 'ecartee' ? 'Obligatoire pour écarter' : 'Recommandée'}>
        <Input value={f.note} onChange={(e) => setF({ ...f, note: e.target.value })} required={f.decision === 'ecartee'} />
      </Field>
      {f.decision === 'confirmee' && alerte.type === 'sanction' && <div style={{ gridColumn: '1 / -1' }}><Alert tone="bad">Confirmer une sanction bloque les demandes de crédit du client et remet son KYC à « incomplet ». La déclaration de soupçon à la CENTIF se fait hors du logiciel.</Alert></div>}
    </FormModal>
  )
}

function Listes({ peutImporter }: { peutImporter: boolean }) {
  const q = useFetch(() => api.get<ResumeListe[]>('/api/lbc/listes'), [])
  const [ouvert, setOuvert] = useState(false)
  return (
    <Card title="Listes chargées" flush actions={peutImporter && <Button variant="primary" onClick={() => setOuvert(true)}>Importer des noms</Button>}>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucune liste chargée : le filtrage ne peut rien détecter" cols={[
            { titre: 'Source', render: (r) => <strong>{r.source}</strong> },
            { titre: 'Catégorie', render: (r) => (r.categorie === 'sanction' ? 'Sanctions' : 'Personnes politiquement exposées') },
            { titre: 'Entrées actives', num: true, render: (r) => r.entrees },
          ]} />
        )}
      </Charge>
      <div className="card-b"><Alert tone="warn">Le logiciel ne télécharge aucune liste officielle : il faut importer celles de votre institution (ONU, UE, listes nationales, PPE). Le rapprochement est approximatif et produit des alertes à examiner, jamais une décision automatique.</Alert></div>
      {ouvert && <Import onClose={() => setOuvert(false)} onFait={() => { setOuvert(false); q.reload() }} />}
    </Card>
  )
}

function Import({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ source: '', categorie: 'sanction', noms: '' })
  return (
    <FormModal titre="Importer des noms" onClose={onClose} busy={busy} valider="Importer" large
      onSubmit={() => void run(() => api.post('/api/lbc/listes', {
        source: f.source, categorie: f.categorie,
        entrees: f.noms.split('\n').map((n) => n.trim()).filter((n) => n.length >= 2).map((nom) => ({ nom })),
      }), 'Liste importée', onFait)}>
      <Field label="Source"><Input value={f.source} onChange={(e) => setF({ ...f, source: e.target.value })} placeholder="ONU, liste nationale…" required /></Field>
      <Field label="Catégorie"><Select value={f.categorie} onChange={(e) => setF({ ...f, categorie: e.target.value })}><option value="sanction">Sanctions</option><option value="ppe">PPE</option></Select></Field>
      <Field label="Noms (un par ligne)"><textarea className="input" rows={8} value={f.noms} onChange={(e) => setF({ ...f, noms: e.target.value })} required /></Field>
    </FormModal>
  )
}

function Pieces() {
  const q = useFetch(() => api.get<PieceARenouveler[]>('/api/kyc/pieces-a-renouveler'), [])
  const aujourdhui = new Date().toISOString().slice(0, 10)
  return (
    <Card flush>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucune pièce n'expire dans les 30 jours" cols={[
            { titre: 'Client', render: (p) => <><Link to={`/clients/${p.client_id}`}><strong>{p.nom}</strong></Link><div className="muted">{p.client_numero}</div></> },
            { titre: 'Pièce', render: (p) => `${p.type} ${p.numero}` },
            { titre: 'Expiration', render: (p) => fdate(p.date_expiration) },
            { titre: '', render: (p) => <Badge tone={p.date_expiration < aujourdhui ? 'bad' : 'warn'}>{p.date_expiration < aujourdhui ? 'Expirée' : 'Bientôt'}</Badge> },
          ]} />
        )}
      </Charge>
    </Card>
  )
}
