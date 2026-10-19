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
  if (chargement) return <Spinner />
  if (!user) return <Login />
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<Dashboard />} />
        <Route path="clients" element={<Clients />} />
        <Route path="clients/:id" element={<ClientDetail />} />
        <Route path="cycles" element={<Garde perm="collecte:read"><Cycles /></Garde>} />
        <Route path="cycles/:id" element={<Garde perm="collecte:read"><CycleDetail /></Garde>} />
        <Route path="collecte" element={<Garde perm="collecte:read"><Collecte /></Garde>} />
        <Route path="epargne" element={<Garde perm="epargne:read"><Epargne /></Garde>} />
        <Route path="adhesion" element={<Garde perm="epargne:read"><Adhesion /></Garde>} />
        <Route path="liaison" element={<Garde perm="epargne:read"><Liaison /></Garde>} />
        <Route path="depots" element={<Garde perm="epargne:read"><DepotsBloques /></Garde>} />
        <Route path="deblocages" element={<Garde perm="epargne:read"><Deblocages /></Garde>} />
        <Route path="pieces" element={<Garde perm="epargne:read"><Pieces /></Garde>} />
        <Route path="retraits" element={<Garde perm="collecte:read"><Retraits /></Garde>} />
        <Route path="credits" element={<Garde perm="credit:read"><Credits /></Garde>} />
        <Route path="credits/:id" element={<Garde perm="credit:read"><CreditDetail /></Garde>} />
        <Route path="caisse" element={<Garde perm="caisse:read"><Caisse /></Garde>} />
        <Route path="tresorerie" element={<Garde perm="tresorerie:read"><Tresorerie /></Garde>} />
        <Route path="rapports" element={<Garde perm="rapports:read"><Rapports /></Garde>} />
        <Route path="compta" element={<Garde perm="compta:read"><Compta /></Garde>} />
        <Route path="etats" element={<Garde perm="compta:read"><Etats /></Garde>} />
        <Route path="provisions" element={<Garde perm="provisions:read"><Provisions /></Garde>} />
        <Route path="conformite" element={<Garde perm="lbc:read"><Conformite /></Garde>} />
        <Route path="rh" element={<Garde perm="rh:read"><Rh /></Garde>} />
        <Route path="admin" element={<Garde perm={['users:manage', 'params:read', 'audit:read', 'ref:write']}><Admin /></Garde>} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  )
}
