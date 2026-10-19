import { useEffect, useRef, useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, xof } from '../lib/format'
import { useRecherche } from '../lib/recherche'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, Input, Kpi, Page, Table, useAction, useFetch } from '../components/ui'

interface Situation {
  client: { id: number; numero: string; nom: string }
  adhesion: { numero: string; date_adhesion: string; statut: string; nb_parts: number; capital_souscrit: number } | null
  remboursement: { nb_parts: number; montant: number; date_operation: string } | null
  en_regle: boolean; valeur_part: number; parts_minimum: number; droit_adhesion: number; obligatoire: boolean
}
interface Jour { total: number; lignes: { nature: 'adhesion' | 'parts'; id: number; client_numero: string; client: string; reference: string; montant: number; nb_parts: number | null }[] }

export default function Adhesion() {
  const { can, agenceId } = useSession()
  const [jour, setJour] = useState(aujourdhui())
  const [suffixe, setSuffixe] = useState('')
  const [nb, setNb] = useState('')
  const refNumero = useRef<HTMLInputElement>(null)
  const refParts = useRef<HTMLInputElement>(null)
  const { run, busy } = useAction()
  const tableau = useFetch(() => api.get<Jour>('/api/adhesions/jour', { date: jour }), [jour, agenceId])
  const { data: s, erreur, recharger } = useRecherche<Situation>('/api/adhesions/recherche', suffixe ? { suffixe } : null)

  useEffect(() => { if (s) setNb(String(Math.max(s.parts_minimum - (s.adhesion?.nb_parts ?? 0), 1))) }, [s])
  useEffect(() => { if (s?.adhesion) refParts.current?.focus() }, [s])

  const n = Number(nb)
  const apres = () => { recharger(); tableau.reload() }
  const adherer = () => void run(() => api.post('/api/adhesions', { client_id: s!.client.id, date: jour }), 'Adhésion enregistrée', apres)
  const sortir = () => {
    if (window.confirm(`Sortie de ${s!.client.nom} : ${xof(s!.adhesion?.capital_souscrit ?? 0)} de parts seront remboursés et l'adhésion radiée. Continuer ?`))
      void run(() => api.post('/api/adhesions/sortie', { client_id: s!.client.id, date: jour }), 'Membre radié, parts remboursées', apres)
  }
  const souscrire = () => void run(() => api.post('/api/adhesions/parts', { client_id: s!.client.id, nb_parts: n, date: jour }), 'Parts souscrites',
    () => { setSuffixe(''); setNb(''); tableau.reload(); setTimeout(() => refNumero.current?.focus(), 0) })

  return (
    <Page title="Adhésion et parts sociales" subtitle="Un client devient membre en adhérant et en souscrivant au moins le nombre minimal de parts ; l'épargne classique est réservée aux membres">
      {can('adhesion:write') && (
        <Card title="Adhésion d'un membre">
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
                <Kpi label="Situation" value={s.en_regle ? 'Membre en règle' : s.adhesion ? 'Adhérent, parts insuffisantes' : 'Pas encore membre'} tone={s.en_regle ? undefined : 'warn'} />
                <Kpi label="Parts détenues" value={`${s.adhesion?.nb_parts ?? 0} / ${s.parts_minimum} minimum`} />
                <Kpi label="Capital souscrit" value={xof(s.adhesion?.capital_souscrit ?? 0)} />
                <Kpi label="Valeur d'une part" value={xof(s.valeur_part)} />
              </div>
              {s.remboursement && <Alert tone="info">Membre radié : {xof(s.remboursement.montant)} de parts remboursés ({s.remboursement.nb_parts} part(s)) le {s.remboursement.date_operation.split('-').reverse().join('/')}.</Alert>}
              {!s.adhesion ? (
                <div className="row">
                  <Alert tone="info">Pas d'adhésion. Droit d'adhésion à encaisser : {xof(s.droit_adhesion)}.</Alert>
                  <Button variant="primary" disabled={busy} onClick={adherer}>Enregistrer l'adhésion</Button>
                </div>
              ) : (
                <div className="row">
                  <Field label={`Adhésion ${s.adhesion.numero}`}><Input readOnly value={`depuis le ${s.adhesion.date_adhesion.split('-').reverse().join('/')}`} /></Field>
                  <Field label="Parts à souscrire" hint={`Montant : ${xof(n > 0 ? n * s.valeur_part : 0)}`}>
                    <Input ref={refParts} type="number" min={1} value={nb} aria-label="Nombre de parts" onChange={(e) => setNb(e.target.value)}
                      onKeyDown={(e) => { if (e.key === 'Enter' && n > 0 && !busy) souscrire() }} />
                  </Field>
                  <Button variant="primary" disabled={busy || !(n > 0) || s.adhesion.statut !== 'active'} onClick={souscrire}>Valider la souscription</Button>
                  {can('collecte:admin') && s.adhesion.statut === 'active' && <Button variant="danger" disabled={busy} onClick={sortir}>Sortie du membre</Button>}
                </div>
              )}
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
