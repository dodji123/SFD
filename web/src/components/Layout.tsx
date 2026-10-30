import { useState } from 'react'
import { NavLink, Outlet, useLocation } from 'react-router-dom'
import { libellesRole } from '../lib/format'
import { useSession } from '../lib/session'
import { Button } from './ui'

interface Entree { to: string; titre: string; icone: string; perm: string | string[] }
const SECTIONS: { titre: string; items: Entree[] }[] = [
  { titre: 'Pilotage', items: [
    { to: '/', titre: 'Tableau de bord', icone: '📊', perm: 'ref:read' },
    { to: '/rapports', titre: 'Rapports', icone: '📈', perm: 'rapports:read' },
    { to: '/etats', titre: 'États financiers', icone: '🧾', perm: 'compta:read' },
    { to: '/conformite', titre: 'Conformité LBC/FT', icone: '🛡️', perm: 'lbc:read' },
  ] },
  { titre: 'Clients', items: [
    { to: '/clients', titre: 'Clients', icone: '👥', perm: 'ref:read' },
    { to: '/adhesion', titre: 'Adhésion et parts', icone: '🤝', perm: 'epargne:read' },
    { to: '/pieces', titre: 'Pièces justificatives', icone: '📎', perm: 'epargne:read' },
    { to: '/procurations', titre: 'Procurations et chèques', icone: '✍️', perm: ['procuration:write', 'cheque:read'] },
  ] },
  { titre: 'Tontine et collecte', items: [
    { to: '/collecte', titre: 'Collecte du jour', icone: '💰', perm: 'collecte:read' },
    { to: '/sync-validation', titre: 'Synchronisations à valider', icone: '📲', perm: 'collecte:valider' },
    { to: '/cycles', titre: 'Cycles de tontine', icone: '🔄', perm: 'collecte:read' },
    { to: '/demande-retrait', titre: 'Retrait tontine', icone: '💸', perm: 'retrait:request' },
    { to: '/rapport-manquants', titre: 'Manquants non payés', icone: '📋', perm: 'collecte:read' },
    { to: '/controle-carnet', titre: 'Contrôle au carnet', icone: '📖', perm: 'livret:read' },
    { to: '/releves-carnet', titre: 'Relevés carnet et rapprochement', icone: '📒', perm: 'livret:read' },
    { to: '/rapport-collecte', titre: 'Rapport de collecte', icone: '📊', perm: 'rapports:read' },
    { to: '/solde-a-retirer', titre: 'Solde à retirer', icone: '💰', perm: 'rapports:read' },
    { to: '/solde-a-retirer-date', titre: 'Solde à retirer à une date', icone: '📅', perm: 'rapports:read' },
    { to: '/ecarts-versement', titre: 'Collectes et écarts', icone: '📊', perm: 'collecte:read' },
    { to: '/reglement-manquants', titre: 'Règlement des manquants', icone: '💵', perm: 'collecte:read' },
    { to: '/evolution-collectes', titre: 'Évolution des collectes', icone: '📈', perm: 'rapports:read' },
    { to: '/paiements-mobile', titre: 'Mobile money et demandes', icone: '📲', perm: 'paiement-mobile:read' },
    { to: '/carnets', titre: 'Carnets et stock', icone: '📦', perm: 'carnet:read' },
    { to: '/controle-livrets', titre: 'Contrôle des livrets', icone: '📖', perm: 'livret:read' },
    { to: '/liaison', titre: 'Tontine ↔ épargne', icone: '🔗', perm: 'epargne:read' },
  ] },
  { titre: 'Épargne', items: [
    { to: '/epargne', titre: 'Épargne classique', icone: '🏦', perm: 'epargne:read' },
    { to: '/depots', titre: 'Dépôts garantie et terme', icone: '🔒', perm: 'epargne:read' },
    { to: '/deblocages', titre: 'Déblocages', icone: '🔓', perm: 'epargne:read' },
  ] },
  { titre: 'Crédit et recouvrement', items: [
    { to: '/credits', titre: 'Crédits', icone: '💳', perm: 'credit:read' },
    { to: '/credits?onglet=demandes', titre: 'Demande de crédit', icone: '📝', perm: 'credit:request' },
    { to: '/terrain', titre: 'Visites et recouvrements terrain', icone: '🗺️', perm: 'recouvrement:read' },
    { to: '/comites', titre: 'Comité de crédit', icone: '⚖️', perm: 'comite:read' },
    { to: '/recouvrement', titre: 'Recouvrement', icone: '📞', perm: 'recouvrement:read' },
    { to: '/provisions', titre: 'Provisions', icone: '📉', perm: 'provisions:read' },
  ] },
  { titre: 'Caisse et comptabilité', items: [
    { to: '/caisse', titre: 'Caisse', icone: '🧮', perm: 'caisse:read' },
    { to: '/journee', titre: "Journée de l'agence", icone: '🗓️', perm: 'caisse:read' },
    { to: '/operations', titre: 'Opérations et transferts', icone: '🔁', perm: 'operation:read' },
    { to: '/charges-produits', titre: 'Charges et produits', icone: '⚖️', perm: 'operation:read' },
    { to: '/immobilisations', titre: 'Immobilisations et maintenance', icone: '🏗️', perm: 'immobilisation:read' },
    { to: '/stock', titre: 'Stock des fournitures', icone: '📦', perm: 'stock:read' },
    { to: '/roles', titre: 'Rôles et droits', icone: '🔑', perm: 'roles:demander' },
    { to: '/tresorerie', titre: 'Trésorerie', icone: '💵', perm: 'tresorerie:read' },
    { to: '/compta', titre: 'Comptabilité', icone: '📒', perm: 'compta:read' },
  ] },
  { titre: 'Ressources humaines', items: [
    { to: '/grh', titre: 'GRH', icone: '🧑‍💼', perm: ['grh:read', 'grh:self'] },
    { to: '/rh', titre: 'RH et paie', icone: '🧑‍🤝‍🧑', perm: 'rh:read' },
  ] },
  { titre: 'Application et administration', items: [
    { to: '/aide', titre: 'Aide et manuel', icone: '❓', perm: '' },
    { to: '/fiche-tests', titre: 'Fiche des tests manuels', icone: '📋', perm: '' },
    { to: '/application-mobile', titre: 'Application mobile', icone: '📱', perm: 'collecte:read' },
    { to: '/import-clients', titre: 'Import des clients (Excel)', icone: '👥', perm: 'ref:write' },
    { to: '/import-cycles', titre: 'Import des cycles (Excel)', icone: '📥', perm: 'livret:controler' },
    { to: '/admin', titre: 'Administration', icone: '⚙️', perm: ['users:manage', 'params:read', 'audit:read', 'ref:write'] },
  ] },
]

const CLE_REPLIE = 'sfd.menu.replie'
function lireReplie(): string[] {
  try { const v = JSON.parse(localStorage.getItem(CLE_REPLIE) ?? '[]'); return Array.isArray(v) ? v : [] } catch { return [] }
}

export default function Layout() {
  const { user, can, logout, agences, agenceId, choisirAgence } = useSession()
  const [ouvert, setOuvert] = useState(false)
  const [replie, setReplie] = useState<string[]>(lireReplie)
  const { pathname } = useLocation()
  const basculer = (titre: string) => setReplie((r) => {
    const n = r.includes(titre) ? r.filter((x) => x !== titre) : [...r, titre]
    try { localStorage.setItem(CLE_REPLIE, JSON.stringify(n)) } catch { /* stockage indisponible : l'état n'est pas conservé */ }
    return n
  })
  // perm vide : écran accessible à tout utilisateur connecté (ex. l'aide)
  const autorise = (p: string | string[]) => (p === '' ? true : Array.isArray(p) ? p.some(can) : can(p))
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
            const actif = items.some((i) => (i.to === '/' ? pathname === '/' : pathname === i.to || pathname.startsWith(`${i.to}/`)))
            const ferme = replie.includes(s.titre) && !actif
            return (
              <div key={s.titre}>
                <button type="button" className="nav-section nav-toggle" aria-expanded={!ferme} onClick={() => basculer(s.titre)}>
                  <span>{s.titre}</span><span aria-hidden>{ferme ? '▸' : '▾'}</span>
                </button>
                {!ferme && items.map((i) => (
                  <NavLink key={i.to} to={i.to} end={i.to === '/'} className={({ isActive }) => (isActive ? 'active' : '')} onClick={() => setOuvert(false)}>
                    <span className="nav-ico" aria-hidden>{i.icone}</span>{i.titre}
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
