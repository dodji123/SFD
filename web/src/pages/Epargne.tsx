import { useEffect, useRef, useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, xof } from '../lib/format'
import { useProduitsEpargne } from '../lib/hooks'
import { useRecherche } from '../lib/recherche'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, Input, Kpi, Page, Select, Table, useAction, useFetch } from '../components/ui'

interface Trouve {
  client: { id: number; numero: string; nom: string }
  compte: { id: number; numero: string; produit: string; solde: number; disponible: number; solde_minimum: number }
}
interface Jour {
  total_depots: number; total_retraits: number; validee: boolean
  lignes: { id: number; type: 'depot' | 'retrait'; montant: number; compte: string; client_numero: string; client: string; produit: string; libelle: string | null; annulee: boolean; contre_passation: boolean; annulable: boolean }[]
}

export default function Epargne() {
  const { can, agenceId } = useSession()
  const produits = useProduitsEpargne('classique')
  const [jour, setJour] = useState(aujourdhui())
  const [produit, setProduit] = useState('')
  const [op, setOp] = useState<'depot' | 'retrait'>('depot')
  const [suffixe, setSuffixe] = useState('')
  const [montant, setMontant] = useState('')
  const refNumero = useRef<HTMLInputElement>(null)
  const refMontant = useRef<HTMLInputElement>(null)
  const { run, busy } = useAction()
  const tableau = useFetch(() => api.get<Jour>('/api/comptes-epargne/operations', { date: jour }), [jour, agenceId])
  const { data: trouve, erreur } = useRecherche<Trouve>('/api/comptes-epargne/recherche', suffixe && produit ? { suffixe, produit_id: produit, date: jour } : null)

  useEffect(() => { if (!produit && produits.length === 1) setProduit(String(produits[0].id)) }, [produits, produit])
  useEffect(() => { if (trouve) refMontant.current?.focus() }, [trouve])

  const c = trouve?.compte
  const m = Number(montant)
  const insuffisant = op === 'retrait' && !!c && m > c.disponible
  const pret = !!c && m > 0 && !insuffisant && !busy

  const valider = () => void run(
    () => api.post(`/api/comptes-epargne/${c!.id}/${op}`, { montant: m, date_operation: jour }),
    op === 'depot' ? 'Dépôt enregistré' : 'Retrait enregistré',
    () => { setSuffixe(''); setMontant(''); tableau.reload(); setTimeout(() => refNumero.current?.focus(), 0) },
  )

  return (
    <Page title="Épargne classique" subtitle="Dépôts et retraits au guichet pour les membres titulaires d'un compte d'épargne">
      {can('epargne:write') && (
        <Card title="Opération de guichet">
          <div className="row">
            <Field label="Jour"><Input type="date" max={aujourdhui()} value={jour} onChange={(e) => setJour(e.target.value || aujourdhui())} /></Field>
            <Field label="Produit d'épargne">
              <Select value={produit} onChange={(e) => setProduit(e.target.value)}>
                <option value="">— choisir un produit —</option>
                {produits.map((p) => <option key={p.id} value={p.id}>{p.code} — {p.libelle}</option>)}
              </Select>
            </Field>
            <Field label="Opération">
              <Select value={op} onChange={(e) => setOp(e.target.value as 'depot' | 'retrait')}>
                <option value="depot">Dépôt</option>
                <option value="retrait">Retrait</option>
              </Select>
            </Field>
          </div>
          <div className="row">
            <Field label="N° client" hint="Numéro d'ordre seul (ex. 5)">
              <Input ref={refNumero} inputMode="numeric" value={suffixe} placeholder="5" autoComplete="off" onChange={(e) => setSuffixe(e.target.value.replace(/\D/g, ''))} />
            </Field>
            <Field label="Numéro de base du client"><Input readOnly value={trouve?.client.numero ?? ''} /></Field>
            <Field label="Nom et prénom"><Input readOnly value={trouve?.client.nom ?? ''} /></Field>
            <Field label="N° de compte"><Input readOnly value={c?.numero ?? ''} /></Field>
          </div>
          <div className="row">
            <Field label="Solde"><Input readOnly value={c ? xof(c.solde) : ''} /></Field>
            <Field label="Disponible" hint={c ? `Solde minimum conservé : ${xof(c.solde_minimum)}` : undefined}><Input readOnly value={c ? xof(c.disponible) : ''} /></Field>
            <Field label={`Montant du ${op === 'depot' ? 'dépôt' : 'retrait'} (F)`}>
              <Input ref={refMontant} type="number" min={1} value={montant} disabled={!c} aria-label="Montant à saisir"
                onChange={(e) => setMontant(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter' && pret) valider() }} />
            </Field>
            <Button variant="primary" disabled={!pret} onClick={valider}>{op === 'depot' ? 'Valider le dépôt' : 'Valider le retrait'}</Button>
          </div>
          {erreur && <Alert tone="warn">{erreur}{erreur.includes('aucun compte') ? ' Ouvrez-lui un compte depuis sa fiche (adhésion et parts sociales requises).' : ''}</Alert>}
          {insuffisant && c && <Alert tone="bad">Retrait supérieur au solde disponible ({xof(c.disponible)}).</Alert>}
        </Card>
      )}
      <Charge q={tableau}>
        {(d) => (
          <Card title={`Opérations du ${jour.split('-').reverse().join('/')}`} flush actions={
            <>
              {d.validee ? <Badge tone="ok">Journée validée</Badge> : <Badge tone="warn">Journée en cours</Badge>}
              {can('collecte:admin') && (d.validee
                ? <Button small disabled={busy} onClick={() => { const motif = window.prompt('Motif de la réouverture de la journée (obligatoire) :'); if (motif) void run(() => api.post('/api/comptes-epargne/rouvrir-journee', { date: jour, motif }), 'Journée rouverte', tableau.reload) }}>Rouvrir la journée</Button>
                : <Button small variant="primary" disabled={busy || d.lignes.length === 0}
                    onClick={() => { if (window.confirm(`Valider la journée : dépôts ${xof(d.total_depots)}, retraits ${xof(d.total_retraits)}. Plus aucune opération ne pourra être saisie ni annulée ce jour.`)) void run(() => api.post('/api/comptes-epargne/valider-journee', { date: jour }), 'Journée validée', tableau.reload) }}>Valider la journée</Button>)}
            </>}>
            <div className="grid-kpi" style={{ padding: '0 16px' }}>
              <Kpi label="Dépôts" value={xof(d.total_depots)} />
              <Kpi label="Retraits" value={xof(d.total_retraits)} />
              <Kpi label="Opérations" value={d.lignes.length} />
            </div>
            <Table rows={d.lignes} vide="Aucune opération ce jour" cols={[
              { titre: 'N° client', render: (l) => l.client_numero },
              { titre: 'Client', render: (l) => <strong>{l.client}</strong> },
              { titre: 'Compte', render: (l) => <>{l.compte}<div className="muted">{l.produit}</div></> },
              { titre: 'Opération', render: (l) => (l.type === 'depot' ? <Badge tone="ok">Dépôt</Badge> : <Badge tone="warn">Retrait</Badge>) },
              { titre: 'Montant', num: true, render: (l) => (l.annulee ? <s>{xof(l.montant)}</s> : xof(l.montant)) },
              { titre: '', render: (l) => l.annulee ? <span className="muted">annulée</span> : l.contre_passation ? <span className="muted">contre-passation</span>
                : l.annulable && can('epargne:write')
                  ? <Button small variant="danger" disabled={busy} onClick={() => { if (window.confirm(`Annuler ${l.type === 'depot' ? 'le dépôt' : 'le retrait'} de ${xof(l.montant)} de ${l.client} ? Une écriture inverse est enregistrée.`)) void run(() => api.post(`/api/comptes-epargne/operations/${l.id}/annuler`), 'Opération annulée', tableau.reload) }}>Annuler</Button>
                  : <span className="muted">{d.validee ? 'validée' : ''}</span> },
            ]} />
          </Card>
        )}
      </Charge>
    </Page>
  )
}
