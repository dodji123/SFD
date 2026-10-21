import { useEffect, useState } from 'react'
import { Alert, Button, Card, Page } from '../components/ui'

interface EvenementInstallation extends Event { prompt: () => Promise<void>; userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }> }

/** Téléchargement / installation de l'application mobile de collecte (PWA servie sous /m). */
export default function ApplicationMobile() {
  const lien = `${window.location.origin}/m`
  const [invite, setInvite] = useState<EvenementInstallation | null>(null)
  const [installee, setInstallee] = useState(window.matchMedia('(display-mode: standalone)').matches)
  const [copie, setCopie] = useState(false)
  const securise = window.isSecureContext

  useEffect(() => {
    const avant = (e: Event) => { e.preventDefault(); setInvite(e as EvenementInstallation) }
    const apres = () => { setInstallee(true); setInvite(null) }
    window.addEventListener('beforeinstallprompt', avant)
    window.addEventListener('appinstalled', apres)
    return () => { window.removeEventListener('beforeinstallprompt', avant); window.removeEventListener('appinstalled', apres) }
  }, [])

  const installer = async () => {
    if (!invite) return
    await invite.prompt()
    const choix = await invite.userChoice
    if (choix.outcome === 'accepted') setInstallee(true)
    setInvite(null)
  }
  const copier = async () => {
    try { await navigator.clipboard.writeText(lien); setCopie(true); setTimeout(() => setCopie(false), 2000) } catch { window.prompt('Copiez ce lien :', lien) }
  }

  return (
    <Page title="Application mobile" subtitle="Application de collecte pour les agents et collectrices : saisie sur le terrain, même sans réseau">
      {installee && <Alert tone="info">L'application est déjà installée sur cet appareil.</Alert>}
      {!securise && <Alert tone="warn">Cette adresse n'est pas en HTTPS : le navigateur n'active pas le mode hors ligne ni l'installation. Ouvrez la plateforme par son adresse HTTPS officielle pour installer l'application.</Alert>}
      <div className="grid-2">
        <Card title="Installer sur ce téléphone">
          <div className="stack">
            <p style={{ margin: 0 }}>Ouvrez cette page depuis le téléphone de l'agent, puis installez l'application sur l'écran d'accueil.</p>
            <div className="row">
              <Button variant="primary" disabled={!invite || installee} onClick={() => void installer()}>Installer l'application</Button>
              <a className="btn" href="/m">Ouvrir sans installer</a>
            </div>
            {!invite && !installee && <p className="muted" style={{ margin: 0 }}>Le bouton s'active sur Chrome ou Edge (Android) en HTTPS. Sinon, suivez les étapes ci-dessous.</p>}
          </div>
        </Card>
        <Card title="Lien à envoyer à l'agent">
          <div className="stack">
            <code style={{ wordBreak: 'break-all' }}>{lien}</code>
            <div><Button onClick={() => void copier()}>{copie ? 'Lien copié' : 'Copier le lien'}</Button></div>
            <p className="muted" style={{ margin: 0 }}>L'agent se connecte avec son propre compte ; il ne voit que les clients de son périmètre.</p>
          </div>
        </Card>
      </div>
      <Card title="Étapes d'installation">
        <div className="stack">
          <div><strong>Android (Chrome)</strong><ol style={{ margin: '4px 0 0' }}><li>Ouvrez le lien ci-dessus.</li><li>Menu ⋮ → « Installer l'application » (ou « Ajouter à l'écran d'accueil »).</li><li>Lancez SFD Collecte depuis l'écran d'accueil.</li></ol></div>
          <div><strong>iPhone (Safari)</strong><ol style={{ margin: '4px 0 0' }}><li>Ouvrez le lien dans Safari.</li><li>Bouton Partager → « Sur l'écran d'accueil ».</li><li>Lancez l'application depuis l'icône ajoutée.</li></ol></div>
          <div><strong>Utilisation hors ligne</strong><p style={{ margin: '4px 0 0' }}>Les collectes saisies sans réseau restent sur le téléphone, puis sont envoyées automatiquement au retour de la connexion. Les refus éventuels (cycle clos, date hors délai) sont listés dans l'application.</p></div>
        </div>
      </Card>
    </Page>
  )
}
