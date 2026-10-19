import { useState } from 'react'
import { api } from '../lib/api'
import { telechargerCsv } from '../lib/csv'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, Input, Kpi, Page, Tabs, useFetch } from '../components/ui'
import { RatiosPrudentiels, Reglementaire } from './EtatsReglementaires'
import Rapprochement from './Rapprochement'

interface Colonnes { [agence: string]: number }
interface LigneCompte { code: string; libelle: string; par_agence: Colonnes; total?: number; montant?: number }
interface Resultat {
  produits: LigneCompte[]; charges: LigneCompte[]
  total_produits: Colonnes; total_charges: Colonnes; resultat: Colonnes
}
interface Bilan { actif: LigneCompte[]; passif: LigneCompte[]; total_actif: number; total_passif: number }
interface Agence { id: number; code: string; libelle: string }
interface EtatsAgence { agence: Agence; compte_resultat: Resultat; bilan: Bilan }
interface Synthese { agence_id: number; agence: string; produits: number; charges: number; resultat: number; total_actif: number; total_passif: number; ecart: number }
interface EtatsConsolides {
  agences: Agence[]; synthese: Synthese[]; compte_resultat: Resultat; bilan: Bilan
  consolide: { produits: number; charges: number; resultat: number; total_actif: number; total_passif: number }
  controles: { bilan_equilibre: boolean; agences_equilibrees: boolean; resultat_coherent: boolean }
  rapprochement: { toutes_validees: boolean; agences_non_validees: string[]; agences_avec_ecart: string[] }
}

const AN = new Date().getFullYear()

export default function Etats() {
  const { agenceId, can, user } = useSession()
  const [du, setDu] = useState(`${AN}-01-01`)
  const [au, setAu] = useState(aujourdhui())
  const [onglet, setOnglet] = useState('agence')
  const consolide = can('etats:consolide') && user?.agence_id === null
  const [reseau, setReseau] = useState(false)
  return (
    <Page title="États financiers" subtitle="Compte de résultat de la période et bilan à la date de fin, issus des écritures comptables"
      actions={<><Field label="Du"><Input type="date" value={du} onChange={(e) => setDu(e.target.value || du)} /></Field>
        <Field label="Au"><Input type="date" value={au} onChange={(e) => setAu(e.target.value || au)} /></Field>
        <Button onClick={() => window.print()}>Imprimer</Button></>}>
      <Tabs actif={onglet} onChange={setOnglet} tabs={[
        { id: 'agence', titre: 'Par agence' }, { id: 'reglementaire', titre: 'États réglementaires' }, { id: 'ratios', titre: 'Ratios prudentiels' }, { id: 'rapprochement', titre: 'Rapprochement compta' },
        ...(consolide ? [{ id: 'consolide', titre: 'Consolidé du réseau' }] : []),
      ]} />
      {consolide && (onglet === 'reglementaire' || onglet === 'ratios' || onglet === 'rapprochement') && (
        <label className="actions"><input type="checkbox" checked={reseau} onChange={(e) => setReseau(e.target.checked)} /> Réseau entier (consolidé) au lieu de l'agence choisie</label>
      )}
      {onglet === 'consolide' && consolide && <Consolide key={`${du}${au}`} du={du} au={au} />}
      {onglet === 'agence' && <ParAgence key={`${du}${au}${agenceId}`} du={du} au={au} />}
      {onglet === 'reglementaire' && <Reglementaire key={`${du}${au}${agenceId}${reseau}`} du={du} au={au} consolide={reseau && consolide} />}
      {onglet === 'rapprochement' && <Rapprochement key={`${au}${agenceId}${reseau}`} au={au} consolide={reseau && consolide} />}
      {onglet === 'ratios' && <RatiosPrudentiels key={`${au}${agenceId}${reseau}`} au={au} consolide={reseau && consolide} />}
      <Alert tone="warn">Documents de travail issus des écritures (soldes par compte de niveau 2), pas des états réglementaires. Un résultat négatif figure à l'actif du bilan. Le bilan suppose que toutes les opérations sont comptabilisées : activer la comptabilisation automatique ou saisir les pièces.</Alert>
    </Page>
  )
}

function Ligne({ l, cols }: { l: LigneCompte; cols: string[] }) {
  return (
    <tr>
      <td>{l.code}</td><td>{l.libelle}</td>
      {cols.map((c) => <td key={c} className="num">{xof(l.par_agence[c] ?? 0)}</td>)}
      {cols.length > 1 && <td className="num"><strong>{xof(l.total ?? l.montant ?? 0)}</strong></td>}
    </tr>
  )
}

function Totaux({ titre, v, cols }: { titre: string; v: Colonnes; cols: string[] }) {
  return (
    <tr>
      <td colSpan={2}><strong>{titre}</strong></td>
      {cols.map((c) => <td key={c} className="num"><strong>{xof(v[c] ?? 0)}</strong></td>)}
      {cols.length > 1 && <td className="num"><strong>{xof(v.total ?? 0)}</strong></td>}
    </tr>
  )
}

function Tableau({ cols, entetes, children }: { cols: string[]; entetes: string[]; children: React.ReactNode }) {
  return (
    <div className="table-wrap"><table className="t">
      <thead><tr><th>Compte</th><th>Libellé</th>{entetes.map((e) => <th key={e} className="num">{e}</th>)}{cols.length > 1 && <th className="num">Total réseau</th>}</tr></thead>
      <tbody>{children}</tbody>
    </table></div>
  )
}

function ResultatTable({ r, ids, entetes }: { r: Resultat; ids: string[]; entetes: string[] }) {
  return (
    <Card title="Compte de résultat" flush>
      <Tableau cols={ids} entetes={entetes}>
        <tr><td colSpan={ids.length + 3}><strong>Produits</strong></td></tr>
        {r.produits.map((l) => <Ligne key={'p' + l.code} l={l} cols={ids} />)}
        <Totaux titre="Total des produits" v={r.total_produits} cols={ids} />
        <tr><td colSpan={ids.length + 3}><strong>Charges</strong></td></tr>
        {r.charges.map((l) => <Ligne key={'c' + l.code} l={l} cols={ids} />)}
        <Totaux titre="Total des charges" v={r.total_charges} cols={ids} />
        <Totaux titre="Résultat de la période" v={r.resultat} cols={ids} />
      </Tableau>
    </Card>
  )
}

/** Les soldes des agences sont signés (débit - crédit) : positif à l'actif, négatif au passif. */
function BilanTables({ b, ids, entetes }: { b: Bilan; ids: string[]; entetes: string[] }) {
  const orienter = (rows: LigneCompte[], f: number) => rows.map((r) => ({ ...r, par_agence: Object.fromEntries(Object.entries(r.par_agence).map(([k, v]) => [k, (v * f) || 0])) }))
  const colonnes = (rows: LigneCompte[], f: number, total: number): Colonnes => ({
    ...Object.fromEntries(ids.map((i) => [i, (f * rows.reduce((s, r) => s + (r.par_agence[i] ?? 0), 0)) || 0])), total,
  })
  return (
    <div className="grid-2">
      <Card title="Actif" flush>
        <Tableau cols={ids} entetes={entetes}>
          {orienter(b.actif, 1).map((l) => <Ligne key={l.code} l={l} cols={ids} />)}
          <Totaux titre="Total actif" v={colonnes(b.actif, 1, b.total_actif)} cols={ids} />
        </Tableau>
      </Card>
      <Card title="Passif" flush>
        <Tableau cols={ids} entetes={entetes}>
          {orienter(b.passif, -1).map((l) => <Ligne key={l.code} l={l} cols={ids} />)}
          <Totaux titre="Total passif" v={colonnes(b.passif, -1, b.total_passif)} cols={ids} />
        </Tableau>
      </Card>
    </div>
  )
}

function ParAgence({ du, au }: { du: string; au: string }) {
  const q = useFetch(() => api.get<EtatsAgence>('/api/etats/agence', { du, au }), [du, au])
  return (
    <Charge q={q}>
      {(d) => {
        const id = String(d.agence.id)
        const res = d.compte_resultat.resultat[id] ?? 0
        return (
          <div className="stack">
            <div className="grid-kpi">
              <Kpi label="Produits" value={xof(d.compte_resultat.total_produits[id] ?? 0)} />
              <Kpi label="Charges" value={xof(d.compte_resultat.total_charges[id] ?? 0)} />
              <Kpi label="Résultat de la période" value={xof(res)} tone={res < 0 ? 'bad' : undefined} />
              <Kpi label="Total du bilan" value={xof(d.bilan.total_actif)} />
            </div>
            <ResultatTable r={d.compte_resultat} ids={[id]} entetes={[d.agence.code]} />
            <BilanTables b={d.bilan} ids={[id]} entetes={[d.agence.code]} />
            <div className="actions">
              {d.bilan.total_actif === d.bilan.total_passif ? <Badge tone="ok">Bilan équilibré</Badge> : <Badge tone="bad">Bilan déséquilibré</Badge>}
              <Button small onClick={() => telechargerCsv(`etats-${d.agence.code}-${du}-${au}`, ['État', 'Compte', 'Libellé', 'Montant'], [
                ...d.compte_resultat.produits.map((l) => ['Produit', l.code, l.libelle, l.total]),
                ...d.compte_resultat.charges.map((l) => ['Charge', l.code, l.libelle, l.total]),
                ...d.bilan.actif.map((l) => ['Actif', l.code, l.libelle, l.montant]),
                ...d.bilan.passif.map((l) => ['Passif', l.code, l.libelle, l.montant]),
              ])}>Exporter en CSV</Button>
              <span className="muted">Période du {fdate(du)} au {fdate(au)} · agence {d.agence.libelle}</span>
            </div>
          </div>
        )
      }}
    </Charge>
  )
}

function Consolide({ du, au }: { du: string; au: string }) {
  const q = useFetch(() => api.get<EtatsConsolides>('/api/etats/consolide', { du, au }), [du, au])
  return (
    <Charge q={q}>
      {(d) => {
        const ids = d.agences.map((a) => String(a.id))
        const entetes = d.agences.map((a) => a.code)
        const ok = d.controles.bilan_equilibre && d.controles.agences_equilibrees && d.controles.resultat_coherent
        return (
          <div className="stack">
            <div className="grid-kpi">
              <Kpi label="Produits du réseau" value={xof(d.consolide.produits)} />
              <Kpi label="Charges du réseau" value={xof(d.consolide.charges)} />
              <Kpi label="Résultat consolidé" value={xof(d.consolide.resultat)} tone={d.consolide.resultat < 0 ? 'bad' : undefined} />
              <Kpi label="Total du bilan consolidé" value={xof(d.consolide.total_actif)} />
            </div>
            {!d.rapprochement.toutes_validees && <Alert tone="warn">Rapprochement fiches / comptabilité non validé au {fdate(au)} pour : {d.rapprochement.agences_non_validees.join(', ')}. Les chiffres consolidés reposent sur des comptabilités non rapprochées (onglet « Rapprochement compta »).</Alert>}
            {d.rapprochement.agences_avec_ecart.length > 0 && <Alert tone="info">Écart justifié par le comptable pour : {d.rapprochement.agences_avec_ecart.join(', ')}.</Alert>}
            <Card title="Synthèse par agence" flush>
              <div className="table-wrap"><table className="t">
                <thead><tr><th>Agence</th><th className="num">Produits</th><th className="num">Charges</th><th className="num">Résultat</th><th className="num">Total actif</th><th className="num">Total passif</th><th>Contrôle</th></tr></thead>
                <tbody>
                  {d.synthese.map((s) => (
                    <tr key={s.agence_id}><td><strong>{s.agence}</strong></td><td className="num">{xof(s.produits)}</td><td className="num">{xof(s.charges)}</td>
                      <td className="num">{xof(s.resultat)}</td><td className="num">{xof(s.total_actif)}</td><td className="num">{xof(s.total_passif)}</td>
                      <td>{s.ecart === 0 ? <Badge tone="ok">Équilibrée</Badge> : <Badge tone="bad">Écart {xof(s.ecart)}</Badge>}</td></tr>
                  ))}
                  <tr><td><strong>Réseau</strong></td><td className="num"><strong>{xof(d.consolide.produits)}</strong></td><td className="num"><strong>{xof(d.consolide.charges)}</strong></td>
                    <td className="num"><strong>{xof(d.consolide.resultat)}</strong></td><td className="num"><strong>{xof(d.consolide.total_actif)}</strong></td>
                    <td className="num"><strong>{xof(d.consolide.total_passif)}</strong></td><td>{ok ? <Badge tone="ok">Cohérent</Badge> : <Badge tone="bad">À vérifier</Badge>}</td></tr>
                </tbody>
              </table></div>
            </Card>
            <ResultatTable r={d.compte_resultat} ids={ids} entetes={entetes} />
            <BilanTables b={d.bilan} ids={ids} entetes={entetes} />
            <Alert tone="info">Consolidation = somme des agences. Aucune écriture inter-agences n'existe : le transfert d'un client entre agences n'en passe pas, le règlement de l'épargne déplacée reste à saisir par le comptable.</Alert>
            <div className="actions"><Button small onClick={() => telechargerCsv(`etats-consolides-${du}-${au}`, ['État', 'Compte', 'Libellé', ...entetes, 'Total'], [
              ...d.compte_resultat.produits.map((l) => ['Produit', l.code, l.libelle, ...ids.map((i) => l.par_agence[i] ?? 0), l.total]),
              ...d.compte_resultat.charges.map((l) => ['Charge', l.code, l.libelle, ...ids.map((i) => l.par_agence[i] ?? 0), l.total]),
              ...d.bilan.actif.map((l) => ['Actif', l.code, l.libelle, ...ids.map((i) => l.par_agence[i] ?? 0), l.montant]),
              ...d.bilan.passif.map((l) => ['Passif', l.code, l.libelle, ...ids.map((i) => -(l.par_agence[i] ?? 0)), l.montant]),
            ])}>Exporter en CSV</Button></div>
          </div>
        )
      }}
    </Charge>
  )
}
