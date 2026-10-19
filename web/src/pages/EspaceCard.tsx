import { useState } from 'react'
import { api } from '../lib/api'
import { useSession } from '../lib/session'
import { Alert, Badge, Button, Card, Charge, Field, FormModal, Input, Table, useAction, useFetch } from '../components/ui'

interface Consentements { actuel: Record<string, boolean>; historique: { id: number; finalite: string; accorde: boolean; canal: string; cree_le: string }[] }
interface Acces {
  existe: boolean; actif?: boolean; pin_provisoire?: boolean; echecs?: number; verrouille?: boolean; derniere_connexion?: string | null
  journal: { cree_le: string; evenement: string; ip: string | null; detail: string | null }[]
}

const FINALITES: [string, string][] = [['portail', 'Espace client en ligne'], ['sms_rappel', 'SMS de rappel d\'échéance'], ['traitement_donnees', 'Traitement des données personnelles']]

export default function EspaceCard({ clientId }: { clientId: number }) {
  const { can } = useSession()
  const consent = useFetch(() => api.get<Consentements>(`/api/clients/${clientId}/consentements`), [clientId])
  const acces = useFetch(() => api.get<Acces>(`/api/clients/${clientId}/acces`), [clientId])
  const { run, busy } = useAction()
  const [pin, setPin] = useState<string | null>(null)
  const [blocage, setBlocage] = useState(false)
  const recharger = () => { consent.reload(); acces.reload() }
  const enregistrer = (finalite: string, accorde: boolean) =>
    void run(() => api.post(`/api/clients/${clientId}/consentements`, { finalite, accorde, canal: 'papier' }), accorde ? 'Consentement enregistré' : 'Consentement retiré', recharger)
  return (
    <Card title="Espace client en ligne" flush actions={can('acces_client:manage') && acces.data && (
      <>
        <Button small variant="primary" disabled={busy} onClick={() => void run(async () => { const r = await api.post<{ pin_provisoire: string }>(`/api/clients/${clientId}/acces/activer`); setPin(r.pin_provisoire) },
          acces.data!.existe ? 'Accès réinitialisé' : 'Accès ouvert', recharger)}>{acces.data.existe ? 'Réinitialiser le PIN' : 'Ouvrir l\'accès'}</Button>
        {acces.data.existe && acces.data.actif && <Button small variant="danger" onClick={() => setBlocage(true)}>Bloquer l'accès</Button>}
      </>
    )}>
      <div className="card-b stack">
        <Charge q={consent}>
          {(c) => (
            <Table rows={FINALITES} cols={[
              { titre: 'Consentement du client', render: ([, lib]) => lib },
              { titre: 'État', render: ([k]) => (c.actuel[k] ? <Badge tone="ok">Accordé</Badge> : <Badge tone="warn">{k in c.actuel ? 'Retiré' : 'Non recueilli'}</Badge>) },
              { titre: '', render: ([k]) => can('consent:write') && (c.actuel[k]
                ? <Button small disabled={busy} onClick={() => { if (window.confirm('Retirer ce consentement ? Pour « espace client », l\'accès sera coupé immédiatement.')) enregistrer(k, false) }}>Retirer</Button>
                : <Button small disabled={busy} onClick={() => enregistrer(k, true)}>Recueilli (formulaire signé)</Button>) },
            ]} />
          )}
        </Charge>
        <Charge q={acces}>
          {(a) => (
            <>
              <div className="actions">
                {!a.existe ? <Badge>Accès non ouvert</Badge> : a.actif ? <Badge tone="ok">Accès actif</Badge> : <Badge tone="bad">Accès bloqué</Badge>}
                {a.existe && a.pin_provisoire && <Badge tone="warn">PIN provisoire non changé</Badge>}
                {a.verrouille && <Badge tone="bad">Verrouillé après échecs</Badge>}
                {a.derniere_connexion && <span className="muted">Dernière connexion : {new Date(a.derniere_connexion).toLocaleString('fr-FR')}</span>}
              </div>
              {!a.existe && <Alert tone="info">Conditions d'ouverture : client actif, KYC complet, téléphone renseigné, consentement « espace client » recueilli et aucune alerte de sanction. Le client se connecte avec son numéro, un PIN et un code reçu par SMS.</Alert>}
              {a.journal.length > 0 && (
                <Table rows={a.journal.slice(0, 8)} cols={[
                  { titre: 'Date', render: (j) => new Date(j.cree_le).toLocaleString('fr-FR') },
                  { titre: 'Événement', render: (j) => j.evenement },
                  { titre: 'Adresse IP', render: (j) => j.ip ?? '—' },
                  { titre: 'Détail', render: (j) => j.detail ?? '' },
                ]} />
              )}
            </>
          )}
        </Charge>
      </div>
      {pin && (
        <FormModal titre="PIN provisoire" onClose={() => setPin(null)} busy={false} valider="J'ai remis le PIN au client" onSubmit={() => setPin(null)}>
          <div style={{ gridColumn: '1 / -1' }}>
            <Alert tone="warn">Ce PIN n'est affiché qu'une seule fois. Remettez-le au client en main propre ; il devra le changer à sa première connexion. Ne l'envoyez pas par message.</Alert>
            <p style={{ fontSize: '2rem', letterSpacing: '0.3em', textAlign: 'center', fontWeight: 700 }}>{pin}</p>
          </div>
        </FormModal>
      )}
      {blocage && <Blocage clientId={clientId} onClose={() => setBlocage(false)} onFait={() => { setBlocage(false); recharger() }} />}
    </Card>
  )
}

function Blocage({ clientId, onClose, onFait }: { clientId: number; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [motif, setMotif] = useState('')
  return (
    <FormModal titre="Bloquer l'accès du client" onClose={onClose} busy={busy} valider="Bloquer"
      onSubmit={() => void run(() => api.post(`/api/clients/${clientId}/acces/bloquer`, { motif: motif || null }), 'Accès bloqué', onFait)}>
      <Field label="Motif" hint="Téléphone perdu, fraude suspectée, demande du client…"><Input value={motif} onChange={(e) => setMotif(e.target.value)} /></Field>
      <p className="muted" style={{ gridColumn: '1 / -1', margin: 0 }}>Les sessions déjà ouvertes cessent aussitôt. Pour rouvrir l'accès, un nouveau PIN provisoire sera généré.</p>
    </FormModal>
  )
}
