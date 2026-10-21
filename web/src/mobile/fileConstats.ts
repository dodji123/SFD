// Contrôle des livrets sur le terrain : file locale (IndexedDB) des constats et envoi idempotent (clé d'opération).
// Le constat est écrit sur le téléphone avant tout envoi ; le serveur le rapproche de l'état du système au moment de la réception,
// puis un responsable le valide ou le rejette (jamais depuis le téléphone).
import { useSyncExternalStore } from 'react'
import { api, ApiError } from '../lib/api'

export type EtatLivret = 'conforme' | 'incomplet' | 'abime' | 'perdu' | 'non_presente'
export type NatureEcart = 'absente_systeme' | 'absente_livret' | 'montant_different'

export interface Ecart { no_ligne: number; date_collecte?: string | null; montant_livret?: number | null; montant_systeme?: number | null; nature: NatureEcart; note?: string | null }
export interface CorpsConstat {
  cycle_id: number
  etat_livret: EtatLivret
  nb_lignes_constatees?: number | null
  total_constate?: number | null
  commentaire?: string | null
  date_controle: string
  ecarts: Ecart[]
}
// attente : sur le téléphone · envoye : reçu par le serveur (statut = a_valider / valide / rejete) · refuse : refusé par les règles, à corriger
export interface Constat {
  cle: string
  cree_le: number
  cycle: string
  client: string
  produit: string
  corps: CorpsConstat
  etat: 'attente' | 'envoye' | 'refuse'
  controle_id?: number
  statut?: 'a_valider' | 'valide' | 'rejete'
  ecart_montant?: number | null
  decision?: string | null
  motif?: string
}

let ouverture: Promise<IDBDatabase> | null = null
function ouvrir(): Promise<IDBDatabase> {
  ouverture ??= new Promise((resolve, reject) => {
    const r = indexedDB.open('sfd_controles', 1)
    r.onupgradeneeded = () => { r.result.createObjectStore('constats', { keyPath: 'cle' }); r.result.createObjectStore('cache', { keyPath: 'k' }) }
    r.onsuccess = () => resolve(r.result)
    r.onerror = () => reject(r.error)
  })
  return ouverture
}
async function idb<T>(store: 'constats' | 'cache', mode: IDBTransactionMode, fn: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  const db = await ouvrir()
  return new Promise((resolve, reject) => {
    const t = db.transaction(store, mode)
    const req = fn(t.objectStore(store))
    t.oncomplete = () => resolve(req.result)
    t.onerror = t.onabort = () => reject(t.error)
  })
}
export const lireCacheC = async <T>(k: string): Promise<T | null> => ((await idb<{ v: T } | undefined>('cache', 'readonly', (s) => s.get(k)))?.v ?? null)
export const ecrireCacheC = (k: string, v: unknown) => idb('cache', 'readwrite', (s) => s.put({ k, v }))
export const viderCacheC = () => idb('cache', 'readwrite', (s) => s.clear())

export interface EtatC { constats: Constat[]; chargee: boolean; enCours: boolean; reseau: boolean; sessionExpiree: boolean; derniereSynchro: number | null }
let etat: EtatC = { constats: [], chargee: false, enCours: false, reseau: typeof navigator === 'undefined' ? true : navigator.onLine, sessionExpiree: false, derniereSynchro: null }
const abonnes = new Set<() => void>()
const maj = (p: Partial<EtatC>) => { etat = { ...etat, ...p }; abonnes.forEach((f) => f()) }
export const useConstats = (): EtatC => useSyncExternalStore((f) => { abonnes.add(f); return () => { abonnes.delete(f) } }, () => etat)

async function relire() {
  const l = await idb<Constat[]>('constats', 'readonly', (s) => s.getAll())
  maj({ constats: l.sort((a, b) => b.cree_le - a.cree_le), chargee: true })
}
const ecrire = (c: Constat) => idb('constats', 'readwrite', (s) => s.put(c))
const cleNouvelle = () => (typeof crypto.randomUUID === 'function' ? crypto.randomUUID() : Array.from(crypto.getRandomValues(new Uint8Array(16)), (x) => x.toString(16).padStart(2, '0')).join(''))

export async function enregistrerConstat(info: { cycle: string; client: string; produit: string }, corps: CorpsConstat) {
  await ecrire({ cle: cleNouvelle(), cree_le: Date.now(), ...info, corps, etat: 'attente' })
  await relire()
  void synchroniserConstats()
}
export async function retirerConstat(cle: string) { await idb('constats', 'readwrite', (s) => s.delete(cle)); await relire() }
export async function reessayerConstat(cle: string) {
  const c = etat.constats.find((x) => x.cle === cle)
  if (c) { await ecrire({ ...c, etat: 'attente', motif: undefined }); await relire(); void synchroniserConstats() }
}

interface Retour { id: number; statut: 'a_valider' | 'valide' | 'rejete'; ecart_montant: number | null; commentaire_decision: string | null }

export async function synchroniserConstats(): Promise<void> {
  if (etat.enCours) return
  if (!etat.chargee) await relire()
  const attente = etat.constats.filter((c) => c.etat === 'attente').sort((a, b) => a.cree_le - b.cree_le)
  const suivis = etat.constats.filter((c) => c.etat === 'envoye' && c.statut === 'a_valider' && c.controle_id)
  if (attente.length === 0 && suivis.length === 0) return
  maj({ enCours: true })
  try {
    for (const c of attente) {
      try {
        const r = await api.post<Retour>('/api/controles-livrets', { ...c.corps, cle: c.cle })     // rejouer la clé ne crée rien
        await ecrire({ ...c, etat: 'envoye', controle_id: r.id, statut: r.statut, ecart_montant: r.ecart_montant, decision: r.commentaire_decision })
      } catch (e) {
        if (!(e instanceof ApiError)) throw e
        if (e.status === 401) { maj({ sessionExpiree: true }); return }
        if (e.status === 0 || e.status >= 500 || e.status === 408 || e.status === 429) { maj({ reseau: false }); return }
        await ecrire({ ...c, etat: 'refuse', motif: e.message })          // règle métier : à corriger ou abandonner
      }
    }
    for (const c of suivis) {                                             // décision du responsable
      try {
        const r = await api.get<Retour>(`/api/controles-livrets/${c.controle_id}`)
        if (r.statut !== c.statut) await ecrire({ ...c, statut: r.statut, decision: r.commentaire_decision })
      } catch (e) {
        if (e instanceof ApiError && (e.status === 0 || e.status >= 500)) { maj({ reseau: false }); break }
      }
    }
    maj({ reseau: true, sessionExpiree: false, derniereSynchro: Date.now() })
    await relire()
  } catch {
    maj({ reseau: false })
  } finally {
    maj({ enCours: false })
  }
}

let demarre = false
export function demarrerSynchroConstats() {
  if (demarre) return
  demarre = true
  void relire().then(() => synchroniserConstats())
  window.addEventListener('online', () => { maj({ reseau: true }); void synchroniserConstats() })
  window.addEventListener('offline', () => maj({ reseau: false }))
  document.addEventListener('visibilitychange', () => { if (!document.hidden) void synchroniserConstats() })
  window.setInterval(() => { if (!etat.sessionExpiree && etat.constats.some((c) => c.etat === 'attente' || (c.etat === 'envoye' && c.statut === 'a_valider'))) void synchroniserConstats() }, 30000)
}
export const marquerReseauC = (ok: boolean) => maj({ reseau: ok })
export const sessionRetablieC = () => { maj({ sessionExpiree: false }); void synchroniserConstats() }
