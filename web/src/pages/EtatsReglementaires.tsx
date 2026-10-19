import { useState } from 'react'
import { api } from '../lib/api'
import { telechargerCsv } from '../lib/csv'
import { aujourdhui, date as fdate, nombre, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Kpi, Modal, Select, Table, useAction, useFetch } from '../components/ui'

interface Poste { code: string; libelle: string; montant: number }
interface Bilan { actif: Poste[]; passif: Poste[]; total_actif: number; total_passif: number }
interface Resultat { produits: Poste[]; charges: Poste[] }
interface Ratio {
  ratio: string; libelle: string; numerateur: number | null; denominateur: number | null; valeur: number | null
  norme_type: 'min' | 'max'; norme: number; conforme: boolean | null; saisies_manquantes: string[]; note: string
}
interface RatiosReponse { fonds_propres: number; ratios: Ratio[]; non_conformes: string[] }
interface Hypothese { code: string; libelle: string; explication: string; valeurs: string[]; valeur: string; validee: boolean; validee_par_login: string | null; validee_le: string | null; commentaire: string | null }
interface Seuil { cle: string; valeur: string; description: string }
interface Parametrage { hypotheses: Hypothese[]; seuils: Seuil[] }
interface Saisie { id: number; code: string; date_effet: string; valeur: number; commentaire: string | null; saisi_par: string | null }

const LIB_SAISIE: Record<string, string> = {
  depots_mlt: 'Dépôts et dettes à plus d\'un an (durée résiduelle)', engagements_ct_donnes: 'Engagements de financement et de garantie à court terme donnés',
  engagements_ct_recus: 'Engagements de financement et de garantie à court terme reçus', ops_autres_activites: 'Montant des opérations autres que épargne et crédit',
  complement_provisions_autorites: 'Compléments de provisions exigés par les autorités', participations_autres_sfd: 'Participations dans d\'autres SFD (fonds propres)',
}

const pct = (v: number | null) => (v === null ? '—' : `${nombre(v)} %`)

function Postes({ titre, rows, total }: { titre: string; rows: Poste[]; total?: string }) {
  const gras = (p: Poste, x: React.ReactNode) => (total && p.code === total ? <strong>{x}</strong> : x)
  return (
    <Card title={titre} flush>
      <Table rows={rows} vide="Aucun poste" cols={[
        { titre: 'Poste', render: (p) => gras(p, p.code) },
        { titre: 'Libellé', render: (p) => gras(p, p.libelle) },
        { titre: 'Montant net', num: true, render: (p) => gras(p, xof(p.montant)) },
      ]} />
    </Card>
  )
}

interface LigneCompte { code: string; libelle: string; montant: number }
interface BilanClassique { bilan: { actif: LigneCompte[]; passif: LigneCompte[]; total_actif: number; total_passif: number } }

/** Bilan « normal » : actif et passif par comptes (niveau 2 du plan comptable), à côté du bilan par postes réglementaires. */
function BilanNormal({ du, au, consolide }: { du: string; au: string; consolide: boolean }) {
  const q = useFetch(() => (consolide ? api.get<BilanClassique>('/api/etats/consolide', { du, au }) : api.get<BilanClassique>('/api/etats/agence', { du, au })), [du, au, consolide])
  const liste = (rows: LigneCompte[], total: number, titre: string) => (
    <Card title={titre} flush>
      <Table rows={rows} vide="Aucun solde" cols={[
        { titre: 'Compte', render: (l) => l.code },
        { titre: 'Libellé', render: (l) => l.libelle },
        { titre: 'Montant', num: true, render: (l) => xof(l.montant) },
      ]} />
      <div className="actions" style={{ padding: '8px 16px', justifyContent: 'space-between' }}><strong>Total</strong><strong>{xof(total)}</strong></div>
    </Card>
  )
  return (
    <Charge q={q}>
      {({ bilan: b }) => (
        <>
          <div className="actions">
            <strong>Bilan classique (par comptes) au {fdate(au)}</strong>
            {b.total_actif === b.total_passif ? <Badge tone="ok">Équilibré</Badge> : <Badge tone="bad">Écart {xof(b.total_actif - b.total_passif)}</Badge>}
            <Button small onClick={() => telechargerCsv(`bilan-classique-${au}`, ['Côté', 'Compte', 'Libellé', 'Montant'],
              [...b.actif.map((l) => ['Actif', l.code, l.libelle, l.montant]), ...b.passif.map((l) => ['Passif', l.code, l.libelle, l.montant])])}>Exporter en CSV</Button>
          </div>
          <div className="grid-2">
            {liste(b.actif, b.total_actif, 'Actif')}
            {liste(b.passif, b.total_passif, 'Passif')}
          </div>
        </>
      )}
    </Charge>
  )
}

export function Reglementaire({ du, au, consolide }: { du: string; au: string; consolide: boolean }) {
  const q = useFetch(() => api.get<Bilan>('/api/reglementaire/bilan', { au, consolide }), [au, consolide])
  const r = useFetch(() => api.get<Resultat>('/api/reglementaire/resultat', { du, au, consolide }), [du, au, consolide])
  return (
    <div className="stack">
      <Alert tone="info">États présentés selon la nomenclature des postes du référentiel comptable des SFD de l'UMOA (annexe 1.1). Montants nets ; les colonnes brut et amortissements ne sont pas produites. Document de travail, à valider par le comptable avant tout dépôt auprès des autorités.</Alert>
      <Charge q={q}>
        {(b) => (
          <>
            <div className="grid-kpi">
              <Kpi label="Total actif (E90)" value={xof(b.total_actif)} />
              <Kpi label="Total passif (L90)" value={xof(b.total_passif)} />
              <Kpi label="Équilibre" value={b.total_actif === b.total_passif ? 'Équilibré' : 'Écart ' + xof(b.total_actif - b.total_passif)} tone={b.total_actif === b.total_passif ? undefined : 'bad'} />
            </div>
            <div className="grid-2">
              <Postes titre={`Bilan — actif au ${fdate(au)}`} rows={b.actif} total="E90" />
              <Postes titre={`Bilan — passif au ${fdate(au)}`} rows={b.passif} total="L90" />
            </div>
            <div className="actions"><Button small onClick={() => telechargerCsv(`bilan-reglementaire-${au}`, ['Côté', 'Poste', 'Libellé', 'Montant net'],
              [...b.actif.map((p) => ['Actif', p.code, p.libelle, p.montant]), ...b.passif.map((p) => ['Passif', p.code, p.libelle, p.montant])])}>Exporter le bilan en CSV</Button></div>
          </>
        )}
      </Charge>
      <BilanNormal du={du} au={au} consolide={consolide} />
      <Charge q={r}>
        {(x) => (
          <div className="grid-2">
            <Postes titre={`Produits du ${fdate(du)} au ${fdate(au)}`} rows={x.produits} />
            <Postes titre="Charges" rows={x.charges} />
          </div>
        )}
      </Charge>
    </div>
  )
}

export function RatiosPrudentiels({ au, consolide }: { au: string; consolide: boolean }) {
  const { can } = useSession()
  const q = useFetch(() => api.get<RatiosReponse>('/api/reglementaire/ratios', { date: au, consolide }), [au, consolide])
  const saisies = useFetch(() => (consolide ? Promise.resolve([] as Saisie[]) : api.get<Saisie[]>('/api/reglementaire/donnees')), [consolide])
  const { run, busy } = useAction()
  const [histo, setHisto] = useState<string | null>(null)
  const [saisie, setSaisie] = useState(false)
  return (
    <div className="stack">
      <Alert tone="info">Ratios prudentiels I à IX du guide méthodologique d'audit externe (instruction 6). Les seuils sont paramétrables. Une valeur « incomplète » signale une donnée qui ne sort pas de la comptabilité et doit être saisie.</Alert>
      <Charge q={q}>
        {(d) => (
          <>
            <div className="grid-kpi">
              <Kpi label="Fonds propres retraités" value={xof(d.fonds_propres)} />
              <Kpi label="Ratios conformes" value={`${d.ratios.filter((x) => x.conforme === true).length} / ${d.ratios.length}`} />
              <Kpi label="Non conformes" value={d.non_conformes.length ? d.non_conformes.join(', ') : 'Aucun'} tone={d.non_conformes.length ? 'bad' : undefined} />
            </div>
            <Card flush actions={<>
              {can('ratios:enregistrer') && <Button small disabled={busy} onClick={() => void run(() => api.post(`/api/reglementaire/ratios/enregistrer?date=${au}${consolide ? '&consolide=true' : ''}`), 'Ratios enregistrés dans l\'historique')}>Figer dans l'historique</Button>}
              <Button small onClick={() => telechargerCsv(`ratios-prudentiels-${au}`, ['Ratio', 'Libellé', 'Numérateur', 'Dénominateur', 'Valeur %', 'Norme', 'Conforme'],
                d.ratios.map((x) => [x.ratio, x.libelle, x.numerateur, x.denominateur, x.valeur, `${x.norme_type === 'max' ? '≤' : '≥'} ${x.norme}`, x.conforme === null ? 'non calculable' : x.conforme ? 'oui' : 'non']))}>Exporter en CSV</Button></>}>
              <Table rows={d.ratios} onRowClick={(x) => setHisto(x.ratio)} cols={[
                { titre: 'Ratio', render: (x) => <strong>{x.ratio}</strong> },
                { titre: 'Libellé', render: (x) => <>{x.libelle}<div className="muted">{x.note}</div></> },
                { titre: 'Valeur', num: true, render: (x) => pct(x.valeur) },
                { titre: 'Norme', num: true, render: (x) => `${x.norme_type === 'max' ? '≤' : '≥'} ${nombre(x.norme)} %` },
                { titre: 'Situation', render: (x) => (
                  <>
                    {x.conforme === true && <Badge tone="ok">Conforme</Badge>}
                    {x.conforme === false && <Badge tone="bad">Non conforme</Badge>}
                    {x.conforme === null && <Badge>Non calculable</Badge>}
                    {x.saisies_manquantes.length > 0 && <div><Badge tone="warn">Incomplet</Badge> <span className="muted">{x.saisies_manquantes.map((c) => LIB_SAISIE[c] ?? c).join(' ; ')}</span></div>}
                  </>
                ) },
              ]} />
            </Card>
          </>
        )}
      </Charge>
      {!consolide && (
        <Card title="Données complémentaires saisies" flush actions={can('ratios:saisir') && <Button small variant="primary" onClick={() => setSaisie(true)}>Saisir une donnée</Button>}>
          <Charge q={saisies}>
            {(rows) => (
              <Table rows={rows} vide="Aucune donnée saisie : les ratios concernés sont marqués incomplets" cols={[
                { titre: 'Donnée', render: (s) => LIB_SAISIE[s.code] ?? s.code },
                { titre: 'Effet au', render: (s) => fdate(s.date_effet) },
                { titre: 'Montant', num: true, render: (s) => xof(s.valeur) },
                { titre: 'Saisi par', render: (s) => s.saisi_par ?? '—' },
                { titre: 'Commentaire', render: (s) => s.commentaire ?? '' },
              ]} />
            )}
          </Charge>
          <div className="card-b muted">Les saisies sont conservées et datées ; la plus récente avant la date de calcul fait foi. Elles ne peuvent ni être modifiées ni supprimées.</div>
        </Card>
      )}
      <Parametres />
      {saisie && <NouvelleSaisie onClose={() => setSaisie(false)} onFait={() => { setSaisie(false); saisies.reload(); q.reload() }} />}
      {histo && <Historique ratio={histo} consolide={consolide} onClose={() => setHisto(null)} />}
    </div>
  )
}

function NouvelleSaisie({ onClose, onFait }: { onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ code: 'depots_mlt', date_effet: aujourdhui(), valeur: '', commentaire: '' })
  return (
    <FormModal titre="Saisir une donnée complémentaire" onClose={onClose} busy={busy} valider="Enregistrer" large
      onSubmit={() => void run(() => api.post('/api/reglementaire/donnees', { code: f.code, date_effet: f.date_effet, valeur: Number(f.valeur), commentaire: f.commentaire || null }), 'Donnée enregistrée', onFait)}>
      <Field label="Donnée"><Select value={f.code} onChange={(e) => setF({ ...f, code: e.target.value })}>{Object.entries(LIB_SAISIE).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</Select></Field>
      <Field label="Valable à partir du"><Input type="date" value={f.date_effet} onChange={(e) => setF({ ...f, date_effet: e.target.value })} required /></Field>
      <Field label="Montant (F)"><Input type="number" min={0} value={f.valeur} onChange={(e) => setF({ ...f, valeur: e.target.value })} required /></Field>
      <Field label="Source / commentaire"><Input value={f.commentaire} onChange={(e) => setF({ ...f, commentaire: e.target.value })} placeholder="ex. état des dépôts à terme au 30/09" /></Field>
    </FormModal>
  )
}

function Historique({ ratio, consolide, onClose }: { ratio: string; consolide: boolean; onClose: () => void }) {
  const q = useFetch(() => api.get<{ date_calcul: string; valeur: number | null; norme_type: string; norme: number; conforme: boolean | null }[]>('/api/reglementaire/ratios/historique', { ratio, consolide }), [ratio, consolide])
  return (
    <Modal titre={`Historique du ratio ${ratio}`} onClose={onClose}>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucun instantané enregistré : utilisez « Figer dans l'historique »" cols={[
            { titre: 'Date', render: (h) => fdate(h.date_calcul) },
            { titre: 'Valeur', num: true, render: (h) => pct(h.valeur) },
            { titre: 'Norme', num: true, render: (h) => `${h.norme_type === 'max' ? '≤' : '≥'} ${nombre(h.norme)} %` },
            { titre: '', render: (h) => (h.conforme === true ? <Badge tone="ok">Conforme</Badge> : h.conforme === false ? <Badge tone="bad">Non conforme</Badge> : <Badge>—</Badge>) },
          ]} />
        )}
      </Charge>
    </Modal>
  )
}

function Parametres() {
  const { can } = useSession()
  const q = useFetch(() => api.get<Parametrage>('/api/reglementaire/hypotheses'), [])
  const { run, busy } = useAction()
  const [seuils, setSeuils] = useState<Record<string, string>>({})
  const modifiable = can('ratios:parametrer')
  const valider = can('ratios:valider')
  const maj = (url: string, valeur: string, message: string) => void run(async () => { await api.put(url, { valeur }); setSeuils({}) }, message, q.reload)
  return (
    <Card title="Hypothèses de calcul et seuils" flush>
      <Charge q={q}>
        {(d) => (
          <>
            <div className="card-b"><Alert tone="warn">Points d'interprétation du guide d'audit. Chaque choix est paramétrable ; le comptable valide la valeur retenue, et sa validation tombe si la valeur change. Les seuils datent de 2010 : les contrôler contre les instructions BCEAO en vigueur.</Alert></div>
            <Table rows={d.hypotheses} cols={[
              { titre: 'Hypothèse', render: (h) => <><strong>{h.libelle}</strong><div className="muted">{h.explication}</div></> },
              { titre: 'Valeur retenue', render: (h) => modifiable
                ? <Select value={h.valeur} disabled={busy} onChange={(e) => maj(`/api/reglementaire/hypotheses/${h.code}`, e.target.value, 'Hypothèse modifiée')}>{h.valeurs.map((v) => <option key={v} value={v}>{v}</option>)}</Select>
                : h.valeur },
              { titre: 'Validation', render: (h) => (h.validee
                ? <><Badge tone="ok">Validée</Badge><div className="muted">{h.validee_par_login} · {h.validee_le ? new Date(h.validee_le).toLocaleDateString('fr-FR') : ''}{h.commentaire ? ' — ' + h.commentaire : ''}</div></>
                : <><Badge tone="warn">À valider</Badge>{valider && <> <Button small disabled={busy} onClick={() => { const c = window.prompt('Commentaire de validation (facultatif)') ; if (c !== null) void run(() => api.post(`/api/reglementaire/hypotheses/${h.code}/valider`, { commentaire: c || null }), 'Hypothèse validée', q.reload) }}>Valider</Button></>}</>) },
            ]} />
            <Table rows={d.seuils} cols={[
              { titre: 'Seuil', render: (s) => <><strong>{s.cle.replace('ratio_norme_', 'Ratio ').replace(/_/g, ' ')}</strong><div className="muted">{s.description}</div></> },
              { titre: 'Valeur', render: (s) => (modifiable
                ? <span className="actions"><Input style={{ width: 110 }} value={seuils[s.cle] ?? s.valeur} onChange={(e) => setSeuils({ ...seuils, [s.cle]: e.target.value })} />
                    {seuils[s.cle] !== undefined && seuils[s.cle] !== s.valeur && <Button small variant="primary" disabled={busy} onClick={() => maj(`/api/reglementaire/seuils/${s.cle}`, seuils[s.cle], 'Seuil modifié')}>Enregistrer</Button>}</span>
                : s.valeur) },
            ]} />
          </>
        )}
      </Charge>
    </Card>
  )
}
