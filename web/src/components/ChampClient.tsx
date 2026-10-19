import { useEffect, useState, type Ref } from 'react'
import { api } from '../lib/api'
import { Field, Input } from './ui'

interface Suggestion { id: number; numero: string; nom: string; telephone: string | null }

/** Vrai si la saisie désigne un client sans ambiguïté : numéro d'ordre (« 5 ») ou numéro complet (« CL-LOM-2026-000005 »). */
export const estNumero = (v: string) => /^\d+$/.test(v.trim()) || /^CL-/i.test(v.trim())

/**
 * Champ client des formulaires de saisie : on tape le numéro d'ordre (« 5 ») ou une partie du nom ; le nom propose les clients
 * correspondants (choisir en remplit le numéro complet). La valeur reste une chaîne exploitable par les routes `recherche`.
 */
export function ChampClient({ valeur, onChange, inputRef, label = 'N° client ou nom' }: {
  valeur: string; onChange: (v: string) => void; inputRef?: Ref<HTMLInputElement>; label?: string
}) {
  const [propositions, setPropositions] = useState<Suggestion[]>([])
  const chercheParNom = valeur.trim().length >= 2 && !estNumero(valeur)

  useEffect(() => {
    if (!chercheParNom) { setPropositions([]); return }
    let ok = true
    const t = setTimeout(() => {
      api.get<Suggestion[]>('/api/clients', { q: valeur.trim(), limit: 8 }).then((d) => ok && setPropositions(d)).catch(() => ok && setPropositions([]))
    }, 250)
    return () => { ok = false; clearTimeout(t) }
  }, [valeur, chercheParNom])

  return (
    <div style={{ position: 'relative' }}>
      <Field label={label} hint="Numéro d'ordre (ex. 5) ou nom du client">
        <Input ref={inputRef} value={valeur} placeholder="5 ou Mensah" autoComplete="off" onChange={(e) => onChange(e.target.value)} />
      </Field>
      {chercheParNom && (
        <ul role="listbox" aria-label="Clients trouvés" style={{ position: 'absolute', zIndex: 20, left: 0, right: 0, margin: 0, padding: 0, listStyle: 'none', background: 'var(--card, #fff)', border: '1px solid var(--line, #d1d5db)', borderRadius: 6, maxHeight: 220, overflowY: 'auto' }}>
          {propositions.length === 0
            ? <li className="muted" style={{ padding: '6px 10px' }}>Aucun client trouvé</li>
            : propositions.map((c) => (
              <li key={c.id} role="option" aria-selected={false} tabIndex={0} style={{ padding: '6px 10px', cursor: 'pointer' }}
                onClick={() => onChange(c.numero)} onKeyDown={(e) => { if (e.key === 'Enter') onChange(c.numero) }}>
                <strong>{c.nom}</strong> <span className="muted">{c.numero}</span>
              </li>
            ))}
        </ul>
      )}
    </div>
  )
}

/** Zone de filtre des tableaux : nom, numéro de client ou de compte. */
export function FiltreTableau({ valeur, onChange }: { valeur: string; onChange: (v: string) => void }) {
  return (
    <div style={{ padding: '8px 16px' }}>
      <Input type="search" value={valeur} placeholder="Filtrer par nom ou numéro" aria-label="Filtrer le tableau par nom ou numéro" onChange={(e) => onChange(e.target.value)} />
    </div>
  )
}

const sansAccent = (s: string) => s.normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()

/** Garde les lignes dont l'un des textes contient le filtre (sans tenir compte des accents ni de la casse). */
export function filtrer<T>(rows: T[], filtre: string, textes: (r: T) => (string | null | undefined)[]): T[] {
  const f = sansAccent(filtre.trim())
  return f === '' ? rows : rows.filter((r) => textes(r).some((t) => t && sansAccent(t).includes(f)))
}
