import { useEffect, useMemo, useState } from 'react'
import { api } from '../lib/api'
import { date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Field, Input, Kpi, Modal, Select, Tabs, useAction, useFetch } from './ui'

type Categorie = 'activite' | 'menage' | 'dette'
interface Charge { libelle: string; categorie: Categorie; montant: number; periode: string }
interface Garantie { libelle: string; type: string; valeur: number; decote: number }
interface Scenario { libelle: string; montant: number; nb_echeances: number; taux: number; methode: string; differe: number }
interface Membre { nom: string; montant: number; disponible: number }
interface Dossier {
  secteur: string | null; anciennete_mois: number; jours_activite: number; ventes_mensuelles: number; achats_mensuels: number; autres_revenus: number
  charges: Charge[]; cycle: number; caution: string; historique: string; garanties: Garantie[]; ventes_par_mois: number[] | null; scenarios: Scenario[]; groupe: Membre[]
}
interface MoisRes { ventes: number; disponible: number; apres_charge: number }
interface EcheanceMois { mois: number; a_payer: number; capital: number; interets: number; solde: number }
interface ScenarioRes { libelle: string; montant: number; nb_echeances: number; taux_annuel: number; methode: string; differe: number; charge_mensuelle: number; mise_journaliere: number
  taux_endettement: number | null; couverture: number | null; baisse_ventes_tolere: number; teg: number; cout_total: number; score: number; avis: string; niveau: string; meilleur: boolean }
interface MembreRes { nom: string; montant: number; disponible: number; charge_mensuelle: number; couverture: number | null; montant_max: number; niveau: string; hors_plafond: boolean }
interface GroupeRes { membres: MembreRes[]; total_montant: number; total_charge: number; total_disponible: number; couverture_groupe: number | null; avis: string | null; alertes: string[]; plafond_cycle: number }
export interface Resultat {
  marge_brute: number; ventes_moyennes: number; charges_activite: number; charges_menage: number; dettes_externes: number; dettes_internes: number; dettes_en_cours: number
  excedent_activite: number; revenus: number; revenu_disponible: number; echeance_periode: number; charge_mensuelle: number; interets_total: number
  frais: number; cout_total: number; total_a_rembourser: number; teg: number; mise_journaliere: number
  taux_endettement: number | null; couverture: number | null; couverture_effective: number | null; surplus: number; baisse_ventes_tolere: number
  montant_max_conseille: number; plafond_cycle: number; depasse_plafond: boolean; garanties_brutes: number; garanties_retenues: number; couverture_garanties: number
  score: number; avis: string; niveau: string; sous_scores: Record<string, number>; poids: number[]
  mois: MoisRes[] | null; pire_mois: number | null; nb_mois_defaut: number; echeancier_mensuel: EcheanceMois[]
  endettement_max_pct: number; couverture_min: number; garantie_min_pct: number
  conforme_endettement: boolean; conforme_couverture: boolean; conforme_garanties: boolean; conforme: boolean; alertes: string[]
  scenarios?: ScenarioRes[]; groupe?: GroupeRes
}
interface Politique { max_dti: number; min_couv: number; min_gar: number; poids: number[]; seuils: number[]; plafonds: number[] }
interface Lecture { analyse: (Dossier & { resultat: Resultat; utilisateur: string | null; ventes_mensuelles: number; achats_mensuels: number; autres_revenus: number }) | null; demande_statut: string; endettement_max_pct: number; couverture_min: number; politique: Politique }
interface Institution { raison_sociale: string; sigle: string | null; agrement: string | null; immatriculation: string | null; adresse: string | null; ville: string | null; telephone: string | null; email: string | null; logo: string | null; pied_de_page: string | null }
export interface DemandeInfo { id: number; numero: string; client: string; produit: string; montant: number; nb_echeances: number; taux: number }

const PERIODES: Record<string, string> = { jourouvre: 'Par jour travaillé', jour7: 'Par jour (7j/7)', semaine: 'Par semaine', mois: 'Par mois', trimestre: 'Par trimestre', semestre: 'Par semestre', an: 'Par an' }
const CATEGORIES: Record<string, string> = { activite: 'Activité', menage: 'Ménage', dette: 'Dette en cours' }
const GARANTIES: Record<string, string> = { terrain: 'Terrain / titre foncier', batiment: 'Bâtiment', vehicule: 'Véhicule / moto', stock: 'Stock de marchandises', materiel: 'Matériel / équipement', betail: 'Bétail', epargne: 'Épargne bloquée', autre: 'Autre' }
const DECOTES: Record<string, number> = { terrain: 30, batiment: 30, vehicule: 40, stock: 50, materiel: 50, betail: 50, epargne: 0, autre: 50 }
const SECTEURS: Record<string, string> = { commerce: 'Commerce', agriculture: 'Agriculture', elevage: 'Élevage', artisanat: 'Artisanat / production', transport: 'Transport', services: 'Services' }
const CAUTIONS: Record<string, string> = { aucune: 'Aucune caution', perso: 'Caution personnelle', groupe: 'Groupe solidaire' }
const HISTORIQUES: Record<string, string> = { nouveau: 'Nouveau client', bon: 'Crédits précédents remboursés à temps', mineur: 'Retards occasionnels', grave: 'Impayés ou contentieux' }
const METHODES: Record<string, string> = { capital_constant: 'Capital constant', annuite_constante: 'Annuités constantes', plat: 'Taux plat', infine: 'In fine' }
const MOIS = ['Jan', 'Fév', 'Mar', 'Avr', 'Mai', 'Juin', 'Juil', 'Août', 'Sep', 'Oct', 'Nov', 'Déc']
const VIDE: Dossier = { secteur: null, anciennete_mois: 0, jours_activite: 26, ventes_mensuelles: 0, achats_mensuels: 0, autres_revenus: 0, charges: [], cycle: 1, caution: 'perso', historique: 'bon', garanties: [], ventes_par_mois: null, scenarios: [], groupe: [] }
const pct = (v: number | null | undefined, d = 1) => (v === null || v === undefined ? '—' : `${(v * 100).toFixed(d).replace('.', ',')} %`)
const cx = (v: number | null | undefined) => (v === null || v === undefined ? '—' : `${v.toFixed(2).replace('.', ',')} ×`)
const tonAvis = (niveau: string) => (niveau === 'bon' ? 'ok' : niveau === 'moyen' ? 'warn' : 'bad')
const couleur = (niveau: string) => (niveau === 'bon' ? 'var(--good, #1f8a4c)' : niveau === 'moyen' ? 'var(--warn, #b7791f)' : 'var(--bad, #c0392b)')
const niveauMembre = (n: string) => (n === 'bon' ? 'Suffisante' : n === 'limite' ? 'Limite' : 'Insuffisante')

/** Résumé compact de l'analyse d'une demande, pour la fenêtre de décision. */
export function ResumeAnalyse({ demandeId }: { demandeId: number }) {
  const q = useFetch(() => api.get<Lecture>(`/api/demandes-credit/${demandeId}/analyse`), [demandeId])
  if (!q.data) return null
  const a = q.data.analyse
  if (!a) return <Alert tone="warn">Aucune analyse de capacité de remboursement pour cette demande (taux d'endettement et couverture non évalués).</Alert>
  const r = a.resultat
  return (
    <Alert tone={r.niveau === 'bon' && r.conforme ? 'info' : 'warn'}>
      Analyse de capacité : avis <b>{r.avis}</b> (score {Math.round(r.score)}/100). Endettement {pct(r.taux_endettement)} (max {q.data.endettement_max_pct} %), couverture {cx(r.couverture)} (min {q.data.couverture_min}),
      mise journalière {xof(r.mise_journaliere)}, montant conseillé {xof(r.montant_max_conseille)}. {r.alertes.length ? 'Points d\'attention : ' + r.alertes.join(' ') : 'Aucun point d\'attention.'}
    </Alert>
  )
}

/** Analyse de capacité de remboursement complète : dossier, résultats, scénarios, groupe solidaire et rapport imprimable. */
export function AnalyseCapacite({ demande, onClose }: { demande: DemandeInfo; onClose: () => void }) {
  const { can } = useSession()
  const lecture = useFetch(() => api.get<Lecture>(`/api/demandes-credit/${demande.id}/analyse`), [demande.id])
  const [f, setF] = useState<Dossier>(VIDE)
  const [res, setRes] = useState<Resultat | null>(null)
  const [erreur, setErreur] = useState<string | null>(null)
  const [onglet, setOnglet] = useState('dossier')
  const [saisonnier, setSaisonnier] = useState(false)
  const { run, busy } = useAction()
  const editable = can('credit:request') && lecture.data?.demande_statut === 'demandee'

  useEffect(() => {
    const a = lecture.data?.analyse
    if (!a) return
    setF({ secteur: a.secteur, anciennete_mois: a.anciennete_mois, jours_activite: a.jours_activite, ventes_mensuelles: Number(a.ventes_mensuelles), achats_mensuels: Number(a.achats_mensuels),
      autres_revenus: Number(a.autres_revenus), charges: a.charges, cycle: a.cycle, caution: a.caution, historique: a.historique, garanties: a.garanties,
      ventes_par_mois: a.ventes_par_mois, scenarios: (a.scenarios ?? []).map((s) => ({ ...s })), groupe: a.groupe ?? [] })
    setSaisonnier(!!a.ventes_par_mois)
  }, [lecture.data])

  // calcul en direct (différé de 300 ms)
  useEffect(() => {
    let ok = true
    const t = setTimeout(() => {
      api.post<Resultat>(`/api/demandes-credit/${demande.id}/analyse/simuler`, f).then((r) => { if (ok) { setRes(r); setErreur(null) } }).catch((e: Error) => ok && setErreur(e.message))
    }, 300)
    return () => { ok = false; clearTimeout(t) }
  }, [f, demande.id])

  const num = (k: keyof Dossier) => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...f, [k]: Math.max(0, Number(e.target.value) || 0) })
  const maj = <K extends 'charges' | 'garanties' | 'scenarios' | 'groupe'>(k: K, i: number, p: Partial<Dossier[K][number]>) =>
    setF({ ...f, [k]: (f[k] as unknown[]).map((x, n) => (n === i ? { ...(x as object), ...p } : x)) } as Dossier)
  const retirer = (k: 'charges' | 'garanties' | 'scenarios' | 'groupe', i: number) => setF({ ...f, [k]: (f[k] as unknown[]).filter((_, n) => n !== i) } as Dossier)
  const moyenne = f.ventes_par_mois ? f.ventes_par_mois.reduce((s, v) => s + v, 0) / 12 : f.ventes_mensuelles

  function basculerSaison(on: boolean) {
    setSaisonnier(on)
    setF({ ...f, ventes_par_mois: on ? Array.from({ length: 12 }, () => f.ventes_mensuelles) : null })
  }

  return (
    <Modal titre={`Analyse de capacité — ${demande.client}`} onClose={onClose} large
      footer={<><Button onClick={onClose}>Fermer</Button>{editable && <Button variant="primary" disabled={busy || !!erreur}
        onClick={() => void run(() => api.put(`/api/demandes-credit/${demande.id}/analyse`, f), 'Analyse enregistrée sur la demande', lecture.reload)}>Enregistrer l'analyse</Button>}</>}>
      {lecture.data && !editable && <Alert tone="info">{lecture.data.demande_statut !== 'demandee' ? 'La demande est décidée : l\'analyse est figée.' : 'Lecture seule.'}</Alert>}
      {res && <BandeauAvis r={res} />}
      <Tabs actif={onglet} onChange={setOnglet} tabs={[{ id: 'dossier', titre: 'Dossier' }, { id: 'resultats', titre: 'Résultats' }, { id: 'scenarios', titre: 'Scénarios' }, { id: 'groupe', titre: 'Groupe solidaire' }, { id: 'rapport', titre: 'Rapport' }]} />
      {erreur && <Alert tone="bad">{erreur}</Alert>}

      {onglet === 'dossier' && (
        <>
          <div className="row">
            <Field label="Secteur"><Select value={f.secteur ?? ''} disabled={!editable} onChange={(e) => setF({ ...f, secteur: e.target.value || null })}><option value="">—</option>{Object.entries(SECTEURS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
            <Field label="Ancienneté de l'activité (mois)"><Input type="number" min={0} value={f.anciennete_mois} disabled={!editable} onChange={num('anciennete_mois')} /></Field>
            <Field label="Jours d'activité par mois"><Input type="number" min={1} max={31} value={f.jours_activite} disabled={!editable} onChange={(e) => setF({ ...f, jours_activite: Math.min(31, Math.max(1, Number(e.target.value) || 26)) })} /></Field>
            <Field label="Cycle de crédit"><Select value={f.cycle} disabled={!editable} onChange={(e) => setF({ ...f, cycle: Number(e.target.value) })}>{[1, 2, 3, 4, 5].map((n) => <option key={n} value={n}>{n === 5 ? '5e crédit et plus' : `${n}${n === 1 ? 'er' : 'e'} crédit`}</option>)}</Select></Field>
          </div>
          <div className="row">
            <Field label="Ventes moyennes par mois (F)" hint={saisonnier ? 'Calculées à partir des ventes mois par mois' : undefined}><Input type="number" min={0} value={Math.round(moyenne)} disabled={!editable || saisonnier} onChange={num('ventes_mensuelles')} /></Field>
            <Field label="Coût d'achat des marchandises (F)"><Input type="number" min={0} value={f.achats_mensuels} disabled={!editable} onChange={num('achats_mensuels')} /></Field>
            <Field label="Autres revenus du foyer (F)"><Input type="number" min={0} value={f.autres_revenus} disabled={!editable} onChange={num('autres_revenus')} /></Field>
            <Field label="Caution"><Select value={f.caution} disabled={!editable} onChange={(e) => setF({ ...f, caution: e.target.value })}>{Object.entries(CAUTIONS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
            <Field label="Historique de crédit"><Select value={f.historique} disabled={!editable} onChange={(e) => setF({ ...f, historique: e.target.value })}>{Object.entries(HISTORIQUES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
          </div>

          <label className="actions"><input type="checkbox" checked={saisonnier} disabled={!editable} onChange={(e) => basculerSaison(e.target.checked)} /> Les ventes du client varient selon les mois (activité saisonnière)</label>
          {saisonnier && f.ventes_par_mois && (
            <div className="row">
              {f.ventes_par_mois.map((v, i) => (
                <Field key={i} label={MOIS[i]}><Input type="number" min={0} value={v} disabled={!editable} aria-label={`Ventes de ${MOIS[i]}`}
                  onChange={(e) => setF({ ...f, ventes_par_mois: f.ventes_par_mois!.map((x, k) => (k === i ? Math.max(0, Number(e.target.value) || 0) : x)) })} /></Field>
              ))}
            </div>
          )}

          <h3>Charges par période</h3>
          <div className="table-wrap"><table className="t">
            <thead><tr><th>Libellé</th><th>Catégorie</th><th className="num">Montant (F)</th><th>Période</th><th /></tr></thead>
            <tbody>
              {f.charges.map((c, i) => (
                <tr key={i}>
                  <td><Input value={c.libelle} disabled={!editable} aria-label="Libellé de la charge" onChange={(e) => maj('charges', i, { libelle: e.target.value })} /></td>
                  <td><Select value={c.categorie} disabled={!editable} onChange={(e) => maj('charges', i, { categorie: e.target.value as Categorie })}>{Object.entries(CATEGORIES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></td>
                  <td><Input type="number" min={0} value={c.montant} disabled={!editable} aria-label="Montant de la charge" onChange={(e) => maj('charges', i, { montant: Math.max(0, Number(e.target.value) || 0) })} /></td>
                  <td><Select value={c.periode} disabled={!editable} onChange={(e) => maj('charges', i, { periode: e.target.value })}>{Object.entries(PERIODES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></td>
                  <td>{editable && <Button small variant="danger" aria-label="Supprimer la charge" onClick={() => retirer('charges', i)}>×</Button>}</td>
                </tr>
              ))}
              {f.charges.length === 0 && <tr><td colSpan={5} className="muted">Aucune charge saisie : le revenu disponible est probablement surestimé.</td></tr>}
            </tbody>
          </table></div>
          {editable && <div className="actions"><Button small onClick={() => setF({ ...f, charges: [...f.charges, { libelle: '', categorie: 'activite', montant: 0, periode: 'mois' }] })}>Ajouter une charge</Button></div>}

          <h3>Garanties</h3>
          <div className="table-wrap"><table className="t">
            <thead><tr><th>Libellé</th><th>Type</th><th className="num">Valeur estimée (F)</th><th className="num">Décote (%)</th><th className="num">Valeur retenue</th><th /></tr></thead>
            <tbody>
              {f.garanties.map((g, i) => (
                <tr key={i}>
                  <td><Input value={g.libelle} disabled={!editable} aria-label="Libellé de la garantie" onChange={(e) => maj('garanties', i, { libelle: e.target.value })} /></td>
                  <td><Select value={g.type} disabled={!editable} onChange={(e) => maj('garanties', i, { type: e.target.value, decote: DECOTES[e.target.value] ?? 50 })}>{Object.entries(GARANTIES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></td>
                  <td><Input type="number" min={0} value={g.valeur} disabled={!editable} aria-label="Valeur de la garantie" onChange={(e) => maj('garanties', i, { valeur: Math.max(0, Number(e.target.value) || 0) })} /></td>
                  <td><Input type="number" min={0} max={100} value={g.decote} disabled={!editable} aria-label="Décote" onChange={(e) => maj('garanties', i, { decote: Math.min(100, Math.max(0, Number(e.target.value) || 0)) })} /></td>
                  <td className="num">{xof(g.valeur * (1 - g.decote / 100))}</td>
                  <td>{editable && <Button small variant="danger" aria-label="Supprimer la garantie" onClick={() => retirer('garanties', i)}>×</Button>}</td>
                </tr>
              ))}
              {f.garanties.length === 0 && <tr><td colSpan={6} className="muted">Aucune garantie saisie.</td></tr>}
            </tbody>
          </table></div>
          {editable && <div className="actions"><Button small onClick={() => setF({ ...f, garanties: [...f.garanties, { libelle: '', type: 'materiel', valeur: 0, decote: DECOTES.materiel }] })}>Ajouter une garantie</Button></div>}
          <p className="muted">La décote tient compte de ce que l'institution récupère réellement en cas de vente forcée ; seule la valeur retenue compte pour la couverture du crédit.</p>
        </>
      )}

      {onglet === 'resultats' && res && <Resultats r={res} />}
      {onglet === 'scenarios' && <Scenarios f={f} res={res} demande={demande} editable={editable} maj={maj} retirer={retirer} ajouter={() => setF({ ...f, scenarios: [...f.scenarios, { libelle: `Scénario ${f.scenarios.length + 1}`, montant: demande.montant, nb_echeances: demande.nb_echeances, taux: demande.taux, methode: 'capital_constant', differe: 0 }] })} />}
      {onglet === 'groupe' && <Groupe f={f} res={res} editable={editable} maj={maj} retirer={retirer} ajouter={() => setF({ ...f, groupe: [...f.groupe, { nom: `Membre ${f.groupe.length + 1}`, montant: 0, disponible: 0 }] })} />}
      {onglet === 'rapport' && res && <Rapport demande={demande} f={f} r={res} politique={lecture.data?.politique ?? null} />}
      <p className="muted">Analyse indicative : elle éclaire la décision sans la bloquer. Taux d'endettement = (échéance mensuelle du crédit + dettes en cours) ÷ revenus ; couverture = revenu disponible ÷ échéance mensuelle.</p>
    </Modal>
  )
}

function BandeauAvis({ r }: { r: Resultat }) {
  return (
    <div className="actions" style={{ alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
      <span className="tag" style={{ background: couleur(r.niveau), color: '#fff', padding: '3px 10px', borderRadius: 4, fontWeight: 600 }}>{r.avis}</span>
      <strong>Score {Math.round(r.score)} / 100</strong>
      <span>Mise journalière {xof(r.mise_journaliere)}</span>
      <span>Endettement {pct(r.taux_endettement)}</span>
      <span>Couverture {cx(r.couverture)}</span>
    </div>
  )
}

function Jauge({ score, niveau }: { score: number; niveau: string }) {
  const s = Math.max(0, Math.min(100, Math.round(score)))
  return (
    <svg viewBox="0 0 220 135" style={{ width: '100%', maxWidth: 240 }} role="img" aria-label={`Score ${s} sur 100`}>
      <path d="M 20 115 A 90 90 0 0 1 200 115" fill="none" stroke="var(--line, #d3dbd7)" strokeWidth="16" strokeLinecap="round" pathLength={100} />
      <path d="M 20 115 A 90 90 0 0 1 200 115" fill="none" stroke={couleur(niveau)} strokeWidth="16" strokeLinecap="round" pathLength={100} strokeDasharray={`${s} 100`} />
      <text x="110" y="98" textAnchor="middle" fontSize="44" fontWeight="700" fill="currentColor">{s}</text>
      <text x="110" y="122" textAnchor="middle" fontSize="11" fill="currentColor" opacity="0.7">SCORE SUR 100</text>
    </svg>
  )
}

function Resultats({ r }: { r: Resultat }) {
  const [baisse, setBaisse] = useState(20)
  const reste = r.surplus - (baisse / 100) * r.marge_brute
  const criteres: [string, string][] = [['capacite', 'Capacité de paiement'], ['endettement', 'Endettement'], ['garanties', 'Garanties et caution'], ['anciennete', 'Ancienneté de l\'activité'], ['historique', 'Historique de crédit']]
  // courbe : marge restante après remboursement selon la baisse des ventes (0 à 60 %)
  const W = 560, H = 220, L = 56, B = 28, T = 12
  const y0 = r.surplus, y1 = r.surplus - 0.6 * r.marge_brute
  const hi = Math.max(y0, y1, 1), lo = Math.min(y0, y1, 0)
  const px = (s: number) => L + (s / 0.6) * (W - L - 12)
  const py = (v: number) => T + (1 - (v - lo) / (hi - lo || 1)) * (H - T - B)
  return (
    <>
      <div className="row" style={{ alignItems: 'center' }}>
        <Jauge score={r.score} niveau={r.niveau} />
        <div>
          <Badge tone={tonAvis(r.niveau)}>{r.avis}</Badge>
          <p>Mise journalière à constituer : <strong>{xof(r.mise_journaliere)}</strong> par jour d'activité, soit {xof(r.charge_mensuelle)} par mois.</p>
          <p className="muted">Montant maximal conseillé : {xof(r.montant_max_conseille)}{r.plafond_cycle > 0 ? ` (plafond du cycle : ${xof(r.plafond_cycle)})` : ''}.</p>
        </div>
      </div>
      <div className="grid-kpi">
        <Kpi label="Marge brute" value={xof(r.marge_brute)} />
        <Kpi label="Excédent de l'activité" value={xof(r.excedent_activite)} tone={r.excedent_activite > 0 ? undefined : 'bad'} />
        <Kpi label="Revenus" value={xof(r.revenus)} />
        <Kpi label="Revenu disponible" value={xof(r.revenu_disponible)} tone={r.revenu_disponible > 0 ? undefined : 'bad'} />
        <Kpi label="Charge mensuelle du crédit" value={xof(r.charge_mensuelle)} />
        <Kpi label={`Taux d'endettement (max ${r.endettement_max_pct} %)`} value={pct(r.taux_endettement)} tone={r.conforme_endettement ? undefined : 'bad'} />
        <Kpi label={`Couverture (min ${r.couverture_min})`} value={cx(r.couverture)} tone={r.conforme_couverture ? undefined : 'bad'} />
        <Kpi label="Dettes en cours" value={xof(r.dettes_en_cours)} />
        <Kpi label="Baisse de ventes tolérée" value={pct(r.baisse_ventes_tolere)} />
        <Kpi label={`Garanties retenues (min ${r.garantie_min_pct} %)`} value={`${xof(r.garanties_retenues)} — ${pct(r.couverture_garanties, 0)}`} tone={r.conforme_garanties ? undefined : 'warn'} />
        <Kpi label="Coût total du crédit" value={xof(r.cout_total)} />
        <Kpi label="TEG annuel" value={pct(r.teg)} />
      </div>
      {r.dettes_internes > 0 && <Alert tone="info">Dont {xof(r.dettes_internes)} par mois de remboursements déjà dus à l'institution, repris automatiquement.</Alert>}

      <h3>Composition du score</h3>
      {criteres.map(([k, lib], i) => (
        <div key={k} style={{ display: 'grid', gridTemplateColumns: '190px 1fr 40px', gap: 10, alignItems: 'center', margin: '4px 0' }}>
          <span>{lib} <span className="muted">({r.poids[i]} %)</span></span>
          <div style={{ height: 8, background: 'var(--line, #d3dbd7)', borderRadius: 4 }}><div style={{ width: `${r.sous_scores[k]}%`, height: '100%', background: 'var(--accent, #0b6e5f)', borderRadius: 4 }} /></div>
          <b style={{ textAlign: 'right' }}>{r.sous_scores[k]}</b>
        </div>
      ))}

      <h3>Et si les ventes baissent ?</h3>
      <div className="row" style={{ alignItems: 'center' }}>
        <input type="range" min={0} max={60} value={baisse} aria-label="Baisse des ventes en pourcentage" onChange={(e) => setBaisse(Number(e.target.value))} style={{ flex: '1 1 220px' }} />
        <span>Ventes −{baisse} % → marge restante après remboursement <b className={reste < 0 ? 'ko' : ''}>{xof(reste)}</b>{reste < 0 ? ' (défaut)' : ''}</span>
      </div>
      <svg viewBox={`0 0 ${W} ${H}`} style={{ width: '100%', maxWidth: 640 }} role="img" aria-label="Marge restante selon la baisse des ventes">
        {[0, 1, 2, 3, 4].map((g) => { const v = lo + (hi - lo) * g / 4; return <g key={g}><line x1={L} x2={W - 12} y1={py(v)} y2={py(v)} stroke="var(--line, #d3dbd7)" /><text x={L - 6} y={py(v) + 4} textAnchor="end" fontSize="10" fill="currentColor" opacity="0.7">{Math.round(v / 1000)} k</text></g> })}
        {[0, 10, 20, 30, 40, 50, 60].map((t) => <text key={t} x={px(t / 100)} y={H - 8} textAnchor="middle" fontSize="10" fill="currentColor" opacity="0.7">−{t} %</text>)}
        <line x1={L} x2={W - 12} y1={py(0)} y2={py(0)} stroke="var(--bad, #c0392b)" strokeDasharray="4 3" />
        <line x1={px(0)} y1={py(y0)} x2={px(0.6)} y2={py(y1)} stroke="var(--accent, #0b6e5f)" strokeWidth="2.5" />
        <line x1={px(baisse / 100)} x2={px(baisse / 100)} y1={T} y2={H - B} stroke="var(--warn, #b7791f)" />
        <circle cx={px(baisse / 100)} cy={py(reste)} r="4.5" fill="var(--warn, #b7791f)" />
      </svg>

      {r.mois && (
        <>
          <h3>Revenu disponible mois par mois</h3>
          <div className="table-wrap"><table className="t">
            <thead><tr><th>Mois</th><th className="num">Ventes</th><th className="num">Revenu disponible</th><th className="num">Après la charge de remboursement</th></tr></thead>
            <tbody>{r.mois.map((m, i) => <tr key={i} style={m.apres_charge < 0 ? { color: 'var(--bad, #c0392b)' } : undefined}><td>{MOIS[i]}</td><td className="num">{xof(m.ventes)}</td><td className="num">{xof(m.disponible)}</td><td className="num">{xof(m.apres_charge)}</td></tr>)}</tbody>
          </table></div>
          <p className="muted">Couverture retenue dans le score : moyenne entre la couverture moyenne ({cx(r.couverture)}) et celle du mois le plus faible ({r.pire_mois ? MOIS[r.pire_mois - 1] : '—'}) : {cx(r.couverture_effective)}.</p>
        </>
      )}

      <h3>Points d'attention</h3>
      {r.alertes.length === 0 ? <Alert tone="info">Aucun point à signaler.</Alert> : r.alertes.map((a) => <Alert key={a} tone="warn">{a}</Alert>)}

      <h3>Échéancier par mois</h3>
      <div className="table-wrap"><table className="t">
        <thead><tr><th>Mois</th><th className="num">À payer</th><th className="num">Capital</th><th className="num">Intérêts</th><th className="num">Solde</th></tr></thead>
        <tbody>{r.echeancier_mensuel.map((m) => <tr key={m.mois}><td>{m.mois}</td><td className="num">{xof(m.a_payer)}</td><td className="num">{xof(m.capital)}</td><td className="num">{xof(m.interets)}</td><td className="num">{xof(m.solde)}</td></tr>)}</tbody>
      </table></div>
    </>
  )
}

function Scenarios({ f, res, demande, editable, maj, retirer, ajouter }: {
  f: Dossier; res: Resultat | null; demande: DemandeInfo; editable: boolean
  maj: (k: 'scenarios', i: number, p: Partial<Scenario>) => void; retirer: (k: 'scenarios', i: number) => void; ajouter: () => void
}) {
  const cols = useMemo(() => {
    if (!res) return []
    const base = { libelle: 'Dossier actuel', charge_mensuelle: res.charge_mensuelle, mise_journaliere: res.mise_journaliere, taux_endettement: res.taux_endettement, couverture: res.couverture,
      baisse_ventes_tolere: res.baisse_ventes_tolere, teg: res.teg, cout_total: res.cout_total, score: res.score, avis: res.avis, niveau: res.niveau, montant: demande.montant, nb_echeances: demande.nb_echeances, taux_annuel: demande.taux, methode: '—', differe: 0, meilleur: false }
    return [base, ...(res.scenarios ?? [])]
  }, [res, demande])
  const meilleur = cols.length > 1 ? cols.reduce((b, c, i) => (c.score > cols[b].score ? i : b), 0) : -1
  const lignes: [string, (c: (typeof cols)[number]) => string][] = [
    ['Montant', (c) => xof(c.montant)], ['Échéances', (c) => String(c.nb_echeances)], ['Taux annuel', (c) => pct(c.taux_annuel)], ['Mode', (c) => (METHODES[c.methode] ?? c.methode) + (c.differe > 0 ? `, différé ${c.differe}` : '')],
    ['Charge mensuelle', (c) => xof(c.charge_mensuelle)], ['Mise journalière', (c) => xof(c.mise_journaliere)], ['Endettement', (c) => pct(c.taux_endettement)], ['Couverture', (c) => cx(c.couverture)],
    ['Baisse de ventes tolérée', (c) => pct(c.baisse_ventes_tolere)], ['TEG annuel', (c) => pct(c.teg)], ['Coût total', (c) => xof(c.cout_total)], ['Score', (c) => `${Math.round(c.score)} / 100`], ['Avis', (c) => c.avis],
  ]
  return (
    <>
      <p className="muted">Chaque scénario reprend les revenus, charges, garanties et la périodicité du dossier et ne change que le crédit. La première colonne est le dossier tel qu'il est demandé.</p>
      <div className="table-wrap"><table className="t">
        <thead><tr><th>Scénario</th><th className="num">Montant (F)</th><th className="num">Échéances</th><th className="num">Taux annuel (%)</th><th>Mode</th><th className="num">Différé (échéances)</th><th /></tr></thead>
        <tbody>
          {f.scenarios.map((s, i) => (
            <tr key={i}>
              <td><Input value={s.libelle} disabled={!editable} aria-label="Nom du scénario" onChange={(e) => maj('scenarios', i, { libelle: e.target.value })} /></td>
              <td><Input type="number" min={1} value={s.montant} disabled={!editable} aria-label="Montant du scénario" onChange={(e) => maj('scenarios', i, { montant: Math.max(1, Number(e.target.value) || 1) })} /></td>
              <td><Input type="number" min={1} value={s.nb_echeances} disabled={!editable} aria-label="Échéances du scénario" onChange={(e) => maj('scenarios', i, { nb_echeances: Math.max(1, Math.round(Number(e.target.value)) || 1) })} /></td>
              <td><Input type="number" min={0} step="0.5" value={Math.round(s.taux * 1000) / 10} disabled={!editable} aria-label="Taux du scénario" onChange={(e) => maj('scenarios', i, { taux: Math.max(0, Number(e.target.value) || 0) / 100 })} /></td>
              <td><Select value={s.methode} disabled={!editable} onChange={(e) => maj('scenarios', i, { methode: e.target.value })}>{Object.entries(METHODES).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></td>
              <td><Input type="number" min={0} value={s.differe} disabled={!editable} aria-label="Différé du scénario" onChange={(e) => maj('scenarios', i, { differe: Math.max(0, Math.round(Number(e.target.value)) || 0) })} /></td>
              <td>{editable && <Button small variant="danger" aria-label="Supprimer le scénario" onClick={() => retirer('scenarios', i)}>×</Button>}</td>
            </tr>
          ))}
          {f.scenarios.length === 0 && <tr><td colSpan={7} className="muted">Aucun scénario. Ajoutez-en un pour le comparer au dossier.</td></tr>}
        </tbody>
      </table></div>
      {editable && <div className="actions"><Button small onClick={ajouter}>Ajouter un scénario</Button></div>}
      {cols.length > 0 && (
        <div className="table-wrap"><table className="t">
          <thead><tr><th />{cols.map((c, i) => <th key={i} className="num">{c.libelle}{i === meilleur ? <><br /><Badge tone="ok">Meilleur score</Badge></> : null}</th>)}</tr></thead>
          <tbody>{lignes.map(([lib, fn]) => <tr key={lib}><th>{lib}</th>{cols.map((c, i) => <td key={i} className="num" style={i === meilleur ? { background: 'var(--accent-soft, #dcebe7)' } : undefined}>{fn(c)}</td>)}</tr>)}</tbody>
        </table></div>
      )}
    </>
  )
}

function Groupe({ f, res, editable, maj, retirer, ajouter }: {
  f: Dossier; res: Resultat | null; editable: boolean
  maj: (k: 'groupe', i: number, p: Partial<Membre>) => void; retirer: (k: 'groupe', i: number) => void; ajouter: () => void
}) {
  const g = res?.groupe
  return (
    <>
      <p className="muted">Chaque membre est évalué avec les conditions de crédit du dossier et les règles de l'institution. Le revenu disponible est celui du membre après ses charges et ses dettes en cours, avant la nouvelle échéance.</p>
      <div className="table-wrap"><table className="t">
        <thead><tr><th>Membre</th><th className="num">Montant demandé</th><th className="num">Revenu disponible par mois</th><th className="num">Charge mensuelle</th><th className="num">Couverture</th><th className="num">Montant max.</th><th>Avis</th><th /></tr></thead>
        <tbody>
          {f.groupe.map((m, i) => {
            const r = g?.membres[i]
            return (
              <tr key={i}>
                <td><Input value={m.nom} disabled={!editable} aria-label="Nom du membre" onChange={(e) => maj('groupe', i, { nom: e.target.value })} /></td>
                <td><Input type="number" min={0} value={m.montant} disabled={!editable} aria-label="Montant du membre" onChange={(e) => maj('groupe', i, { montant: Math.max(0, Number(e.target.value) || 0) })} /></td>
                <td><Input type="number" value={m.disponible} disabled={!editable} aria-label="Revenu disponible du membre" onChange={(e) => maj('groupe', i, { disponible: Number(e.target.value) || 0 })} /></td>
                <td className="num">{r ? xof(r.charge_mensuelle) : '—'}</td>
                <td className="num">{r ? cx(r.couverture) : '—'}</td>
                <td className="num">{r ? xof(r.montant_max) : '—'}</td>
                <td>{r ? <Badge tone={r.niveau === 'bon' ? 'ok' : r.niveau === 'limite' ? 'warn' : 'bad'}>{niveauMembre(r.niveau)}</Badge> : null}{r?.hors_plafond ? <> <Badge tone="warn">plafond</Badge></> : null}</td>
                <td>{editable && <Button small variant="danger" aria-label="Supprimer le membre" onClick={() => retirer('groupe', i)}>×</Button>}</td>
              </tr>
            )
          })}
          {f.groupe.length === 0 && <tr><td colSpan={8} className="muted">Aucun membre. Ajoutez les membres du groupe pour analyser un crédit solidaire.</td></tr>}
        </tbody>
      </table></div>
      {editable && <div className="actions"><Button small onClick={ajouter}>Ajouter un membre</Button></div>}
      {g && g.avis && (
        <>
          <div className="grid-kpi">
            <Kpi label="Montant total" value={xof(g.total_montant)} />
            <Kpi label="Charge mensuelle totale" value={xof(g.total_charge)} />
            <Kpi label="Revenu disponible total" value={xof(g.total_disponible)} />
            <Kpi label="Couverture du groupe" value={cx(g.couverture_groupe)} />
            <Kpi label="Avis du groupe" value={g.avis} tone={g.avis === 'Favorable' ? undefined : g.avis === 'Défavorable' ? 'bad' : 'warn'} />
          </div>
          {g.alertes.map((a) => <Alert key={a} tone="warn">{a}</Alert>)}
        </>
      )}
    </>
  )
}

/** Rapport du dossier : document imprimable (seul le rapport s'imprime) avec l'en-tête de l'institution. */
function Rapport({ demande, f, r, politique }: { demande: DemandeInfo; f: Dossier; r: Resultat; politique: Politique | null }) {
  const inst = useFetch(() => api.get<Institution>('/api/institution'), [])
  const i = inst.data
  const aujourd = new Date().toISOString().slice(0, 10)
  return (
    <>
      <div className="actions"><Button variant="primary" onClick={() => window.print()}>Imprimer le rapport</Button></div>
      <div className="piece-doc" style={{ padding: 16, border: '1px solid var(--line, #d1d5db)', borderRadius: 8, background: '#fff', color: '#111', fontSize: 13 }}>
        {i && (
          <div style={{ display: 'flex', gap: 12, alignItems: 'center', borderBottom: '2px solid #111', paddingBottom: 8 }}>
            {i.logo && <img src={i.logo} alt="Logo" style={{ maxHeight: 56, maxWidth: 110, objectFit: 'contain' }} />}
            <div>
              <div style={{ fontSize: 17, fontWeight: 700 }}>{i.raison_sociale}{i.sigle ? ` (${i.sigle})` : ''}</div>
              <div style={{ fontSize: 11 }}>{[i.adresse, i.ville, i.telephone && `Tél. ${i.telephone}`, i.email].filter(Boolean).join(' — ')}</div>
            </div>
          </div>
        )}
        <h3 style={{ margin: '10px 0 2px' }}>Rapport d'analyse de capacité de remboursement</h3>
        <div style={{ fontSize: 11 }}>Demande {demande.numero} — édité le {fdate(aujourd)}</div>

        <h4>1. Client et activité</h4>
        <table className="t" style={{ width: '100%' }}><tbody>
          <tr><th>Client</th><td>{demande.client}</td><th>Secteur</th><td>{f.secteur ? SECTEURS[f.secteur] : '—'}</td></tr>
          <tr><th>Ancienneté</th><td>{f.anciennete_mois} mois</td><th>Jours d'activité par mois</th><td>{f.jours_activite}</td></tr>
          <tr><th>Cycle de crédit</th><td>{f.cycle}</td><th>Caution</th><td>{CAUTIONS[f.caution]}</td></tr>
          <tr><th>Historique</th><td colSpan={3}>{HISTORIQUES[f.historique]}</td></tr>
        </tbody></table>

        <h4>2. Crédit demandé</h4>
        <table className="t" style={{ width: '100%' }}><tbody>
          <tr><th>Produit</th><td>{demande.produit}</td><th>Montant</th><td>{xof(demande.montant)}</td></tr>
          <tr><th>Échéances</th><td>{demande.nb_echeances}</td><th>Taux annuel</th><td>{pct(demande.taux)}</td></tr>
          <tr><th>Charge mensuelle</th><td>{xof(r.charge_mensuelle)}</td><th>Mise journalière</th><td>{xof(r.mise_journaliere)} par jour d'activité</td></tr>
          <tr><th>Coût total</th><td>{xof(r.cout_total)} (frais {xof(r.frais)})</td><th>TEG annuel</th><td>{pct(r.teg)}</td></tr>
        </tbody></table>

        <h4>3. Charges par période</h4>
        <table className="t" style={{ width: '100%' }}>
          <thead><tr><th>Libellé</th><th>Catégorie</th><th className="num">Montant</th><th>Période</th></tr></thead>
          <tbody>
            {f.charges.map((c, k) => <tr key={k}><td>{c.libelle || '(sans libellé)'}</td><td>{CATEGORIES[c.categorie]}</td><td className="num">{xof(c.montant)}</td><td>{PERIODES[c.periode]}</td></tr>)}
            {f.charges.length === 0 && <tr><td colSpan={4}>Aucune charge saisie.</td></tr>}
            <tr><th colSpan={2}>Charges de l'activité / du ménage / dettes en cours (par mois)</th><td className="num" colSpan={2}>{xof(r.charges_activite)} / {xof(r.charges_menage)} / {xof(r.dettes_en_cours)}</td></tr>
          </tbody>
        </table>

        <h4>4. Garanties</h4>
        <table className="t" style={{ width: '100%' }}>
          <thead><tr><th>Libellé</th><th>Type</th><th className="num">Valeur</th><th className="num">Décote</th><th className="num">Retenue</th></tr></thead>
          <tbody>
            {f.garanties.map((g, k) => <tr key={k}><td>{g.libelle || '(sans libellé)'}</td><td>{GARANTIES[g.type]}</td><td className="num">{xof(g.valeur)}</td><td className="num">{g.decote} %</td><td className="num">{xof(g.valeur * (1 - g.decote / 100))}</td></tr>)}
            {f.garanties.length === 0 && <tr><td colSpan={5}>Aucune garantie saisie.</td></tr>}
            <tr><th colSpan={4}>Total retenu ({pct(r.couverture_garanties, 0)} du crédit)</th><td className="num">{xof(r.garanties_retenues)}</td></tr>
          </tbody>
        </table>

        {r.mois && (
          <>
            <h4>5. Ventes par mois</h4>
            <table className="t" style={{ width: '100%' }}>
              <thead><tr><th>Mois</th><th className="num">Ventes</th><th className="num">Revenu disponible</th><th className="num">Après la charge</th></tr></thead>
              <tbody>{r.mois.map((m, k) => <tr key={k}><td>{MOIS[k]}</td><td className="num">{xof(m.ventes)}</td><td className="num">{xof(m.disponible)}</td><td className="num">{xof(m.apres_charge)}</td></tr>)}</tbody>
            </table>
          </>
        )}

        <h4>Revenus et capacité</h4>
        <table className="t" style={{ width: '100%' }}><tbody>
          <tr><th>Marge brute</th><td>{xof(r.marge_brute)}</td><th>Excédent de l'activité</th><td>{xof(r.excedent_activite)}</td></tr>
          <tr><th>Revenus</th><td>{xof(r.revenus)}</td><th>Revenu disponible</th><td>{xof(r.revenu_disponible)}</td></tr>
          <tr><th>Taux d'endettement (max {r.endettement_max_pct} %)</th><td>{pct(r.taux_endettement)}</td><th>Couverture (min {r.couverture_min})</th><td>{cx(r.couverture)}</td></tr>
          <tr><th>Baisse de ventes tolérée</th><td>{pct(r.baisse_ventes_tolere)}</td><th>Montant maximal conseillé</th><td>{xof(r.montant_max_conseille)}</td></tr>
        </tbody></table>

        <h4>Avis</h4>
        <p><strong>{r.avis} — {Math.round(r.score)} / 100</strong></p>
        <ul>{r.alertes.map((a) => <li key={a}>{a}</li>)}{r.alertes.length === 0 && <li>Aucun point d'attention.</li>}</ul>

        {r.scenarios && r.scenarios.length > 0 && (
          <>
            <h4>Comparaison de scénarios</h4>
            <table className="t" style={{ width: '100%' }}>
              <thead><tr><th>Scénario</th><th className="num">Charge mensuelle</th><th className="num">Endettement</th><th className="num">Couverture</th><th className="num">Score</th><th>Avis</th></tr></thead>
              <tbody>{r.scenarios.map((s, k) => <tr key={k}><td>{s.libelle}{s.meilleur ? ' (meilleur)' : ''}</td><td className="num">{xof(s.charge_mensuelle)}</td><td className="num">{pct(s.taux_endettement)}</td><td className="num">{cx(s.couverture)}</td><td className="num">{Math.round(s.score)}</td><td>{s.avis}</td></tr>)}</tbody>
            </table>
          </>
        )}

        {r.groupe && r.groupe.membres.length > 0 && (
          <>
            <h4>Groupe solidaire — avis : {r.groupe.avis}</h4>
            <table className="t" style={{ width: '100%' }}>
              <thead><tr><th>Membre</th><th className="num">Montant</th><th className="num">Revenu disponible</th><th className="num">Charge</th><th className="num">Couverture</th><th>Avis</th></tr></thead>
              <tbody>{r.groupe.membres.map((m, k) => <tr key={k}><td>{m.nom || 'Membre'}</td><td className="num">{xof(m.montant)}</td><td className="num">{xof(m.disponible)}</td><td className="num">{xof(m.charge_mensuelle)}</td><td className="num">{cx(m.couverture)}</td><td>{niveauMembre(m.niveau)}</td></tr>)}</tbody>
            </table>
          </>
        )}

        {politique && (
          <>
            <h4>Règles appliquées</h4>
            <p>Endettement maximum {politique.max_dti} % — couverture minimale {politique.min_couv} — garanties minimales {politique.min_gar} % du crédit — pondérations du score : capacité {r.poids[0]} %, endettement {r.poids[1]} %, garanties {r.poids[2]} %,
              ancienneté {r.poids[3]} %, historique {r.poids[4]} % — avis favorable dès {politique.seuils[0]}, sous conditions dès {politique.seuils[1]}, risqué dès {politique.seuils[2]} — plafond du cycle {f.cycle} : {xof(politique.plafonds[f.cycle - 1] ?? 0)}.</p>
          </>
        )}

        <h4>Échéancier par mois</h4>
        <table className="t" style={{ width: '100%' }}>
          <thead><tr><th>Mois</th><th className="num">À payer</th><th className="num">Capital</th><th className="num">Intérêts</th><th className="num">Solde</th></tr></thead>
          <tbody>{r.echeancier_mensuel.map((m) => <tr key={m.mois}><td>{m.mois}</td><td className="num">{xof(m.a_payer)}</td><td className="num">{xof(m.capital)}</td><td className="num">{xof(m.interets)}</td><td className="num">{xof(m.solde)}</td></tr>)}</tbody>
        </table>

        <div style={{ display: 'flex', justifyContent: 'space-between', gap: 16, marginTop: 28 }}>
          <div>Agent de crédit<br />Nom, date et signature<div style={{ height: 44 }} /></div>
          <div>Client<br />Nom, date et signature<div style={{ height: 44 }} /></div>
          <div>Responsable de l'agence<br />Avis, date et signature<div style={{ height: 44 }} /></div>
        </div>
        <p style={{ fontSize: 10, marginTop: 10 }}>Avis indicatif d'aide à la décision, calculé sur les données saisies ; il ne remplace ni la visite du client ni la politique de crédit de l'institution.{i?.pied_de_page ? ` ${i.pied_de_page}` : ''}</p>
      </div>
    </>
  )
}
