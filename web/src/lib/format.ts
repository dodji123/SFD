const nf = new Intl.NumberFormat('fr-FR', { maximumFractionDigits: 0 })

/** Montant en francs CFA : 1 234 567 F. Espace insécable fine remplacée par une espace normale pour l'alignement. */
export function xof(n: number | null | undefined): string {
  if (n === null || n === undefined || Number.isNaN(n)) return '—'
  return nf.format(n).replace(/[  ]/g, ' ') + ' F'
}

export function nombre(n: number | null | undefined): string {
  if (n === null || n === undefined || Number.isNaN(n)) return '—'
  return nf.format(n).replace(/[  ]/g, ' ')
}

/** Date ISO (2026-10-19) -> 19/10/2026, sans passer par le fuseau horaire. */
export function date(d: string | null | undefined): string {
  if (!d) return '—'
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(d)
  return m ? `${m[3]}/${m[2]}/${m[1]}` : d
}

export function dateHeure(d: string | null | undefined): string {
  if (!d) return '—'
  const x = new Date(d)
  return Number.isNaN(x.getTime()) ? d : x.toLocaleString('fr-FR', { dateStyle: 'short', timeStyle: 'short' })
}

export function aujourdhui(): string {
  const d = new Date()
  const p = (n: number) => String(n).padStart(2, '0')
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`
}

export function decaler(iso: string, jours: number): string {
  const [y, m, d] = iso.split('-').map(Number)
  const x = new Date(y, m - 1, d + jours)
  const p = (n: number) => String(n).padStart(2, '0')
  return `${x.getFullYear()}-${p(x.getMonth() + 1)}-${p(x.getDate())}`
}

export const libellesStatut: Record<string, string> = {
  en_cours: 'En cours', clos: 'Clos', retire: 'Retiré',
  demande: 'Demandé', ecart_en_traitement: 'Écart en traitement', fonds_disponibles: 'Fonds disponibles', execute: 'Exécuté', annule: 'Annulé',
  demandee: 'À décider', approuvee: 'Approuvée', refusee: 'Refusée', debloquee: 'Débloquée',
  en_retard: 'En retard', solde: 'Soldé',
  a_venir: 'À venir', echue: 'Échue', partielle: 'Partielle', payee: 'Payée',
  ouverte: 'Ouverte', fermee: 'Fermée', actif: 'Actif', brouillon: 'Brouillon', valide: 'Validé', paye: 'Payé',
  calculee: 'Calculée', a_traiter: 'À traiter', ouvert: 'Ouvert', cloture: 'Clôturé',
}

export const tonStatut: Record<string, 'ok' | 'warn' | 'bad' | 'info' | 'neutre'> = {
  en_cours: 'info', clos: 'neutre', retire: 'ok', demande: 'warn', ecart_en_traitement: 'bad', fonds_disponibles: 'info', execute: 'ok',
  demandee: 'warn', approuvee: 'info', refusee: 'bad', debloquee: 'ok', en_retard: 'bad', solde: 'ok', a_venir: 'neutre', echue: 'bad',
  partielle: 'warn', payee: 'ok', ouverte: 'info', fermee: 'neutre', brouillon: 'warn', valide: 'ok', ouvert: 'info', cloture: 'neutre',
  a_traiter: 'warn', calculee: 'info', paye: 'ok',
}

export const libellesRole: Record<string, string> = {
  admin: 'Administrateur', directeur: 'Directeur', chef_agence: "Chef d'agence", caissier: 'Caissier', comptable: 'Comptable',
  agent: 'Agent', collectrice: 'Collectrice', rh: 'Ressources humaines', auditeur: 'Auditeur',
}
