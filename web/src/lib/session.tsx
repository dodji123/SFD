import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { api, session } from './api'

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
  login: (login: string, mdp: string) => Promise<void>
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
    setUser(null)
    setPerms(new Set())
    setAgences([])
    setAgenceId(null)
  }, [])

  const charger = useCallback(async () => {
    const moi = await api.get<Utilisateur>('/api/auth/me')
    if (moi.doit_changer_mdp) {              // mot de passe temporaire : seul le changement est possible
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
      charger().catch(logout).finally(() => setChargement(false))
    }
  }, [charger, logout])

  const login = useCallback(
    async (l: string, mdp: string) => {
      const r = await api.post<{ access_token: string }>('/api/auth/login', { login: l, mot_de_passe: mdp })
      session.setToken(r.access_token)
      await charger()
    },
    [charger],
  )
  const rafraichir = useCallback(async () => { await charger() }, [charger])

  const choisirAgence = useCallback((id: number) => {
    session.setAgence(id)
    setAgenceId(id)
  }, [])

  const value = useMemo<Ctx>(
    () => ({ user, perms, agences, agenceId, chargement, can: (p) => perms.has(p), login, logout, rafraichir, choisirAgence }),
    [user, perms, agences, agenceId, chargement, login, logout, rafraichir, choisirAgence],
  )
  return <SessionCtx.Provider value={value}>{children}</SessionCtx.Provider>
}

export function useSession(): Ctx {
  const c = useContext(SessionCtx)
  if (!c) throw new Error('useSession hors SessionProvider')
  return c
}
