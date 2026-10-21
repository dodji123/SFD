import { useEffect, useState } from 'react'
import { api } from '../lib/api'
import { Field, Select } from './ui'

/** Type de cycle : libre à chaque cycle, sauf si le produit en impose un (GET /api/cycles/type-propose). */
export function useTypeCycle(clientId: number | null | undefined, produitId: string) {
  const [type, setType] = useState('')
  const [verrou, setVerrou] = useState<string | null>(null)
  useEffect(() => {
    setVerrou(null)
    if (!clientId || !produitId) { setType(''); return }
    let ok = true
    api.get<{ type_cycle: number | null; impose_par: string | null }>('/api/cycles/type-propose', { client_id: clientId, produit_id: Number(produitId) })
      .then((r) => { if (!ok) return; if (r.type_cycle) { setType(String(r.type_cycle)); setVerrou(r.impose_par) } else setType('') })
      .catch(() => ok && setType(''))
    return () => { ok = false }
  }, [clientId, produitId])
  return { type, setType, verrou, corps: verrou ? {} : { type_cycle: type ? Number(type) : undefined } }
}

function messageVerrou(par: string | null) {
  if (par === 'produit') return 'Verrouillé : type imposé par le produit.'
  return par ? 'Verrouillé.' : null
}

export function ChampTypeCycle({ t }: { t: ReturnType<typeof useTypeCycle> }) {
  return (
    <Field label="Type de cycle" hint={messageVerrou(t.verrou) ?? 'Choisi pour ce cycle : un même client peut prendre un autre type au cycle suivant, sur n’importe quel produit.'}>
      <Select value={t.type} disabled={t.verrou !== null} onChange={(e) => t.setType(e.target.value)} required={t.verrou === null}>
        <option value="">— choisir —</option>
        <option value="1">Type 1 — mise fixe</option>
        <option value="2">Type 2 — mise modifiable</option>
        <option value="3">Type 3 — mise finale calculée</option>
      </Select>
    </Field>
  )
}
