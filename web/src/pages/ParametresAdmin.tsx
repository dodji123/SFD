import { useMemo, useState } from 'react'
import { api } from '../lib/api'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Select, Table, useAction, useFetch } from '../components/ui'

interface Parametre { cle: string; valeur: string; description: string | null; agence_id: number | null }

/** Rubriques de paramètres : première règle qui correspond à la clé. */
const RUBRIQUES: { id: string; titre: string; motif: RegExp }[] = [
  { id: 'tontine', titre: 'Tontine et cycles', motif: /^(taux_commission|plafond_retenue|mode_cloture|arrondi_|diviseur_type3|cycle_)/ },
  { id: 'epargne', titre: 'Épargne et parts sociales', motif: /^(adhesion_|droit_adhesion|parts_minimum|part_valeur|dat_|dormance_|retrait_seuil_)/ },
  { id: 'credit', titre: 'Crédit', motif: /^(seuil_validation_credit|plafond_cycle_|credit_|jours_saisie_garantie|garantie_min|penalite_|points_|jours_tranche|kyc_|endettement_max|couverture_min|score_|separation_|perte_min|comite_)/ },
  { id: 'provisions', titre: 'Provisions et risques', motif: /^(prov_|lbc_)/ },
  { id: 'compta', titre: 'Comptabilité et ratios', motif: /^(comptabilisation_|rapprochement_|ratio_|hyp_|type_institution|cheque_)/ },
  { id: 'rh', titre: 'RH et paie', motif: /^(conge_|jours_ouvres_|alerte_|discipline_|preavis_|recrutement_)/ },
]
const AUTRES = { id: 'autres', titre: 'Autres', motif: /.*/ }

const LIBELLES: Record<string, string> = {
  taux_commission: 'Taux de commission des collectrices (ex. 0,02 = 2 %)', plafond_retenue: 'Part maximale de la commission retenable pour solder le compte agent',
  mode_cloture: 'Mode de clôture / production : calendaire_mensuel ou date_fin_client', arrondi_mode: 'Arrondi de la mise (type 3) : plus_proche, superieur, inferieur',
  arrondi_multiple: "Multiple d'arrondi", diviseur_type3: 'Diviseur de la mise finale (type 3)', jours_saisie_garantie: 'Jours de retard avant saisie de la garantie',
  points_a_temps: 'Points : échéance payée à temps', points_retard_par_tranche: 'Points perdus par tranche de retard', jours_tranche_retard: "Taille d'une tranche de retard (jours)",
  points_credit_solde: 'Points : crédit soldé sans retard', penalite_taux: "Pénalité par jour : part du capital de l'échéance", penalite_plafond: "Plafond de pénalité (part de l'échéance)",
  seuil_validation_credit: 'Montant au-delà duquel un validateur est obligatoire', comptabilisation_auto: 'Comptabilisation automatique des opérations : oui / non',
  cycle_delai_grace_jours: "Délai de grâce par défaut après la fin d'un cycle (surchargé par le produit)",
}

export function rubriqueDe(cle: string) { return RUBRIQUES.find((r) => r.motif.test(cle)) ?? AUTRES }

/** Paramètres regroupés par rubrique, avec filtres (texte, rubrique, portée). */
export default function ParametresAdmin() {
  const { can, agenceId, agences } = useSession()
  const q = useFetch(() => api.get<Parametre[]>('/api/parametres'), [agenceId])
  const [texte, setTexte] = useState('')
  const [rubrique, setRubrique] = useState('')
  const [portee, setPortee] = useState('')
  const [edit, setEdit] = useState<Parametre | null>(null)
  const filtres = (rows: Parametre[]) => rows.filter((p) => {
    const t = texte.trim().toLowerCase()
    if (t && !`${p.cle} ${LIBELLES[p.cle] ?? ''} ${p.description ?? ''}`.toLowerCase().includes(t)) return false
    if (rubrique && rubriqueDe(p.cle).id !== rubrique) return false
    if (portee === 'agence' && p.agence_id === null) return false
    if (portee === 'globale' && p.agence_id !== null) return false
    return true
  })
  const rubriques = useMemo(() => [...RUBRIQUES, AUTRES], [])
  return (
    <div className="stack">
      <Alert tone="warn">Valeurs provisoires à faire valider par le client : taux de commission, plafond de retenue, plafond de pénalité, points de fidélité, seuils de retrait, durées de préavis et de prescription. L'activation de la comptabilisation automatique exige un exercice comptable ouvert et des règles validées par le comptable.</Alert>
      <Card>
        <div className="row">
          <Field label="Recherche"><Input value={texte} onChange={(e) => setTexte(e.target.value)} placeholder="Nom ou description du paramètre" /></Field>
          <Field label="Rubrique"><Select value={rubrique} onChange={(e) => setRubrique(e.target.value)}><option value="">Toutes</option>{rubriques.map((r) => <option key={r.id} value={r.id}>{r.titre}</option>)}</Select></Field>
          <Field label="Portée"><Select value={portee} onChange={(e) => setPortee(e.target.value)}><option value="">Toutes</option><option value="globale">Valeur commune</option><option value="agence">Surchargés pour l'agence</option></Select></Field>
        </div>
      </Card>
      <Charge q={q}>
        {(rows) => {
          const visibles = filtres(rows)
          if (visibles.length === 0) return <Card><p className="muted">Aucun paramètre ne correspond aux filtres.</p></Card>
          return (
            <>
              {rubriques.map((r) => {
                const lot = visibles.filter((p) => rubriqueDe(p.cle).id === r.id)
                if (lot.length === 0) return null
                return (
                  <Card key={r.id} title={`${r.titre} (${lot.length})`} flush>
                    <Table rows={lot} cols={[
                      { titre: 'Paramètre', render: (p) => <><strong>{p.cle}</strong><div className="muted">{LIBELLES[p.cle] ?? p.description}</div></> },
                      { titre: 'Valeur', render: (p) => <>{p.valeur}{p.agence_id !== null && <> <Badge tone="info">surcharge {agences.find((a) => a.id === p.agence_id)?.code ?? 'agence'}</Badge></>}</> },
                      { titre: '', render: (p) => can('params:write') && <Button small onClick={() => setEdit(p)}>Modifier</Button> },
                    ]} />
                  </Card>
                )
              })}
            </>
          )
        }}
      </Charge>
      {edit && <ModifierParametre p={edit} onClose={() => setEdit(null)} onFait={() => { setEdit(null); q.reload() }} />}
    </div>
  )
}

function ModifierParametre({ p, onClose, onFait }: { p: Parametre; onClose: () => void; onFait: () => void }) {
  const { agenceId, agences } = useSession()
  const { run, busy } = useAction()
  const [v, setV] = useState(p.valeur)
  const [portee, setPortee] = useState(p.agence_id !== null ? 'agence' : 'globale')
  return (
    <FormModal titre={`Modifier ${p.cle}`} onClose={onClose} busy={busy} valider="Enregistrer"
      onSubmit={() => void run(() => api.put(`/api/parametres/${p.cle}`, { valeur: v, agence_id: portee === 'agence' ? agenceId : null }), 'Paramètre modifié', onFait)}>
      <p className="muted" style={{ margin: 0 }}>{LIBELLES[p.cle] ?? p.description}</p>
      <Field label="Valeur"><Input value={v} onChange={(e) => setV(e.target.value)} required autoFocus /></Field>
      <Field label="Portée">
        <Select value={portee} onChange={(e) => setPortee(e.target.value)}>
          <option value="globale">Toutes les agences</option>
          <option value="agence">Cette agence seulement ({agences.find((a) => a.id === agenceId)?.code})</option>
        </Select>
      </Field>
    </FormModal>
  )
}
