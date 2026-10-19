import { useEffect, useState } from 'react'
import { api } from './api'

/** Recherche différée (250 ms) : se relance quand les paramètres changent ; `params` nul = pas de recherche. */
export function useRecherche<T>(chemin: string, params: Record<string, string | number> | null) {
  const [data, setData] = useState<T | null>(null)
  const [erreur, setErreur] = useState<string | null>(null)
  const [version, setVersion] = useState(0)
  const cle = params ? JSON.stringify(params) : ''
  useEffect(() => {
    setData(null); setErreur(null)
    if (!params) return
    let ok = true
    const t = setTimeout(() => {
      api.get<T>(chemin, params).then((d) => ok && setData(d)).catch((e: Error) => ok && setErreur(e.message))
    }, 250)
    return () => { ok = false; clearTimeout(t) }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chemin, cle, version])
  return { data, erreur, recharger: () => setVersion((n) => n + 1) }
}
