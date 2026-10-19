import { useEffect, useRef, useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useProduitsEpargne } from '../lib/hooks'
import { useRecherche } from '../lib/recherche'
import { useSession } from '../lib/session'
import { ChampClient, FiltreTableau, estNumero, filtrer } from '../components/ChampClient'
import { useAffichagePiece } from '../components/Piece'
import { Alert, Badge, Button, Card, Charge, Field, Input, Kpi, Page, Select, Table, Tabs, useAction, useFetch } from '../components/ui'

interface Trouve {
  client: { id: number; numero: string; nom: string }
  compte: { id: number; numero: string; produit: string; solde: number; disponible: number; solde_minimum: number }
}
interface Garantie { id: number; numero: string; client_numero: string; client: string; compte: string; montant: number; motif: string | null; credit: string | null; date_depot: string; statut: string }
interface Terme { id: number; numero: string; client_numero: string; client: string; compte: string; montant: number; duree_mois: number; taux_annuel: number; date_depot: string; date_echeance: string; interets_prevus: number; statut: string; echu: boolean }
interface Parametres { taux_annuel: number; duree_min_mois: number; montant_min: number; penalite_rupture_pct: number }
interface CreditLigne { id: number; numero: string; statut: string }

const ajouterMois = (iso: string, mois: number) => {
  const [a, m, j] = iso.split('-').map(Number)
  const d = new Date(Date.UTC(a, m - 1 + mois, j))
  if (d.getUTCDate() !== j) d.setUTCDate(0)            // 31 janvier + 1 mois = fin février
  return d.toISOString().slice(0, 10)
}

export default function DepotsBloques() {
  const { can, agenceId } = useSession()
  const produits = useProduitsEpargne('classique')
  const [jour, setJour] = useState(aujourdhui())
  const [produit, setProduit] = useState('')
  const [onglet, setOnglet] = useState<'garantie' | 'terme'>('garantie')
  useEffect(() => { if (!produit && produits.length === 1) setProduit(String(produits[0].id)) }, [produits, produit])

  return (
    <Page title="Dépôts de garantie et dépôts à terme" subtitle="Sommes bloquées sur le compte d'épargne d'un membre ; leur déblocage se fait sur la page Déblocages">
      {can('epargne:write') && (
        <Card title="Nouveau dépôt">
          <div className="row">
            <Field label="Jour"><Input type="date" max={aujourdhui()} value={jour} onChange={(e) => setJour(e.target.value || aujourdhui())} /></Field>
            <Field label="Produit d'épargne">
              <Select value={produit} onChange={(e) => setProduit(e.target.value)}>
                <option value="">— choisir un produit —</option>
                {produits.map((p) => <option key={p.id} value={p.id}>{p.code} — {p.libelle}</option>)}
              </Select>
            </Field>
          </div>
          <Tabs actif={onglet} onChange={(id) => setOnglet(id as 'garantie' | 'terme')} tabs={[{ id: 'garantie', titre: 'Dépôt de garantie' }, { id: 'terme', titre: 'Dépôt à terme' }]} />
          {onglet === 'garantie'
            ? <FormGarantie key={`g-${agenceId}`} jour={jour} produit={produit} />
            : <FormTerme key={`t-${agenceId}`} jour={jour} produit={produit} />}
        </Card>
      )}
      {onglet === 'garantie' ? <ListeGarantiesDuJour key={`lg-${jour}-${agenceId}`} jour={jour} /> : <ListeTermesDuJour key={`lt-${jour}-${agenceId}`} jour={jour} />}
    </Page>
  )
}

/** Zone commune aux deux formulaires : retrouver le client et son compte. */
function BlocCompte({ suffixe, onSuffixe, trouve, erreur, refNumero }: { suffixe: string; onSuffixe: (v: string) => void; trouve: Trouve | null; erreur: string | null; refNumero: React.RefObject<HTMLInputElement | null> }) {
  const c = trouve?.compte
  return (
    <>
      <div className="row">
        <ChampClient valeur={suffixe} onChange={onSuffixe} inputRef={refNumero} />
        <Field label="Numéro de base du client"><Input readOnly value={trouve?.client.numero ?? ''} /></Field>
        <Field label="Nom et prénom"><Input readOnly value={trouve?.client.nom ?? ''} /></Field>
        <Field label="N° de compte"><Input readOnly value={c?.numero ?? ''} /></Field>
        <Field label="Solde"><Input readOnly value={c ? xof(c.solde) : ''} /></Field>
        <Field label="Disponible"><Input readOnly value={c ? xof(c.disponible) : ''} /></Field>
      </div>
      {erreur && <Alert tone="warn">{erreur}</Alert>}
    </>
  )
}

function FormGarantie({ jour, produit }: { jour: string; produit: string }) {
  const [suffixe, setSuffixe] = useState('')
  const [montant, setMontant] = useState('')
  const [motif, setMotif] = useState('')
  const [credit, setCredit] = useState('')
  const refNumero = useRef<HTMLInputElement>(null)
  const refMontant = useRef<HTMLInputElement>(null)
  const { run, busy } = useAction()
  const piece = useAffichagePiece()
  const { data: trouve, erreur } = useRecherche<Trouve>('/api/comptes-epargne/recherche', estNumero(suffixe) && produit ? { suffixe, produit_id: produit, date: jour } : null)
  const credits = useFetch(() => (trouve ? api.get<CreditLigne[]>('/api/credits', { client_id: trouve.client.id }) : Promise.resolve([] as CreditLigne[])), [trouve?.client.id])
  useEffect(() => { if (trouve) refMontant.current?.focus() }, [trouve])
  const m = Number(montant)
  const pret = !!trouve && m > 0 && !busy

  return (
    <>
      <BlocCompte suffixe={suffixe} onSuffixe={setSuffixe} trouve={trouve} erreur={erreur} refNumero={refNumero} />
      <div className="row">
        <Field label="Montant du dépôt de garantie (F)" hint="Encaissé sur le compte et bloqué aussitôt">
          <Input ref={refMontant} type="number" min={1} value={montant} disabled={!trouve} aria-label="Montant à saisir" onChange={(e) => setMontant(e.target.value)} />
        </Field>
        <Field label="Crédit garanti (facultatif)">
          <Select value={credit} disabled={!trouve} onChange={(e) => setCredit(e.target.value)}>
            <option value="">— aucun crédit rattaché —</option>
            {(credits.data ?? []).filter((x) => x.statut !== 'solde').map((x) => <option key={x.id} value={x.id}>{x.numero}</option>)}
          </Select>
        </Field>
        <Field label="Motif (facultatif)"><Input value={motif} maxLength={200} disabled={!trouve} onChange={(e) => setMotif(e.target.value)} /></Field>
        <Button variant="primary" disabled={!pret}
          onClick={() => void run(async () => { const r = await api.post<{ piece_id: number | null }>('/api/depots/garanties', { compte_id: trouve!.compte.id, montant: m, motif: motif.trim() || null, credit_id: credit ? Number(credit) : null, date: jour }); piece.ouvrir(r.piece_id) },
            'Dépôt de garantie enregistré et bloqué', () => { setSuffixe(''); setMontant(''); setMotif(''); setCredit(''); window.dispatchEvent(new Event('depots-maj')); setTimeout(() => refNumero.current?.focus(), 0) })}>Valider le dépôt</Button>
      </div>
      {piece.modal}
    </>
  )
}

function FormTerme({ jour, produit }: { jour: string; produit: string }) {
  const [suffixe, setSuffixe] = useState('')
  const [montant, setMontant] = useState('')
  const [duree, setDuree] = useState('')
  const [taux, setTaux] = useState('')            // en %
  const refNumero = useRef<HTMLInputElement>(null)
  const refMontant = useRef<HTMLInputElement>(null)
  const { run, busy } = useAction()
  const piece = useAffichagePiece()
  const params = useFetch(() => api.get<Parametres>('/api/depots/parametres'), [])
  const { data: trouve, erreur } = useRecherche<Trouve>('/api/comptes-epargne/recherche', estNumero(suffixe) && produit ? { suffixe, produit_id: produit, date: jour } : null)
  useEffect(() => { if (trouve) refMontant.current?.focus() }, [trouve])

  const p = params.data
  const m = Number(montant)
  const d = Number(duree || p?.duree_min_mois || 0)
  const t = taux === '' ? (p ? p.taux_annuel * 100 : 0) : Number(taux)
  const interets = d > 0 && m > 0 ? Math.round((m * t / 100 * d) / 12) : 0
  const c = trouve?.compte
  const horsMin = !!p && m > 0 && m < p.montant_min
  const courte = !!p && d > 0 && d < p.duree_min_mois
  const trop = !!c && m > c.disponible
  const pret = !!c && m > 0 && d > 0 && !horsMin && !courte && !trop && !busy

  return (
    <>
      <BlocCompte suffixe={suffixe} onSuffixe={setSuffixe} trouve={trouve} erreur={erreur} refNumero={refNumero} />
      <div className="row">
        <Field label="Montant placé (F)" hint={p ? `Minimum ${xof(p.montant_min)} ; prélevé sur le disponible du compte` : undefined}>
          <Input ref={refMontant} type="number" min={1} value={montant} disabled={!c} aria-label="Montant à saisir" onChange={(e) => setMontant(e.target.value)} />
        </Field>
        <Field label="Durée (mois)" hint={p ? `Minimum ${p.duree_min_mois} mois` : undefined}>
          <Input type="number" min={1} value={duree} placeholder={p ? String(p.duree_min_mois) : ''} disabled={!c} onChange={(e) => setDuree(e.target.value)} />
        </Field>
        <Field label="Taux annuel (%)" hint="Taux de l'agence par défaut, modifiable">
          <Input type="number" min={0} step="0.1" value={taux} placeholder={p ? String(p.taux_annuel * 100) : ''} disabled={!c} onChange={(e) => setTaux(e.target.value)} />
        </Field>
        <Field label="Échéance"><Input readOnly value={d > 0 ? fdate(ajouterMois(jour, d)) : ''} /></Field>
        <Field label="Intérêts à l'échéance"><Input readOnly value={interets ? xof(interets) : ''} /></Field>
        <Button variant="primary" disabled={!pret}
          onClick={() => void run(async () => { const r = await api.post<{ piece_id: number | null }>('/api/depots/terme', { compte_id: c!.id, montant: m, duree_mois: d, taux_annuel: taux === '' ? null : t / 100, date: jour }); piece.ouvrir(r.piece_id) },
            'Dépôt à terme enregistré', () => { setSuffixe(''); setMontant(''); setDuree(''); setTaux(''); window.dispatchEvent(new Event('depots-maj')); setTimeout(() => refNumero.current?.focus(), 0) })}>Valider le placement</Button>
      </div>
      {horsMin && p && <Alert tone="bad">Montant inférieur au minimum d'un dépôt à terme ({xof(p.montant_min)}).</Alert>}
      {courte && p && <Alert tone="bad">Durée inférieure au minimum ({p.duree_min_mois} mois).</Alert>}
      {trop && c && <Alert tone="bad">Montant supérieur au disponible du compte ({xof(c.disponible)}).</Alert>}
      {piece.modal}
    </>
  )
}

function useRafraichissement() {
  const [n, setN] = useState(0)
  useEffect(() => { const f = () => setN((x) => x + 1); window.addEventListener('depots-maj', f); return () => window.removeEventListener('depots-maj', f) }, [])
  return n
}

function ListeGarantiesDuJour({ jour }: { jour: string }) {
  const n = useRafraichissement()
  const q = useFetch(() => api.get<Garantie[]>('/api/depots/garanties', { date: jour }), [jour, n])
  const [filtre, setFiltre] = useState('')
  return (
    <Charge q={q}>
      {(rows) => (
        <Card title={`Dépôts de garantie du ${fdate(jour)}`} flush>
          <div className="grid-kpi" style={{ padding: '0 16px' }}>
            <Kpi label="Total bloqué ce jour" value={xof(rows.reduce((s, r) => s + r.montant, 0))} />
            <Kpi label="Dépôts" value={rows.length} />
          </div>
          <FiltreTableau valeur={filtre} onChange={setFiltre} />
          <Table rows={filtrer(rows, filtre, (r) => [r.client, r.client_numero, r.compte, r.numero])} vide={filtre ? 'Aucun dépôt ne correspond au filtre' : 'Aucun dépôt de garantie ce jour'} cols={[
            { titre: 'N°', render: (r) => r.numero },
            { titre: 'Client', render: (r) => <><strong>{r.client}</strong><div className="muted">{r.client_numero}</div></> },
            { titre: 'Compte', render: (r) => r.compte },
            { titre: 'Crédit', render: (r) => r.credit ?? '—' },
            { titre: 'Motif', render: (r) => r.motif ?? '' },
            { titre: 'Montant', num: true, render: (r) => xof(r.montant) },
            { titre: 'Statut', render: (r) => (r.statut === 'bloque' ? <Badge tone="warn">Bloqué</Badge> : <Badge tone="ok">Libéré</Badge>) },
          ]} />
        </Card>
      )}
    </Charge>
  )
}

function ListeTermesDuJour({ jour }: { jour: string }) {
  const n = useRafraichissement()
  const q = useFetch(() => api.get<Terme[]>('/api/depots/terme', { date: jour }), [jour, n])
  const [filtre, setFiltre] = useState('')
  return (
    <Charge q={q}>
      {(rows) => (
        <Card title={`Dépôts à terme du ${fdate(jour)}`} flush>
          <div className="grid-kpi" style={{ padding: '0 16px' }}>
            <Kpi label="Total placé ce jour" value={xof(rows.reduce((s, r) => s + r.montant, 0))} />
            <Kpi label="Dépôts" value={rows.length} />
          </div>
          <FiltreTableau valeur={filtre} onChange={setFiltre} />
          <Table rows={filtrer(rows, filtre, (r) => [r.client, r.client_numero, r.compte, r.numero])} vide={filtre ? 'Aucun dépôt ne correspond au filtre' : 'Aucun dépôt à terme ce jour'} cols={[
            { titre: 'N°', render: (r) => r.numero },
            { titre: 'Client', render: (r) => <><strong>{r.client}</strong><div className="muted">{r.client_numero}</div></> },
            { titre: 'Compte', render: (r) => r.compte },
            { titre: 'Montant', num: true, render: (r) => xof(r.montant) },
            { titre: 'Durée', render: (r) => `${r.duree_mois} mois à ${Math.round(Number(r.taux_annuel) * 10000) / 100} %` },
            { titre: 'Échéance', render: (r) => fdate(r.date_echeance) },
            { titre: 'Intérêts prévus', num: true, render: (r) => xof(r.interets_prevus) },
          ]} />
        </Card>
      )}
    </Charge>
  )
}
