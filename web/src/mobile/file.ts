// File d'attente locale (IndexedDB) et synchronisation des saisies de collecte de l'application mobile.
// Toute saisie passe par la file, réseau ou non : une seule voie, donc un seul comportement à vérifier.
// Chaque opération a une clé unique (UUID) conservée jusqu'à l'accusé du serveur : l'envoyer deux fois ne crée qu'une ligne.
import { useSyncExternalStore } from 'react'
import { api, ApiError } from '../lib/api'

export interface Operation {
  cle: string
  cycle_id: number
  date_collecte: string
  montant_collecte: number
  cree_le: number
  etat: 'attente' | 'refusee'
  code?: string
  motif?: string
  // affichage hors ligne
  client: string
  cycle: string
  produit: string
}

export interface CycleCollecte {
  id: number
  numero: string
  client: string
  produit: string
  produit_libelle: string
  type_cycle: number
  mise_courante: number
  reste_a_collecter: number | null
  date_debut: string
  date_fin: string
  date_limite: string
}

// ------------------------------------------------------------------ IndexedDB
let ouverture: Promise<IDBDatabase> | null = null

function ouvrir(): Promise<IDBDatabase> {
  ouverture ??= new Promise((resolve, reject) => {
    const r = indexedDB.open('sfd_collecte', 1)
    r.onupgradeneeded = () => {
      r.result.createObjectStore('ops', { keyPath: 'cle' })
      r.result.createObjectStore('cache', { keyPath: 'k' })
    }
    r.onsuccess = () => resolve(r.result)
    r.onerror = () => reject(r.error)
  })
  return ouverture
}

async function idb<T>(store: 'ops' | 'cache', mode: IDBTransactionMode, fn: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  const db = await ouvrir()
  return new Promise((resolve, reject) => {
    const t = db.transaction(store, mode)
    const req = fn(t.objectStore(store))
    t.oncomplete = () => resolve(req.result)
    t.onerror = t.onabort = () => reject(t.error)
  })
}

export const lireCache = async <T>(k: string): Promise<T | null> => ((await idb<{ v: T } | undefined>('cache', 'readonly', (s) => s.get(k)))?.v ?? null)
export const ecrireCache = (k: string, v: unknown) => idb('cache', 'readwrite', (s) => s.put({ k, v }))
export const viderCache = () => idb('cache', 'readwrite', (s) => s.clear())

// ------------------------------------------------------------------ état partagé
export interface Etat {
  ops: Operation[]
  chargee: boolean
  enCours: boolean
  reseau: boolean              // false après un échec réseau, jusqu'au prochain succès
  sessionExpiree: boolean
  derniereSynchro: number | null
}

let etat: Etat = { ops: [], chargee: false, enCours: false, reseau: typeof navigator === 'undefined' ? true : navigator.onLine, sessionExpiree: false, derniereSynchro: null }
const abonnes = new Set<() => void>()
const maj = (p: Partial<Etat>) => {
  etat = { ...etat, ...p }
  abonnes.forEach((f) => f())
}

export function useFile(): Etat {
  return useSyncExternalStore((f) => { abonnes.add(f); return () => { abonnes.delete(f) } }, () => etat)
}

async function relire() {
  const ops = await idb<Operation[]>('ops', 'readonly', (s) => s.getAll())
  maj({ ops: ops.sort((a, b) => a.cree_le - b.cree_le), chargee: true })
}

export function nouvelleCle(): string {
  if (typeof crypto.randomUUID === 'function') return crypto.randomUUID()
  const b = crypto.getRandomValues(new Uint8Array(16))
  return Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('')
}

export async function enregistrer(o: Omit<Operation, 'cle' | 'cree_le' | 'etat'>): Promise<Operation> {
  const op: Operation = { ...o, cle: nouvelleCle(), cree_le: Date.now(), etat: 'attente' }
  await idb('ops', 'readwrite', (s) => s.put(op))      // écrit sur le téléphone AVANT toute tentative d'envoi
  await relire()
  void synchroniser()
  return op
}

export async function retirer(cle: string) {
  await idb('ops', 'readwrite', (s) => s.delete(cle))
  await relire()
}

export async function reessayer(cle: string) {
  const o = etat.ops.find((x) => x.cle === cle)
  if (!o) return
  await idb('ops', 'readwrite', (s) => s.put({ ...o, etat: 'attente', code: undefined, motif: undefined }))
  await relire()
  void synchroniser()
}

// ------------------------------------------------------------------ synchronisation
interface ResultatSync { cle: string; statut: 'appliquee' | 'doublon' | 'refusee'; code?: string | null; motif?: string | null }
const LOT = 50

export async function synchroniser(): Promise<void> {
  if (etat.enCours) return
  if (!etat.chargee) await relire()
  const attente = etat.ops.filter((o) => o.etat === 'attente')
  if (attente.length === 0) return
  maj({ enCours: true })
  try {
    for (let i = 0; i < attente.length; i += LOT) {
      const lot = attente.slice(i, i + LOT)
      let resultats: ResultatSync[]
      try {
        const r = await api.post<{ resultats: ResultatSync[] }>('/api/collecte/sync', {
          operations: lot.map(({ cle, cycle_id, date_collecte, montant_collecte }) => ({ cle, cycle_id, date_collecte, montant_collecte })),
        })
        resultats = r.resultats
      } catch (e) {
        if (!(e instanceof ApiError)) throw e
        if (e.status === 401) { maj({ sessionExpiree: true }); return }
        if (e.status === 0 || e.status >= 500 || e.status === 408 || e.status === 429) { maj({ reseau: false }); return }
        // refus du lot entier (droit, format) : chaque opération est marquée à corriger, rien n'est perdu
        resultats = lot.map((o) => ({ cle: o.cle, statut: 'refusee' as const, code: 'lot_refuse', motif: e.message }))
      }
      for (const r of resultats) {
        const o = lot.find((x) => x.cle === r.cle)
        if (!o) continue
        if (r.statut === 'refusee') await idb('ops', 'readwrite', (s) => s.put({ ...o, etat: 'refusee', code: r.code ?? 'autre', motif: r.motif ?? 'Refusée' }))
        else await idb('ops', 'readwrite', (s) => s.delete(o.cle))
      }
      maj({ reseau: true, sessionExpiree: false, derniereSynchro: Date.now() })
      await relire()
    }
  } catch {
    maj({ reseau: false })
  } finally {
    maj({ enCours: false })
  }
}

// reprise automatique : retour du réseau, retour au premier plan, et toutes les 20 s tant qu'il reste des opérations
let demarre = false
export function demarrerSynchro() {
  if (demarre) return
  demarre = true
  void relire().then(() => synchroniser())
  window.addEventListener('online', () => { maj({ reseau: true }); void synchroniser() })
  window.addEventListener('offline', () => maj({ reseau: false }))
  document.addEventListener('visibilitychange', () => { if (!document.hidden) void synchroniser() })
  window.setInterval(() => { if (etat.ops.some((o) => o.etat === 'attente') && !etat.sessionExpiree) void synchroniser() }, 20000)
}

export const marquerReseau = (ok: boolean) => maj({ reseau: ok })

export function sessionRetablie() {
  maj({ sessionExpiree: false })
  void synchroniser()
}
