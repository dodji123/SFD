import { useEffect, useState } from 'react'
import { api } from './api'
import { useSession } from './session'

export interface Zone { id: number; code: string; libelle: string; collectrice: string | null; agent_id: number | null }
export interface Agent { id: number; matricule: string; nom: string; actif: boolean }
export interface Produit { id: number; code: string; libelle: string; categorie: string; type_cycle: number | null; solde_minimum: number }

function useListe<T>(chemin: string, params?: Record<string, string | number>): T[] {
  const { agenceId } = useSession()
  const [liste, setListe] = useState<T[]>([])
  useEffect(() => {
    let ok = true
    api.get<T[]>(chemin, params).then((d) => ok && setListe(d)).catch(() => ok && setListe([]))
    return () => { ok = false }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chemin, agenceId, JSON.stringify(params)])
  return liste
}

export const useZones = () => useListe<Zone>('/api/zones')
export const useAgents = () => useListe<Agent>('/api/agents')
export const useProduitsEpargne = (categorie?: string) => useListe<Produit>('/api/produits-epargne', categorie ? { categorie } : undefined)
