import { useState } from 'react'
import { api } from '../lib/api'
import { useSession } from '../lib/session'
import { Badge, Button, Card, Charge, Field, FormModal, Input, Kpi, Modal, Money, Table, useAction, useFetch } from '../components/ui'

interface Reseau { id: number; code: string; libelle: string; actif: boolean; nb_agences: number; nb_utilisateurs: number }
interface Agence { id: number; code: string; libelle: string; reseau_id: number | null }
interface Synthese {
  reseau: Reseau
  agences: { agence_id: number; code: string; libelle: string; clients: number; credits_en_cours: number; encours: number; credits_en_retard: number; encours_en_retard: number; demandes_en_attente: number }[]
  total: { clients: number; credits_en_cours: number; encours: number; credits_en_retard: number; encours_en_retard: number; demandes_en_attente: number; par_pct: number }
}

/** Réseaux d'agences : regroupement, rattachement et vue de synthèse. Un coordinateur ne voit que son réseau. */
export default function ReseauxAdmin() {
  const { can } = useSession()
  const q = useFetch(() => api.get<Reseau[]>('/api/reseaux'), [])
  const { run, busy } = useAction()
  const [nouveau, setNouveau] = useState(false)
  const [f, setF] = useState({ code: '', libelle: '' })
  const [rattache, setRattache] = useState<Reseau | null>(null)
  const [synthese, setSynthese] = useState<number | null>(null)
  return (
    <Card flush actions={can('reseaux:write') ? <Button variant="primary" onClick={() => { setF({ code: '', libelle: '' }); setNouveau(true) }}>Nouveau réseau</Button> : undefined}>
      <Charge q={q}>
        {(rows) => (
          <Table rows={rows} vide="Aucun réseau" cols={[
            { titre: 'Code', render: (r) => <strong>{r.code}</strong> },
            { titre: 'Libellé', render: (r) => r.libelle },
            { titre: 'Agences', render: (r) => r.nb_agences },
            { titre: 'Utilisateurs', render: (r) => r.nb_utilisateurs },
            { titre: 'État', render: (r) => (r.actif ? <Badge tone="ok">Actif</Badge> : <Badge tone="bad">Inactif</Badge>) },
            { titre: '', render: (r) => (
              <span className="actions">
                <Button small onClick={() => setSynthese(r.id)}>Synthèse</Button>
                {can('reseaux:write') && <Button small onClick={() => setRattache(r)}>Agences</Button>}
                {can('reseaux:write') && <Button small disabled={busy} onClick={() => void run(() => api.patch(`/api/reseaux/${r.id}`, { actif: !r.actif }), r.actif ? 'Réseau désactivé' : 'Réseau réactivé', q.reload)}>{r.actif ? 'Désactiver' : 'Réactiver'}</Button>}
              </span>
            ) },
          ]} />
        )}
      </Charge>
      {nouveau && (
        <FormModal titre="Nouveau réseau" onClose={() => setNouveau(false)} busy={busy} valider="Créer"
          onSubmit={() => void run(() => api.post('/api/reseaux', f), 'Réseau créé', () => { setNouveau(false); q.reload() })}>
          <Field label="Code" hint="Lettres, chiffres, - et _"><Input value={f.code} onChange={(e) => setF({ ...f, code: e.target.value })} maxLength={10} required autoFocus /></Field>
          <Field label="Libellé"><Input value={f.libelle} onChange={(e) => setF({ ...f, libelle: e.target.value })} required /></Field>
        </FormModal>
      )}
      {rattache && <Rattachement reseau={rattache} onClose={() => setRattache(null)} onFait={() => { setRattache(null); q.reload() }} />}
      {synthese !== null && <VueSynthese id={synthese} onClose={() => setSynthese(null)} />}
    </Card>
  )
}

function Rattachement({ reseau, onClose, onFait }: { reseau: Reseau; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const q = useFetch(() => api.get<Agence[]>('/api/agences'), [])
  const [choix, setChoix] = useState<Set<number> | null>(null)
  const sel = (rows: Agence[]) => choix ?? new Set(rows.filter((a) => a.reseau_id === reseau.id).map((a) => a.id))
  return (
    <Charge q={q}>
      {(rows) => {
        const s = sel(rows)
        return (
          <FormModal titre={`Agences du réseau ${reseau.code}`} onClose={onClose} busy={busy} valider="Enregistrer"
            onSubmit={() => void run(() => api.put(`/api/reseaux/${reseau.id}/agences`, { agence_ids: [...s] }), 'Agences rattachées', onFait)}>
            <p className="muted" style={{ margin: 0 }}>Une agence n'appartient qu'à un seul réseau : cocher une agence d'un autre réseau l'en retire.</p>
            {rows.map((a) => (
              <label key={a.id} className="row" style={{ gap: 8 }}>
                <input type="checkbox" checked={s.has(a.id)} onChange={(e) => { const n = new Set(s); if (e.target.checked) n.add(a.id); else n.delete(a.id); setChoix(n) }} />
                <span>{a.code} — {a.libelle}</span>
                {a.reseau_id !== null && a.reseau_id !== reseau.id && <Badge tone="warn">autre réseau</Badge>}
              </label>
            ))}
          </FormModal>
        )
      }}
    </Charge>
  )
}

function VueSynthese({ id, onClose }: { id: number; onClose: () => void }) {
  const q = useFetch(() => api.get<Synthese>(`/api/reseaux/${id}/synthese`), [id])
  return (
    <Modal titre="Synthèse du réseau" onClose={onClose} large footer={<Button onClick={onClose}>Fermer</Button>}>
      <Charge q={q}>
        {(s) => (
          <div className="stack">
            <div className="kpis">
              <Kpi label="Clients" value={s.total.clients} />
              <Kpi label="Crédits en cours" value={s.total.credits_en_cours} />
              <Kpi label="Encours" value={<Money v={s.total.encours} />} />
              <Kpi label="Portefeuille à risque" value={`${s.total.par_pct} %`} tone={s.total.par_pct > 5 ? 'bad' : s.total.par_pct > 0 ? 'warn' : undefined} />
              <Kpi label="Demandes en attente" value={s.total.demandes_en_attente} />
            </div>
            <Table rows={s.agences} cols={[
              { titre: 'Agence', render: (a) => <strong>{a.code}</strong> },
              { titre: 'Clients', render: (a) => a.clients },
              { titre: 'Crédits en cours', render: (a) => a.credits_en_cours },
              { titre: 'Encours', render: (a) => <Money v={a.encours} /> },
              { titre: 'En retard', render: (a) => `${a.credits_en_retard} (${a.encours_en_retard.toLocaleString('fr-FR')})` },
              { titre: 'Demandes', render: (a) => a.demandes_en_attente },
            ]} />
          </div>
        )}
      </Charge>
    </Modal>
  )
}
