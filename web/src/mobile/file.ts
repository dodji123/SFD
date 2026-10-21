// File d'attente locale (IndexedDB) et synchronisation de l'application mobile du collecteur.
// Toute saisie passe par la file, réseau ou non : une seule voie, donc un seul comportement à vérifier.
// Chaque opération a une clé unique (UUID) conservée jusqu'à la décision de l'opérateur : l'envoyer deux fois ne la crée qu'une fois.
// Le serveur ne l'écrit pas dans les données vives : il la met en attente de VALIDATION (chef/caissier), qui la valide ou la rejette.
// Un client ou un cycle créé hors ligne est désigné par la clé de son opération (identifiant local) ; le serveur la remplace à la validation.
import { useSyncExternalStore } from 'react'
import { api, ApiError } from '../lib/api'

export type TypeOp = 'client' | 'cycle' | 'collecte' | 'cloture'
// attente : sur le téléphone, pas encore reçue · envoyee : reçue, en attente de validation · validee / rejetee : décision de l'opérateur
// refusee : refusée dès la réception (zone, droit, format) — à corriger ou abandonner
export type EtatOp = 'attente' | 'envoyee' | 'validee' | 'rejetee' | 'refusee'
export type Ref = number | string

export interface Operation {
  cle: string
  type: TypeOp
  payload: Record<string, unknown>
  cree_le: number
  etat: EtatOp
  code?: string
  motif?: string
  libelle: string              // texte lisible, gardé pour l'affichage hors ligne
}

export interface Zone { id: number; code: string; libelle: string }
export interface ClientVue { id: Ref; numero?: string; nom: string; telephone: string | null; zone_id: number | null; local?: boolean }
export interface Produit { id: number; code: string; libelle: string; type_cycle: number | null; nb_pages_livret: number }
export interface CycleVue {
  id: Ref
  client_id: Ref
  numero: string
  client: string
  produit: string
  type_cycle: number
  mise_courante: number
  reste_a_collecter: number | null
  date_debut: string
  date_fin: string
  date_limite: string
  local?: boolean
}
export interface Tournee {
  agent_id: number
  zones: Zone[]
  clients: ClientVue[]
  cycles: CycleVue[]
  produits: Produit[]
  operations: { cle: string; type: TypeOp; statut: 'en_attente' | 'validee' | 'rejetee'; code: string | null; motif: string | null }[]
}

const RANG: Record<TypeOp, number> = { client: 1, cycle: 2, collecte: 3, cloture: 4 }

// ------------------------------------------------------------------ IndexedDB
let ouverture: Promise<IDBDatabase> | null = null

function ouvrir(): Promise<IDBDatabase> {
  ouverture ??= new Promise((resolve, reject) => {
    const r = indexedDB.open('sfd_collecte', 2)
    r.onupgradeneeded = () => {
      const db = r.result
      if (db.objectStoreNames.contains('ops')) db.deleteObjectStore('ops')   // v1 : anciennes opérations sans type (jamais en production)
      db.createObjectStore('ops', { keyPath: 'cle' })
      if (!db.objectStoreNames.contains('cache')) db.createObjectStore('cache', { keyPath: 'k' })
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

const ecrire = (o: Operation) => idb('ops', 'readwrite', (s) => s.put(o))

export function nouvelleCle(): string {
  if (typeof crypto.randomUUID === 'function') return crypto.randomUUID()
  const b = crypto.getRandomValues(new Uint8Array(16))
  return Array.from(b, (x) => x.toString(16).padStart(2, '0')).join('')
}

/** Écrit l'opération sur le téléphone AVANT toute tentative d'envoi. Retourne sa clé (identifiant local d'un client / cycle créé). */
export async function enregistrer(type: TypeOp, payload: Record<string, unknown>, libelle: string): Promise<string> {
  const op: Operation = { cle: nouvelleCle(), type, payload, libelle, cree_le: Date.now(), etat: 'attente' }
  await ecrire(op)
  await relire()
  void synchroniser()
  return op.cle
}

export async function retirer(cle: string) {
  await idb('ops', 'readwrite', (s) => s.delete(cle))
  await relire()
}

export async function reessayer(cle: string) {
  const o = etat.ops.find((x) => x.cle === cle)
  if (!o) return
  await ecrire({ ...o, etat: 'attente', code: undefined, motif: undefined })
  await relire()
  void synchroniser()
}

/** Reporte les décisions de l'opérateur (statuts renvoyés par la tournée) sur les opérations locales, puis purge les anciennes validées. */
export async function appliquerStatuts(distant: Tournee['operations']) {
  const par = new Map(distant.map((d) => [d.cle, d]))
  const limite = Date.now() - 2 * 24 * 3600 * 1000
  let change = false
  for (const o of etat.ops) {
    const d = par.get(o.cle)
    if (d && o.etat === 'envoyee' && d.statut !== 'en_attente') {
      await ecrire({ ...o, etat: d.statut === 'validee' ? 'validee' : 'rejetee', code: d.code ?? undefined, motif: d.motif ?? undefined })
      change = true
    } else if (o.etat === 'validee' && o.cree_le < limite) {
      await idb('ops', 'readwrite', (s) => s.delete(o.cle))
      change = true
    }
  }
  if (change) await relire()
}

// ------------------------------------------------------------------ synchronisation
interface ResultatSync { cle: string; statut: 'recue' | 'doublon' | 'refusee'; etat?: string | null; code?: string | null; motif?: string | null }
const LOT = 50

export async function synchroniser(): Promise<void> {
  if (etat.enCours) return
  if (!etat.chargee) await relire()
  const attente = etat.ops.filter((o) => o.etat === 'attente').sort((a, b) => RANG[a.type] - RANG[b.type] || a.cree_le - b.cree_le)
  if (attente.length === 0) return
  maj({ enCours: true })
  try {
    for (let i = 0; i < attente.length; i += LOT) {
      const lot = attente.slice(i, i + LOT)
      let resultats: ResultatSync[]
      try {
        const r = await api.post<{ resultats: ResultatSync[] }>('/api/collecte/sync', {
          operations: lot.map(({ cle, type, payload }) => ({ cle, type, payload })),
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
        if (r.statut === 'refusee') await ecrire({ ...o, etat: 'refusee', code: r.code ?? 'autre', motif: r.motif ?? 'Refusée' })
        else if (r.etat === 'validee') await ecrire({ ...o, etat: 'validee' })
        else if (r.etat === 'rejetee') await ecrire({ ...o, etat: 'rejetee', code: r.code ?? undefined, motif: r.motif ?? undefined })
        else await ecrire({ ...o, etat: 'envoyee' })
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

// reprise automatique : retour du réseau, retour au premier plan, et toutes les 20 s tant qu'il reste des opérations à envoyer
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
