import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { api, ApiError, session } from './api'

// Instantané du profil (sans jeton) : permet de rouvrir l'application mobile hors réseau tant que le jeton de la session est valide.
const SNAP_KEY = 'sfd_profil'
interface Instantane { user: Utilisateur; perms: string[]; agences: Agence[] }
function lireInstantane(): Instantane | null {
  try { return JSON.parse(sessionStorage.getItem(SNAP_KEY) ?? 'null') } catch { return null }
}
function ecrireInstantane(s: Instantane | null) {
  try { if (s) sessionStorage.setItem(SNAP_KEY, JSON.stringify(s)); else sessionStorage.removeItem(SNAP_KEY) } catch { /* stockage indisponible */ }
}

export interface Utilisateur {
  id: number
  login: string
  nom: string
  role: string
  agence_id: number | null
  reseau_id: number | null
  agent_id: number | null
  collectrice_id: number | null
  doit_changer_mdp: boolean
  totp_actif: boolean
  totp_a_enroler: boolean
  agences: number[] | null
}
export interface Agence { id: number; code: string; libelle: string; siege?: boolean }

interface Ctx {
  user: Utilisateur | null
  perms: Set<string>
  agences: Agence[]
  agenceId: number | null          // agence de travail (fixe pour un utilisateur d'agence, au choix pour le siège)
  chargement: boolean
  can: (p: string) => boolean
  login: (login: string, mdp: string) => Promise<'ok' | 'totp'>   // 'totp' : second facteur à fournir (loginTotp)
  loginTotp: (code: string) => Promise<void>
  logout: () => void
  rafraichir: () => Promise<void>
  choisirAgence: (id: number) => void
}

const SessionCtx = createContext<Ctx | null>(null)

export function SessionProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<Utilisateur | null>(null)
  const [perms, setPerms] = useState<Set<string>>(new Set())
  const [agences, setAgences] = useState<Agence[]>([])
  const [agenceId, setAgenceId] = useState<number | null>(session.getAgence())
  const [chargement, setChargement] = useState<boolean>(!!session.getToken())

  const logout = useCallback(() => {
    session.setToken(null)
    session.setAgence(null)
    ecrireInstantane(null)
    setUser(null)
    setPerms(new Set())
    setAgences([])
    setAgenceId(null)
  }, [])

  const charger = useCallback(async () => {
    const moi = await api.get<Utilisateur>('/api/auth/me')
    if (moi.doit_changer_mdp || moi.totp_a_enroler) {   // mot de passe temporaire ou second facteur à enrôler : rien d'autre n'est possible
      setUser(moi)
      return
    }
    const [p, ag] = await Promise.all([
      api.get<{ permissions: string[] }>('/api/moi/permissions'),
      api.get<Agence[]>('/api/agences'),
    ])
    setUser(moi)
    setPerms(new Set(p.permissions))
    setAgences(ag)
    ecrireInstantane({ user: moi, perms: p.permissions, agences: ag })
    if (moi.agence_id !== null) {
      session.setAgence(null)               // l'API impose déjà l'agence de l'utilisateur
      setAgenceId(moi.agence_id)
    } else {
      // siège : toutes les agences ; réseau : celles du réseau (la liste renvoyée par l'API est déjà filtrée)
      const memorisee = session.getAgence()
      const choix = (memorisee && ag.some((a) => a.id === memorisee) ? memorisee : null) ?? ag.find((a) => a.siege)?.id ?? ag[0]?.id ?? null
      session.setAgence(choix)
      setAgenceId(choix)
    }
  }, [])

  // inactivité : déconnexion après la durée de session du personnel (15 minutes sans action)
  useEffect(() => {
    if (!user) return
    const MAX = 15 * 60 * 1000
    let dernier = Date.now()
    const marque = () => { dernier = Date.now() }
    const evts = ['click', 'keydown', 'mousemove', 'touchstart'] as const
    evts.forEach((e) => window.addEventListener(e, marque, { passive: true }))
    const t = window.setInterval(() => { if (Date.now() - dernier > MAX) logout() }, 15000)
    return () => { evts.forEach((e) => window.removeEventListener(e, marque)); window.clearInterval(t) }
  }, [user, logout])

  useEffect(() => {
    session.onUnauthorized(logout)
    if (session.getToken()) {
      charger().catch((e) => {
        const snap = lireInstantane()
        if (e instanceof ApiError && (e.status === 0 || e.status >= 500) && snap) {      // réseau ou serveur indisponible : on garde la session ouverte avec le profil connu
          setUser(snap.user)
          setPerms(new Set(snap.perms))
          setAgences(snap.agences)
          setAgenceId(snap.user.agence_id)
        } else logout()
      }).finally(() => setChargement(false))
    }
  }, [charger, logout])

  const defi = useRef<string | null>(null)       // défi du second facteur : en mémoire seulement, jamais stocké
  const login = useCallback(
    async (l: string, mdp: string): Promise<'ok' | 'totp'> => {
      const r = await api.post<{ access_token?: string; totp_requis?: boolean; defi?: string }>('/api/auth/login', { login: l, mot_de_passe: mdp })
      if (r.totp_requis && r.defi) { defi.current = r.defi; return 'totp' }
      session.setToken(r.access_token ?? null)
      await charger()
      return 'ok'
    },
    [charger],
  )
  const loginTotp = useCallback(
    async (code: string) => {
      if (!defi.current) throw new ApiError(401, 'Défi expiré : recommencez la connexion')
      try {
        const r = await api.post<{ access_token: string }>('/api/auth/login/totp', { defi: defi.current, code })
        defi.current = null
        session.setToken(r.access_token)
        await charger()
      } catch (e) {
        if (e instanceof ApiError && e.status === 429) defi.current = null      // compte verrouillé : on repart du mot de passe
        throw e
      }
    },
    [charger],
  )
  const rafraichir = useCallback(async () => { await charger() }, [charger])

  const choisirAgence = useCallback((id: number) => {
    session.setAgence(id)
    setAgenceId(id)
  }, [])

  const value = useMemo<Ctx>(
    () => ({ user, perms, agences, agenceId, chargement, can: (p) => perms.has(p), login, loginTotp, logout, rafraichir, choisirAgence }),
    [user, perms, agences, agenceId, chargement, login, loginTotp, logout, rafraichir, choisirAgence],
  )
  return <SessionCtx.Provider value={value}>{children}</SessionCtx.Provider>
}

export function useSession(): Ctx {
  const c = useContext(SessionCtx)
  if (!c) throw new Error('useSession hors SessionProvider')
  return c
}
