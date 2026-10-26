import { Navigate, Route, Routes, useLocation } from 'react-router-dom'
import Garde from './components/Garde'
import Layout from './components/Layout'
import { Spinner } from './components/ui'
import { useSession } from './lib/session'
import Admin from './pages/Admin'
import Caisse from './pages/Caisse'
import ClientDetail from './pages/ClientDetail'
import Clients from './pages/Clients'
import Collecte from './pages/Collecte'
import Comites from './pages/Comites'
import Recouvrement from './pages/Recouvrement'
import Grh from './pages/Grh'
import ApplicationMobile from './pages/ApplicationMobile'
import ControleLivrets from './pages/ControleLivrets'
import Carnets from './pages/Carnets'
import PaiementsMobile from './pages/PaiementsMobile'
import OperationsCaisse from './pages/OperationsCaisse'
import ChargesProduits from './pages/ChargesProduits'
import Roles from './pages/Roles'
import Immobilisations from './pages/Immobilisations'
import Aide from './pages/Aide'
import Journee from './pages/Journee'
import FicheTests from './pages/FicheTests'
import DemandeRetraitTontine from './pages/DemandeRetraitTontine'
import Stock from './pages/Stock'
import ProcurationsCheques from './pages/ProcurationsCheques'
import Epargne from './pages/Epargne'
import Adhesion from './pages/Adhesion'
import Liaison from './pages/Liaison'
import DepotsBloques from './pages/DepotsBloques'
import Deblocages from './pages/Deblocages'
import Pieces from './pages/Pieces'
import Compta from './pages/Compta'
import CreditDetail from './pages/CreditDetail'
import Credits from './pages/Credits'
import CycleDetail from './pages/CycleDetail'
import Cycles from './pages/Cycles'
import Dashboard from './pages/Dashboard'
import Conformite from './pages/Conformite'
import EspaceClient from './pages/EspaceClient'
import Etats from './pages/Etats'
import Login from './pages/Login'
import MobileApp from './mobile/MobileApp'
import SyncValidation from './pages/SyncValidation'
import { ChangementObligatoire, Reinitialiser } from './pages/MotDePasse'
import { EnrolementTotp } from './pages/Totp'
import Provisions from './pages/Provisions'
import Rapports from './pages/Rapports'
import Retraits from './pages/Retraits'
import Rh from './pages/Rh'
import Tresorerie from './pages/Tresorerie'

export default function App() {
  const { user, chargement } = useSession()
  const { pathname } = useLocation()
  // l'espace client est indépendant de la session du personnel (autre jeton, autre écran)
  if (pathname === '/espace' || pathname.startsWith('/espace/')) return <EspaceClient />
  if (pathname === '/m' || pathname.startsWith('/m/')) return <MobileApp />   // application de collecte (PWA), écran étroit et hors ligne
  if (pathname === '/reinitialiser') return <Reinitialiser />
  if (chargement) return <Spinner />
  if (!user) return <Login />
  if (user.doit_changer_mdp) return <ChangementObligatoire />
  if (user.totp_a_enroler) return <EnrolementTotp />
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<Dashboard />} />
        <Route path="clients" element={<Clients />} />
        <Route path="clients/:id" element={<ClientDetail />} />
        <Route path="cycles" element={<Garde perm="collecte:read"><Cycles /></Garde>} />
        <Route path="cycles/:id" element={<Garde perm="collecte:read"><CycleDetail /></Garde>} />
        <Route path="collecte" element={<Garde perm="collecte:read"><Collecte /></Garde>} />
        <Route path="sync-validation" element={<Garde perm="collecte:valider"><SyncValidation /></Garde>} />
        <Route path="epargne" element={<Garde perm="epargne:read"><Epargne /></Garde>} />
        <Route path="adhesion" element={<Garde perm="epargne:read"><Adhesion /></Garde>} />
        <Route path="liaison" element={<Garde perm="epargne:read"><Liaison /></Garde>} />
        <Route path="depots" element={<Garde perm="epargne:read"><DepotsBloques /></Garde>} />
        <Route path="deblocages" element={<Garde perm="epargne:read"><Deblocages /></Garde>} />
        <Route path="pieces" element={<Garde perm="epargne:read"><Pieces /></Garde>} />
        <Route path="retraits" element={<Garde perm="collecte:read"><Retraits /></Garde>} />
        <Route path="credits" element={<Garde perm="credit:read"><Credits /></Garde>} />
        <Route path="credits/:id" element={<Garde perm="credit:read"><CreditDetail /></Garde>} />
        <Route path="comites" element={<Garde perm="comite:read"><Comites /></Garde>} />
        <Route path="recouvrement" element={<Garde perm="recouvrement:read"><Recouvrement /></Garde>} />
        <Route path="procurations" element={<Garde perm={['procuration:write', 'cheque:read']}><ProcurationsCheques /></Garde>} />
        <Route path="caisse" element={<Garde perm="caisse:read"><Caisse /></Garde>} />
        <Route path="tresorerie" element={<Garde perm="tresorerie:read"><Tresorerie /></Garde>} />
        <Route path="rapports" element={<Garde perm="rapports:read"><Rapports /></Garde>} />
        <Route path="compta" element={<Garde perm="compta:read"><Compta /></Garde>} />
        <Route path="etats" element={<Garde perm="compta:read"><Etats /></Garde>} />
        <Route path="provisions" element={<Garde perm="provisions:read"><Provisions /></Garde>} />
        <Route path="conformite" element={<Garde perm="lbc:read"><Conformite /></Garde>} />
        <Route path="grh" element={<Garde perm={['grh:read', 'grh:self']}><Grh /></Garde>} />
        <Route path="application-mobile" element={<Garde perm="collecte:read"><ApplicationMobile /></Garde>} />
        <Route path="controle-livrets" element={<Garde perm="livret:read"><ControleLivrets /></Garde>} />
        <Route path="carnets" element={<Garde perm="carnet:read"><Carnets /></Garde>} />
        <Route path="paiements-mobile" element={<Garde perm="paiement-mobile:read"><PaiementsMobile /></Garde>} />
        <Route path="operations" element={<Garde perm="operation:read"><OperationsCaisse /></Garde>} />
        <Route path="charges-produits" element={<Garde perm="operation:read"><ChargesProduits /></Garde>} />
        <Route path="roles" element={<Garde perm="roles:demander"><Roles /></Garde>} />
        <Route path="immobilisations" element={<Garde perm="immobilisation:read"><Immobilisations /></Garde>} />
        <Route path="aide" element={<Aide />} />
        <Route path="journee" element={<Garde perm="caisse:read"><Journee /></Garde>} />
        <Route path="fiche-tests" element={<FicheTests />} />
        <Route path="demande-retrait" element={<Garde perm="retrait:request"><DemandeRetraitTontine /></Garde>} />
        <Route path="stock" element={<Garde perm="stock:read"><Stock /></Garde>} />
        <Route path="rh" element={<Garde perm="rh:read"><Rh /></Garde>} />
        <Route path="admin" element={<Garde perm={['users:manage', 'params:read', 'audit:read', 'ref:write']}><Admin /></Garde>} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  )
}
