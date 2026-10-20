import { useState } from 'react'
import { NavLink, Outlet } from 'react-router-dom'
import { libellesRole } from '../lib/format'
import { useSession } from '../lib/session'
import { Button } from './ui'

interface Entree { to: string; titre: string; perm: string | string[] }
const SECTIONS: { titre: string; items: Entree[] }[] = [
  { titre: 'Exploitation', items: [
    { to: '/', titre: 'Tableau de bord', perm: 'ref:read' },
    { to: '/clients', titre: 'Clients', perm: 'ref:read' },
    { to: '/cycles', titre: 'Cycles de tontine', perm: 'collecte:read' },
    { to: '/collecte', titre: 'Collecte du jour', perm: 'collecte:read' },
    { to: '/retraits', titre: 'Retraits et écarts', perm: 'collecte:read' },
    { to: '/adhesion', titre: 'Adhésion et parts', perm: 'epargne:read' },
    { to: '/epargne', titre: 'Épargne classique', perm: 'epargne:read' },
    { to: '/liaison', titre: 'Tontine ↔ épargne', perm: 'epargne:read' },
    { to: '/depots', titre: 'Dépôts garantie et terme', perm: 'epargne:read' },
    { to: '/deblocages', titre: 'Déblocages', perm: 'epargne:read' },
    { to: '/pieces', titre: 'Pièces justificatives', perm: 'epargne:read' },
  ] },
  { titre: 'Crédit et caisse', items: [
    { to: '/credits', titre: 'Crédits', perm: 'credit:read' },
    { to: '/comites', titre: 'Comité de crédit', perm: 'comite:read' },
    { to: '/recouvrement', titre: 'Recouvrement', perm: 'recouvrement:read' },
    { to: '/procurations', titre: 'Procurations et chèques', perm: ['procuration:write', 'cheque:read'] },
    { to: '/caisse', titre: 'Caisse', perm: 'caisse:read' },
    { to: '/tresorerie', titre: 'Trésorerie', perm: 'tresorerie:read' },
    { to: '/provisions', titre: 'Provisions', perm: 'provisions:read' },
  ] },
  { titre: 'Gestion', items: [
    { to: '/rapports', titre: 'Rapports', perm: 'rapports:read' },
    { to: '/compta', titre: 'Comptabilité', perm: 'compta:read' },
    { to: '/etats', titre: 'États financiers', perm: 'compta:read' },
    { to: '/conformite', titre: 'Conformité LBC/FT', perm: 'lbc:read' },
    { to: '/rh', titre: 'RH et paie', perm: 'rh:read' },
    { to: '/admin', titre: 'Administration', perm: ['users:manage', 'params:read', 'audit:read', 'ref:write'] },
  ] },
]

export default function Layout() {
  const { user, can, logout, agences, agenceId, choisirAgence } = useSession()
  const [ouvert, setOuvert] = useState(false)
  const autorise = (p: string | string[]) => (Array.isArray(p) ? p.some(can) : can(p))
  return (
    <div className="app">
      <aside className={`sidebar ${ouvert ? 'ouverte' : ''}`} aria-label="Navigation principale">
        <div className="brand">
          <div className="brand-mark" aria-hidden>S</div>
          <div>Plateforme SFD<small>Microfinance UMOA</small></div>
        </div>
        <nav className="nav">
          {SECTIONS.map((s) => {
            const items = s.items.filter((i) => autorise(i.perm))
            if (!items.length) return null
            return (
              <div key={s.titre}>
                <div className="nav-section">{s.titre}</div>
                {items.map((i) => (
                  <NavLink key={i.to} to={i.to} end={i.to === '/'} className={({ isActive }) => (isActive ? 'active' : '')} onClick={() => setOuvert(false)}>
                    {i.titre}
                  </NavLink>
                ))}
              </div>
            )
          })}
        </nav>
      </aside>
      <div className="main">
        <header className="topbar">
          <Button small className="btn btn-sm menu-btn" onClick={() => setOuvert((o) => !o)} aria-label="Ouvrir le menu">☰</Button>
          {user?.agence_id === null ? (
            <label className="row" style={{ gap: 8, alignItems: 'center' }}>
              <span className="muted">Agence</span>
              <select className="input" style={{ width: 'auto', minHeight: 32 }} value={agenceId ?? ''} onChange={(e) => choisirAgence(Number(e.target.value))} aria-label="Agence de travail">
                {agences.map((a) => <option key={a.id} value={a.id}>{a.code} — {a.libelle}</option>)}
              </select>
            </label>
          ) : (
            <span className="muted">{agences.find((a) => a.id === user?.agence_id)?.libelle}</span>
          )}
          <span className="spacer" />
          <span className="user-chip"><strong>{user?.nom}</strong> <span className="muted user-role">· {libellesRole[user?.role ?? ''] ?? user?.role}</span></span>
          <Button small onClick={logout}>Déconnexion</Button>
        </header>
        <main className="content">
          <Outlet />
        </main>
      </div>
    </div>
  )
}
