import { api } from '../lib/api'
import { telechargerCsv } from '../lib/csv'
import { date as fdate, nombre, xof } from '../lib/format'
import { Alert, Badge, Button, Card, Charge, Kpi, Table, useFetch } from '../components/ui'

interface Portefeuille {
  indicateurs: Record<string, number | null>
  tranches: { tranche: string; nb_credits: number; capital_restant: number; montant_en_retard: number }[]
  repartition: Record<'type' | 'mode' | 'produit', { cle: string; nb_credits: number; encours: number; encours_en_retard: number }[]>
}
interface Retard { credit_id: number; numero: string; client: string; produit: string; capital_restant: number; jours_retard: number; nb_echeances_en_retard: number; montant_en_retard: number; garantie_bloquee: number }
interface Periode { rubriques: Record<string, number | null> }
interface Financier { lignes: { section: string; rubrique: string; libelle: string; valeur: number | null }[] }

const pct = (v: number | null | undefined) => (v === null || v === undefined ? '—' : `${nombre(v)} %`)
const LIB_REP: Record<string, string> = { type: 'Par type', mode: 'Par mode de remboursement', produit: 'Par produit' }
const LIB_CLE: Record<string, string> = { sur_epargne: 'Sur épargne', sans_epargne: 'Sans épargne', especes: 'Espèces', prelevement_compte: 'Prélèvement', tontine: 'Tontine' }

export function PortefeuilleCredit({ jour }: { jour: string }) {
  const q = useFetch(() => api.get<Portefeuille>('/api/rapports/credits/portefeuille', { date: jour }), [jour])
  const retards = useFetch(() => api.get<Retard[]>('/api/rapports/credits/retards', { date: jour }), [jour])
  return (
    <Charge q={q}>
      {(p) => {
        const i = p.indicateurs
        return (
          <div className="stack">
            <div className="grid-kpi">
              <Kpi label="Crédits actifs" value={nombre(i.credits_actifs)} />
              <Kpi label="Encours de capital" value={xof(i.encours_capital)} />
              <Kpi label="PAR 30 jours" value={pct(i.par_30_jours_pct)} tone={(i.par_30_jours_pct ?? 0) > 5 ? 'bad' : undefined} />
              <Kpi label="PAR 90 jours" value={pct(i.par_90_jours_pct)} tone={(i.par_90_jours_pct ?? 0) > 0 ? 'warn' : undefined} />
              <Kpi label="Impayé (capital + intérêts)" value={xof(i.impaye_capital_interets)} />
              <Kpi label="Garanties bloquées" value={xof(i.garanties_bloquees)} />
            </div>
            <Alert tone="info">PAR n jours = part de l'encours dont le plus ancien impayé dépasse n jours (PAR 1 jour : {pct(i.par_1_jour_pct)} ; PAR 60 jours : {pct(i.par_60_jours_pct)}). Calculé au {fdate(jour)} à partir des dates de paiement : une date passée se reproduit à l'identique.</Alert>
            <div className="grid-2">
              <Card title="Retard par tranche" flush>
                <Table rows={p.tranches} cols={[
                  { titre: 'Tranche', render: (t) => t.tranche },
                  { titre: 'Crédits', num: true, render: (t) => t.nb_credits },
                  { titre: 'Capital restant', num: true, render: (t) => xof(t.capital_restant) },
                  { titre: 'Impayé', num: true, render: (t) => xof(t.montant_en_retard) },
                ]} />
              </Card>
              {(['type', 'mode', 'produit'] as const).map((c) => (
                <Card key={c} title={LIB_REP[c]} flush>
                  <Table rows={p.repartition[c]} vide="Aucun crédit" cols={[
                    { titre: 'Catégorie', render: (r) => LIB_CLE[r.cle] ?? r.cle },
                    { titre: 'Crédits', num: true, render: (r) => r.nb_credits },
                    { titre: 'Encours', num: true, render: (r) => xof(r.encours) },
                    { titre: 'En retard', num: true, render: (r) => xof(r.encours_en_retard) },
                  ]} />
                </Card>
              ))}
            </div>
            <Card title="Crédits en retard" flush actions={retards.data && retards.data.length > 0 && <Button small onClick={() => telechargerCsv(`credits-en-retard-${jour}`,
              ['Crédit', 'Client', 'Produit', 'Capital restant', 'Jours de retard', 'Échéances en retard', 'Impayé', 'Garantie bloquée'],
              retards.data!.map((r) => [r.numero, r.client, r.produit, r.capital_restant, r.jours_retard, r.nb_echeances_en_retard, r.montant_en_retard, r.garantie_bloquee]))}>Exporter en CSV</Button>}>
              <Charge q={retards}>
                {(rows) => (
                  <Table rows={rows} vide="Aucun crédit en retard" cols={[
                    { titre: 'Crédit', render: (r) => <><strong>{r.numero}</strong><div className="muted">{r.client}</div></> },
                    { titre: 'Retard', num: true, render: (r) => <Badge tone={r.jours_retard > 90 ? 'bad' : r.jours_retard > 30 ? 'warn' : 'info'}>{r.jours_retard} j</Badge> },
                    { titre: 'Échéances', num: true, render: (r) => r.nb_echeances_en_retard },
                    { titre: 'Capital restant', num: true, render: (r) => xof(r.capital_restant) },
                    { titre: 'Impayé', num: true, render: (r) => xof(r.montant_en_retard) },
                    { titre: 'Garantie', num: true, render: (r) => (r.garantie_bloquee ? xof(r.garantie_bloquee) : '—') },
                  ]} />
                )}
              </Charge>
            </Card>
          </div>
        )
      }}
    </Charge>
  )
}

const LIB_PERIODE: [string, string, boolean][] = [
  ['credits_debloques_nb', 'Crédits débloqués (nombre)', true], ['credits_debloques_montant', 'Crédits débloqués (montant)', false],
  ['frais_de_dossier', 'Frais de dossier', false], ['remboursements_capital', 'Remboursements : capital', false],
  ['remboursements_interets', 'Remboursements : intérêts', false], ['remboursements_penalites', 'Remboursements : pénalités', false],
  ['remboursements_par_tontine', 'Remboursés sur tontine', false], ['remboursements_par_prelevement', 'Remboursés par prélèvement', false],
  ['remboursements_en_especes', 'Remboursés en espèces', false], ['garanties_saisies', 'Garanties saisies', false],
  ['credits_soldes', 'Crédits soldés', true], ['echeances_attendues', 'Échéances tombées dans la période', false],
  ['echeances_recouvrees', 'dont recouvrées à la fin de la période', false],
]

export function ActiviteCredit({ du, au }: { du: string; au: string }) {
  const q = useFetch(() => api.get<Periode>('/api/rapports/credits/periode', { du, au }), [du, au])
  return (
    <Charge q={q}>
      {(p) => {
        const v = p.rubriques
        return (
          <div className="stack">
            <div className="grid-kpi">
              <Kpi label="Décaissé" value={xof(v.credits_debloques_montant)} />
              <Kpi label="Remboursé (capital)" value={xof(v.remboursements_capital)} />
              <Kpi label="Intérêts perçus" value={xof(v.remboursements_interets)} />
              <Kpi label="Taux de recouvrement" value={pct(v.taux_recouvrement_pct)} tone={v.taux_recouvrement_pct !== null && (v.taux_recouvrement_pct ?? 100) < 90 ? 'warn' : undefined} />
            </div>
            <Card title={`Activité du ${fdate(du)} au ${fdate(au)}`} flush actions={<Button small onClick={() => telechargerCsv(`activite-credit-${du}-${au}`, ['Rubrique', 'Valeur'], LIB_PERIODE.map(([k, l]) => [l, v[k]]))}>Exporter en CSV</Button>}>
              <table className="t"><tbody>
                {LIB_PERIODE.map(([k, l, compte]) => <tr key={k}><td>{l}</td><td className="num">{compte ? nombre(v[k]) : xof(v[k])}</td></tr>)}
              </tbody></table>
            </Card>
            <Alert tone="info">Taux de recouvrement = part du capital et des intérêts des échéances tombées dans la période qui est payée à la fin de la période.</Alert>
          </div>
        )
      }}
    </Charge>
  )
}

export function RapportFinancier({ du, au }: { du: string; au: string }) {
  const q = useFetch(() => api.get<Financier>('/api/rapports/financier', { du, au }), [du, au])
  return (
    <Charge q={q}>
      {(f) => {
        const par = (s: string) => f.lignes.filter((l) => l.section === s)
        const val = (r: string) => f.lignes.find((l) => l.rubrique === r)?.valeur ?? 0
        const res = val('resultat')
        return (
          <div className="stack">
            <div className="grid-kpi">
              <Kpi label="Produits" value={xof(val('total_produits'))} />
              <Kpi label="Charges" value={xof(val('total_charges'))} />
              <Kpi label="Résultat de la période" value={xof(res)} tone={res < 0 ? 'bad' : undefined} />
              <Kpi label="Charges / produits" value={pct(f.lignes.find((l) => l.rubrique === 'ratio_charges_produits_pct')?.valeur)} />
            </div>
            <div className="grid-2">
              <Card title="Produits" flush><table className="t"><tbody>{par('produit').map((l) => <tr key={l.rubrique}><td>{l.libelle}</td><td className="num">{xof(l.valeur)}</td></tr>)}</tbody></table></Card>
              <Card title="Charges" flush><table className="t"><tbody>{par('charge').map((l) => <tr key={l.rubrique}><td>{l.libelle}</td><td className="num">{xof(l.valeur)}</td></tr>)}</tbody></table></Card>
            </div>
            <Card title="Pour information" flush><table className="t"><tbody>
              {par('info').filter((l) => l.rubrique !== 'ratio_charges_produits_pct').map((l) => <tr key={l.rubrique}><td>{l.libelle}</td><td className="num">{xof(l.valeur)}</td></tr>)}
            </tbody></table></Card>
            <Alert tone="warn">Compte d'exploitation opérationnel, calculé à partir des opérations : ce n'est pas un état réglementaire. Non inclus : intérêts servis sur l'épargne, provisions, amortissements ; les manquants des agents ne sont des charges que passés en perte. Le bilan se trouve dans Comptabilité.</Alert>
            <div className="actions"><Button small onClick={() => telechargerCsv(`rapport-financier-${du}-${au}`, ['Section', 'Rubrique', 'Valeur'], f.lignes.map((l) => [l.section, l.libelle, l.valeur]))}>Exporter en CSV</Button></div>
          </div>
        )
      }}
    </Charge>
  )
}
