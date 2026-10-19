import { useEffect, useRef, useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, xof } from '../lib/format'
import { useProduitsEpargne } from '../lib/hooks'
import { useRecherche } from '../lib/recherche'
import { useSession } from '../lib/session'
import { ChampClient, FiltreTableau, estNumero, filtrer } from '../components/ChampClient'
import { Alert, Badge, Button, Card, Charge, Field, Input, Kpi, Page, Select, Table, Tabs, useAction, useFetch } from '../components/ui'

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
  const [onglet, setOnglet] = useState<'depot' | 'retrait'>('depot')
  const [filtre, setFiltre] = useState('')
  const { run, busy } = useAction()
  const tableau = useFetch(() => api.get<Jour>('/api/comptes-epargne/operations', { date: jour }), [jour, agenceId])

  useEffect(() => { if (!produit && produits.length === 1) setProduit(String(produits[0].id)) }, [produits, produit])

  return (
    <Page title="Épargne classique" subtitle="Dépôts et retraits au guichet pour les membres titulaires d'un compte d'épargne">
      {can('epargne:write') && (
        <Card title="Guichet">
          <div className="row">
            <Field label="Jour"><Input type="date" max={aujourdhui()} value={jour} onChange={(e) => setJour(e.target.value || aujourdhui())} /></Field>
            <Field label="Produit d'épargne">
              <Select value={produit} onChange={(e) => setProduit(e.target.value)}>
                <option value="">— choisir un produit —</option>
                {produits.map((p) => <option key={p.id} value={p.id}>{p.code} — {p.libelle}</option>)}
              </Select>
            </Field>
          </div>
          <Tabs actif={onglet} onChange={(id) => setOnglet(id as 'depot' | 'retrait')} tabs={[{ id: 'depot', titre: 'Dépôt' }, { id: 'retrait', titre: 'Retrait' }]} />
          <FormulaireOperation key={`${onglet}-${agenceId}`} op={onglet} jour={jour} produit={produit} onFait={tableau.reload} />
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
            <FiltreTableau valeur={filtre} onChange={setFiltre} />
            <Table rows={filtrer(d.lignes, filtre, (l) => [l.client, l.client_numero, l.compte])} vide={filtre ? 'Aucune opération ne correspond au filtre' : 'Aucune opération ce jour'} cols={[
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

/** Formulaire d'une opération : le dépôt et le retrait ont chacun leur formulaire (champs et contrôles propres). */
function FormulaireOperation({ op, jour, produit, onFait }: { op: 'depot' | 'retrait'; jour: string; produit: string; onFait: () => void }) {
  const depot = op === 'depot'
  const [suffixe, setSuffixe] = useState('')
  const [montant, setMontant] = useState('')
  const [libelle, setLibelle] = useState('')
  const refNumero = useRef<HTMLInputElement>(null)
  const refMontant = useRef<HTMLInputElement>(null)
  const { run, busy } = useAction()
  const { data: trouve, erreur } = useRecherche<Trouve>('/api/comptes-epargne/recherche', estNumero(suffixe) && produit ? { suffixe, produit_id: produit, date: jour } : null)
  useEffect(() => { if (trouve) refMontant.current?.focus() }, [trouve])

  const c = trouve?.compte
  const m = Number(montant)
  const insuffisant = !depot && !!c && m > c.disponible
  const pret = !!c && m > 0 && !insuffisant && !busy
  const valider = () => void run(
    () => api.post(`/api/comptes-epargne/${c!.id}/${op}`, { montant: m, date_operation: jour, libelle: libelle.trim() || null }),
    depot ? 'Dépôt enregistré' : 'Retrait enregistré',
    () => { setSuffixe(''); setMontant(''); setLibelle(''); onFait(); setTimeout(() => refNumero.current?.focus(), 0) },
  )

  return (
    <>
      <div className="row">
        <ChampClient valeur={suffixe} onChange={setSuffixe} inputRef={refNumero} />
        <Field label="Numéro de base du client"><Input readOnly value={trouve?.client.numero ?? ''} /></Field>
        <Field label="Nom et prénom"><Input readOnly value={trouve?.client.nom ?? ''} /></Field>
        <Field label="N° de compte"><Input readOnly value={c?.numero ?? ''} /></Field>
      </div>
      <div className="row">
        <Field label="Solde"><Input readOnly value={c ? xof(c.solde) : ''} /></Field>
        {!depot && <Field label="Disponible au retrait" hint={c ? `Solde minimum conservé : ${xof(c.solde_minimum)}, garanties bloquées déduites` : undefined}><Input readOnly value={c ? xof(c.disponible) : ''} /></Field>}
        <Field label={depot ? 'Montant du dépôt (F)' : 'Montant du retrait (F)'}>
          <Input ref={refMontant} type="number" min={1} value={montant} disabled={!c} aria-label="Montant à saisir"
            onChange={(e) => setMontant(e.target.value)} onKeyDown={(e) => { if (e.key === 'Enter' && pret) valider() }} />
        </Field>
        <Field label={depot ? 'Origine des fonds (facultatif)' : 'Motif du retrait (facultatif)'}>
          <Input value={libelle} maxLength={120} disabled={!c} onChange={(e) => setLibelle(e.target.value)} />
        </Field>
        <Button variant="primary" disabled={!pret} onClick={valider}>{depot ? 'Valider le dépôt' : 'Valider le retrait'}</Button>
      </div>
      {erreur && <Alert tone="warn">{erreur}{erreur.includes('aucun compte') ? ' Ouvrez-lui un compte depuis la page Adhésion et parts (adhésion et parts sociales requises).' : ''}</Alert>}
      {insuffisant && c && <Alert tone="bad">Retrait supérieur au solde disponible ({xof(c.disponible)}).</Alert>}
    </>
  )
}
