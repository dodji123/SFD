import { useRef, useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, xof } from '../lib/format'
import { useProduitsEpargne } from '../lib/hooks'
import { useRecherche } from '../lib/recherche'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, Input, Kpi, Page, Select, Table, useAction, useFetch } from '../components/ui'

interface CompteMembre {
  id: number; numero: string; statut: string; produit: string; solde: number
  adhesion_numero: string | null; date_adhesion: string | null; adhesion_statut: string | null; nb_parts: number | null; capital_souscrit: number | null
  en_regle: boolean; rembourse_parts: number | null; rembourse_montant: number | null; rembourse_le: string | null
}
interface Situation {
  client: { id: number; numero: string; nom: string }; comptes: CompteMembre[]
  valeur_part: number; parts_minimum: number; droit_adhesion: number; obligatoire: boolean
}
interface Jour { total: number; lignes: { nature: 'adhesion' | 'parts'; id: number; client_numero: string; client: string; compte: string | null; reference: string; montant: number; nb_parts: number | null }[] }

export default function Adhesion() {
  const { can, agenceId } = useSession()
  const [jour, setJour] = useState(aujourdhui())
  const [suffixe, setSuffixe] = useState('')
  const refNumero = useRef<HTMLInputElement>(null)
  const tableau = useFetch(() => api.get<Jour>('/api/adhesions/jour', { date: jour }), [jour, agenceId])
  const { data: s, erreur, recharger } = useRecherche<Situation>('/api/adhesions/recherche', suffixe ? { suffixe } : null)
  const apres = () => { recharger(); tableau.reload() }

  return (
    <Page title="Adhésion et parts sociales" subtitle="Chaque compte d'épargne a sa propre adhésion et sa souscription de parts : un client qui ouvre un second compte adhère à nouveau pour ce compte">
      {can('adhesion:write') && (
        <Card title="Compte, adhésion et parts">
          <div className="row">
            <Field label="Jour"><Input type="date" max={aujourdhui()} value={jour} onChange={(e) => setJour(e.target.value || aujourdhui())} /></Field>
            <Field label="N° client" hint="Numéro d'ordre seul (ex. 5)">
              <Input ref={refNumero} inputMode="numeric" value={suffixe} placeholder="5" autoComplete="off" onChange={(e) => setSuffixe(e.target.value.replace(/\D/g, ''))} />
            </Field>
            <Field label="Numéro de base du client"><Input readOnly value={s?.client.numero ?? ''} /></Field>
            <Field label="Nom et prénom"><Input readOnly value={s?.client.nom ?? ''} /></Field>
          </div>
          {erreur && <Alert tone="warn">{erreur}</Alert>}
          {s && (
            <>
              <div className="grid-kpi">
                <Kpi label="Valeur d'une part" value={xof(s.valeur_part)} />
                <Kpi label="Parts minimum par compte" value={s.parts_minimum} />
                <Kpi label="Droit d'adhésion" value={xof(s.droit_adhesion)} />
                <Kpi label="Comptes du client" value={s.comptes.length} />
              </div>
              {s.comptes.map((c) => <CompteCarte key={c.id} c={c} s={s} jour={jour} onFait={apres} peutSortir={can('collecte:admin')} />)}
              <NouveauCompte s={s} onFait={() => { setSuffixe(''); tableau.reload(); setTimeout(() => refNumero.current?.focus(), 0) }} />
            </>
          )}
        </Card>
      )}
      <Charge q={tableau}>
        {(d) => (
          <Card title={`Adhésions et parts du ${jour.split('-').reverse().join('/')}`} flush>
            <div className="grid-kpi" style={{ padding: '0 16px' }}>
              <Kpi label="Total encaissé" value={xof(d.total)} />
              <Kpi label="Opérations" value={d.lignes.length} />
            </div>
            <Table rows={d.lignes} vide="Aucune adhésion ni souscription ce jour" cols={[
              { titre: 'N° client', render: (l) => l.client_numero },
              { titre: 'Client', render: (l) => <strong>{l.client}</strong> },
              { titre: 'Compte', render: (l) => l.compte ?? '—' },
              { titre: 'Nature', render: (l) => (l.nature === 'adhesion' ? <Badge tone="ok">Adhésion</Badge> : <Badge tone="info">{l.nb_parts} part(s)</Badge>) },
              { titre: 'Réf. adhésion', render: (l) => l.reference },
              { titre: 'Montant', num: true, render: (l) => xof(l.montant) },
            ]} />
          </Card>
        )}
      </Charge>
    </Page>
  )
}

function CompteCarte({ c, s, jour, onFait, peutSortir }: { c: CompteMembre; s: Situation; jour: string; onFait: () => void; peutSortir: boolean }) {
  const { run, busy } = useAction()
  const [nb, setNb] = useState(String(Math.max(s.parts_minimum - (c.nb_parts ?? 0), 1)))
  const n = Number(nb)
  const radiee = c.adhesion_statut === 'radiee'
  return (
    <div style={{ padding: '12px 0', borderTop: '1px solid var(--line, #e5e7eb)' }}>
      <div className="row">
        <Field label="Compte"><Input readOnly value={`${c.numero} — ${c.produit}`} /></Field>
        <Field label="Solde"><Input readOnly value={xof(c.solde)} /></Field>
        <Field label="Adhésion"><Input readOnly value={c.adhesion_numero ? `${c.adhesion_numero} (${radiee ? 'radiée' : 'active'})` : 'aucune'} /></Field>
        <Field label="Parts / capital"><Input readOnly value={c.adhesion_numero ? `${c.nb_parts} part(s) — ${xof(c.capital_souscrit ?? 0)}` : '—'} /></Field>
        {c.en_regle ? <Badge tone="ok">En règle</Badge> : c.statut === 'clos' ? <Badge tone="warn">Compte clos</Badge> : <Badge tone="bad">Pas en règle</Badge>}
      </div>
      {radiee && c.rembourse_montant !== null && <Alert tone="info">Sortie le {c.rembourse_le?.split('-').reverse().join('/')} : {xof(c.rembourse_montant)} de parts remboursés ({c.rembourse_parts} part(s)).</Alert>}
      {!c.adhesion_numero && c.statut !== 'clos' && (
        <div className="row">
          <Alert tone="info">Ce compte n'a pas d'adhésion. Droit d'adhésion à encaisser : {xof(s.droit_adhesion)}.</Alert>
          <Button variant="primary" disabled={busy} onClick={() => void run(() => api.post('/api/adhesions', { compte_id: c.id, date: jour }), 'Adhésion enregistrée', onFait)}>Enregistrer l'adhésion</Button>
        </div>
      )}
      {c.adhesion_numero && !radiee && (
        <div className="row">
          <Field label="Parts à souscrire" hint={`Montant : ${xof(n > 0 ? n * s.valeur_part : 0)}`}>
            <Input type="number" min={1} value={nb} aria-label={`Nombre de parts ${c.numero}`} onChange={(e) => setNb(e.target.value)} />
          </Field>
          <Button variant="primary" disabled={busy || !(n > 0)} onClick={() => void run(() => api.post('/api/adhesions/parts', { compte_id: c.id, nb_parts: n, date: jour }), 'Parts souscrites', onFait)}>Valider la souscription</Button>
          {peutSortir && <Button variant="danger" disabled={busy}
            onClick={() => { if (window.confirm(`Sortie du compte ${c.numero} : ${xof(c.capital_souscrit ?? 0)} de parts seront remboursés, l'adhésion radiée et le compte clos. Continuer ?`)) void run(() => api.post('/api/adhesions/sortie', { compte_id: c.id, date: jour }), 'Parts remboursées, compte clos', onFait) }}>Sortie du compte</Button>}
        </div>
      )}
    </div>
  )
}

function NouveauCompte({ s, onFait }: { s: Situation; onFait: () => void }) {
  const produits = useProduitsEpargne('classique')
  const { run, busy } = useAction()
  const [produit, setProduit] = useState('')
  const [nb, setNb] = useState(String(s.parts_minimum))
  const n = Number(nb)
  return (
    <div style={{ padding: '12px 0', borderTop: '1px solid var(--line, #e5e7eb)' }}>
      <strong>Ouvrir un nouveau compte (avec son adhésion et ses parts)</strong>
      <div className="row">
        <Field label="Produit d'épargne">
          <Select value={produit} onChange={(e) => setProduit(e.target.value)}>
            <option value="">— choisir un produit —</option>
            {produits.map((p) => <option key={p.id} value={p.id}>{p.code} — {p.libelle}</option>)}
          </Select>
        </Field>
        <Field label="Parts à souscrire" hint={`Montant : ${xof(n > 0 ? n * s.valeur_part : 0)} + droit d'adhésion ${xof(s.droit_adhesion)}`}>
          <Input type="number" min={s.parts_minimum} value={nb} aria-label="Parts du nouveau compte" onChange={(e) => setNb(e.target.value)} />
        </Field>
        <Button variant="primary" disabled={busy || !produit || n < s.parts_minimum}
          onClick={() => void run(() => api.post('/api/comptes-epargne', { client_id: s.client.id, produit_id: Number(produit), nb_parts: n }), "Compte ouvert avec son adhésion", onFait)}>Ouvrir le compte</Button>
      </div>
    </div>
  )
}
