import { useState } from 'react'
import { api } from '../lib/api'
import { date as fdate, xof } from '../lib/format'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, Input, Modal, Page, Select, Table, useAction, useFetch } from '../components/ui'

interface LigneRapprochement {
  cycle_id: number; cycle_numero: string; client_numero: string; client: string
  machine_debut: string; machine_fin: string; machine_mise: number; machine_total: number
  releve_id: number | null; carnet_debut: string | null; carnet_fin: string | null; carnet_mise: number | null; total_carnet: number | null
  statut: 'sans_releve' | 'conforme' | 'ecart'; ecarts: string[]; ecart_total: number | null
}

const STATUT: Record<LigneRapprochement['statut'], { libelle: string; tone: 'ok' | 'warn' | 'neutre' }> = {
  sans_releve: { libelle: 'Sans relevé', tone: 'neutre' },
  conforme: { libelle: 'Conforme', tone: 'ok' },
  ecart: { libelle: 'Écart', tone: 'warn' },
}
const RUBRIQUE: Record<string, string> = { dates: 'dates', mise: 'mise', total: 'total' }
const signe = (v: number) => (v > 0 ? `+${xof(v)}` : xof(v))

// Relevé du carnet par cycle et rapprochement avec la machine. Un écart est signalé, il ne bloque pas le cycle.
export default function RelevesCarnet() {
  const { can } = useSession()
  const [statut, setStatut] = useState('')
  const [saisie, setSaisie] = useState<LigneRapprochement | null>(null)
  const q = useFetch(() => api.get<LigneRapprochement[]>('/api/releves-carnet/rapprochement', { statut: statut || undefined }), [statut])
  const peutSaisir = can('livret:controler')
  return (
    <Page title="Relevés carnet et rapprochement" subtitle="Relever le carnet du client (dates, mise, total non retiré page par page) et le rapprocher de la machine">
      <Card>
        <div className="grid-form">
          <Field label="Afficher">
            <Select value={statut} onChange={(e) => setStatut(e.target.value)}>
              <option value="">Tous les cycles</option>
              <option value="sans_releve">Sans relevé</option>
              <option value="ecart">En écart</option>
              <option value="conforme">Conformes</option>
            </Select>
          </Field>
        </div>
      </Card>
      <Card title="Cycles et rapprochement" flush>
        <Charge q={q}>
          {(rows) => (
            <>
              <p className="muted" style={{ padding: '8px 16px', margin: 0 }}>{rows.length} cycle(s) affiché(s)</p>
              <Table rows={rows} vide="Aucun cycle" cols={[
                { titre: 'Client', render: (l) => <><strong>{l.client}</strong><div className="muted">{l.client_numero} · {l.cycle_numero}</div></> },
                { titre: 'Machine', render: (l) => <>{fdate(l.machine_debut)} → {fdate(l.machine_fin)}<div className="muted">Mise {xof(l.machine_mise)} · total {xof(l.machine_total)}</div></> },
                { titre: 'Carnet', render: (l) => (l.releve_id === null
                  ? <span className="muted">Pas encore relevé</span>
                  : <>{fdate(l.carnet_debut)} → {fdate(l.carnet_fin)}<div className="muted">Mise {xof(l.carnet_mise)} · total {xof(l.total_carnet)}</div></>) },
                { titre: 'Statut', render: (l) => <Badge tone={STATUT[l.statut].tone}>{STATUT[l.statut].libelle}</Badge> },
                { titre: 'Écarts', render: (l) => (l.ecarts.length === 0
                  ? '—'
                  : <>{l.ecarts.map((e) => RUBRIQUE[e] ?? e).join(', ')}{l.ecart_total !== null && l.ecart_total !== 0 ? ` (total ${signe(l.ecart_total)})` : ''}</>) },
                { titre: '', render: (l) => (l.releve_id === null && peutSaisir
                  ? <Button small onClick={() => setSaisie(l)}>Saisir le relevé</Button>
                  : null) },
              ]} />
            </>
          )}
        </Charge>
      </Card>
      {saisie && <ReleverCycle ligne={saisie} onClose={() => setSaisie(null)} onFait={() => { setSaisie(null); q.reload() }} />}
    </Page>
  )
}

interface PageSaisie { page: number; montant: string }

function ReleverCycle({ ligne, onClose, onFait }: { ligne: LigneRapprochement; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  // identifiant de saisie : une validation rejouée (réseau coupé) ne crée pas un second relevé
  const [cle] = useState(() => `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`)
  const [debut, setDebut] = useState(ligne.machine_debut)
  const [fin, setFin] = useState(ligne.machine_fin)
  const [mise, setMise] = useState(String(ligne.machine_mise))
  const [pages, setPages] = useState<PageSaisie[]>([{ page: 1, montant: '' }])
  const total = pages.reduce((s, p) => s + Number(p.montant || 0), 0)
  const numeros = pages.map((p) => Number(p.page))
  const pagesUniques = new Set(numeros).size === numeros.length
  const complet = pages.every((p) => p.montant !== '' && Number(p.montant) >= 0 && Number(p.page) >= 1)
    && pagesUniques && fin >= debut && Number(mise) > 0
  const modifier = (i: number, champ: keyof PageSaisie, valeur: string) =>
    setPages(pages.map((p, k) => (k === i ? { ...p, [champ]: valeur } : p)))
  const ajouter = () => setPages([...pages, { page: Math.max(0, ...numeros) + 1, montant: '' }])
  const retirer = (i: number) => setPages(pages.filter((_, k) => k !== i))
  return (
    <Modal titre={`Relevé du carnet — ${ligne.client} · ${ligne.cycle_numero}`} onClose={onClose} large>
      <div className="stack">
        <Alert tone="info">Reportez les dates et la mise du carnet, puis le total non retiré de chaque page. Le relevé ne se modifie plus ensuite.</Alert>
        {fin < debut && <Alert tone="warn">La date de fin précède la date de début.</Alert>}
        {!pagesUniques && <Alert tone="warn">Une même page apparaît deux fois.</Alert>}
        <div className="grid-form">
          <Field label="Date de début"><Input type="date" value={debut} onChange={(e) => setDebut(e.target.value)} /></Field>
          <Field label="Date de fin"><Input type="date" value={fin} onChange={(e) => setFin(e.target.value)} /></Field>
          <Field label="Mise"><Input type="number" min={1} value={mise} onChange={(e) => setMise(e.target.value)} /></Field>
        </div>
        <Table rows={pages.map((p, i) => ({ ...p, i }))} vide="Aucune page" cols={[
          { titre: 'Page', render: (p) => <Input type="number" min={1} aria-label={`Numéro de page ${p.i + 1}`} style={{ width: 90 }}
            value={p.page} onChange={(e) => modifier(p.i, 'page', e.target.value)} /> },
          { titre: 'Total non retiré', num: true, render: (p) => <Input type="number" min={0} aria-label={`Montant page ${p.i + 1}`} style={{ width: 140 }}
            value={p.montant} onChange={(e) => modifier(p.i, 'montant', e.target.value)} /> },
          { titre: '', render: (p) => (pages.length > 1 ? <Button small onClick={() => retirer(p.i)}>Retirer</Button> : null) },
        ]} />
        <div>
          <Button small onClick={ajouter}>Ajouter une page</Button>
        </div>
        <div className="row" style={{ justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
          <span className="muted">
            Total du carnet {xof(total)} · total machine {xof(ligne.machine_total)} · écart {signe(total - ligne.machine_total)}
          </span>
          <Button variant="primary" disabled={!complet || busy} onClick={() => void run(() => api.post(`/api/releves-carnet/cycles/${ligne.cycle_id}`, {
            date_debut: debut, date_fin: fin, mise: Number(mise), cle,
            pages: pages.map((p) => ({ page: Number(p.page), montant: Number(p.montant) })),
          }), 'Relevé enregistré', onFait)}>Enregistrer le relevé</Button>
        </div>
      </div>
    </Modal>
  )
}
