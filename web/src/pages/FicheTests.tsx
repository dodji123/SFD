import { useState } from 'react'
import { api } from '../lib/api'
import { date as fdate } from '../lib/format'
import { Badge, Button, Card, Charge, Input, Page, Select, useAction, useFetch } from '../components/ui'

interface Test {
  section: string; numero: string; parcours: string; resultat_attendu: string
  statut: 'a_faire' | 'ok' | 'ko'; commentaire: string | null; modifie_par: string | null; modifie_le: string | null
}

const TON: Record<Test['statut'], { texte: string; tone: 'neutre' | 'ok' | 'bad' }> = {
  a_faire: { texte: 'À faire', tone: 'neutre' }, ok: { texte: 'OK', tone: 'ok' }, ko: { texte: 'Anomalie', tone: 'bad' },
}

/** Ligne d'un test : statut et commentaire, enregistrés test par test. */
function LigneTest({ t, onFait }: { t: Test; onFait: () => void }) {
  const { run, busy } = useAction()
  const [statut, setStatut] = useState<Test['statut']>(t.statut)
  const [commentaire, setCommentaire] = useState(t.commentaire ?? '')
  const modifie = statut !== t.statut || commentaire !== (t.commentaire ?? '')
  return (
    <tr>
      <td><strong>{t.numero}</strong></td>
      <td>{t.parcours}</td>
      <td className="muted">{t.resultat_attendu}</td>
      <td>
        <Select value={statut} onChange={(e) => setStatut(e.target.value as Test['statut'])}>
          <option value="a_faire">À faire</option>
          <option value="ok">OK</option>
          <option value="ko">Anomalie</option>
        </Select>
      </td>
      <td><Input value={commentaire} onChange={(e) => setCommentaire(e.target.value)} placeholder="Constat, anomalie…" /></td>
      <td>
        <Button small variant="primary" disabled={busy || !modifie}
          onClick={() => void run(() => api.put(`/api/fiche-tests/${t.numero}`, { statut, commentaire: commentaire.trim() || null }), `Test ${t.numero} enregistré`, onFait)}>
          Enregistrer
        </Button>
        <div className="muted" style={{ fontSize: '0.8rem' }}>
          <Badge tone={TON[t.statut].tone}>{TON[t.statut].texte}</Badge>{t.modifie_par ? ` · ${t.modifie_par}` : ''}{t.modifie_le ? ` · ${fdate(t.modifie_le)}` : ''}
        </div>
      </td>
    </tr>
  )
}

/** Fiche de suivi des tests manuels : chacun renseigne le résultat de ses tests. */
export default function FicheTests() {
  const liste = useFetch(() => api.get<Test[]>('/api/fiche-tests'), [])
  return (
    <Page title="Fiche de suivi des tests manuels" subtitle="Cochez le résultat de chaque test et notez ce que vous observez">
      <Charge q={liste}>
        {(rows) => {
          const sections = [...new Set(rows.map((r) => r.section))]
          const faits = rows.filter((r) => r.statut !== 'a_faire').length
          const ko = rows.filter((r) => r.statut === 'ko').length
          return (
            <>
              <p className="muted">{faits} / {rows.length} tests renseignés · {ko} anomalie(s)</p>
              {sections.map((s) => (
                <Card key={s} title={s} flush>
                  <div className="table-wrap">
                    <table className="table">
                      <thead><tr><th>N°</th><th>Parcours</th><th>Résultat attendu</th><th>Statut</th><th>Commentaire</th><th></th></tr></thead>
                      <tbody>
                        {rows.filter((r) => r.section === s).map((t) => <LigneTest key={t.numero} t={t} onFait={liste.reload} />)}
                      </tbody>
                    </table>
                  </div>
                </Card>
              ))}
            </>
          )
        }}
      </Charge>
    </Page>
  )
}
