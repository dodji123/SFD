import type { ReactNode } from 'react'
import { useSession } from '../lib/session'
import { Alert, Page } from './ui'

/** Affiche la page si l'utilisateur a l'une des permissions demandées, sinon un message d'accès refusé.
 *  (Le contrôle réel reste côté API : ceci ne sert qu'à éviter une page d'erreurs.) */
export default function Garde({ perm, children }: { perm: string | string[]; children: ReactNode }) {
  const { can } = useSession()
  const ok = Array.isArray(perm) ? perm.some(can) : can(perm)
  if (ok) return <>{children}</>
  return (
    <Page title="Accès refusé">
      <Alert tone="warn">Votre rôle ne permet pas d'accéder à cette page.</Alert>
    </Page>
  )
}
