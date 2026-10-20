import { useState } from 'react'
import { api } from '../lib/api'
import { aujourdhui, date as fdate, xof } from '../lib/format'
import { Button, Charge, Field, Input, Modal, useFetch } from './ui'

interface Mouvement { id: number; date_operation: string; type: string; montant: number; libelle: string | null; sens: number; solde: number }
interface Releve {
  du: string; au: string; edite_par: string; edite_le: string
  client: { numero: string; nom: string; telephone: string | null }
  comptes: { id: number; numero: string; produit: string; solde_ouverture: number; solde_fin: number; total_entrees: number; total_sorties: number; mouvements: Mouvement[] }[]
  cycles: { id: number; numero: string; produit: string; statut: string; mise_courante: number; total_collecte: number; total_periode: number
    lignes: { date_collecte: string; montant_collecte: number }[]; retraits: { date_operation: string; montant: number; nature: string }[] }[]
  credits: { numero: string; montant_accorde: number; date_deblocage: string; statut: string; capital_restant: number; prochaine_echeance: string | null }[]
  institution: { raison_sociale: string; sigle: string | null; agrement: string | null; adresse: string | null; ville: string | null; telephone: string | null; logo: string | null; pied_de_page: string | null }
  agence: { code: string; libelle: string; adresse: string | null; ville: string | null; telephone: string | null } | null
}

const TYPES: Record<string, string> = {
  depot: 'Dépôt', retrait: 'Retrait', virement_entrant: 'Virement reçu', virement_sortant: 'Virement émis', interet: 'Intérêts',
  deblocage_credit: 'Déblocage de crédit', frais_dossier: 'Frais de dossier', prelevement_echeance: 'Échéance prélevée', saisie_garantie: 'Saisie de garantie',
}

function debutParDefaut() {
  const d = new Date(); d.setDate(d.getDate() - 90)
  return d.toISOString().slice(0, 10)
}

/** Relevé de compte d'un client (épargne, tontine, crédits) sur une période, prêt à imprimer. */
export function ReleveModal({ clientId, onClose }: { clientId: number; onClose: () => void }) {
  const [du, setDu] = useState(debutParDefaut())
  const [au, setAu] = useState(aujourdhui())
  const q = useFetch(() => api.get<Releve>(`/api/clients/${clientId}/releve`, { du, au }), [clientId, du, au])
  return (
    <Modal titre="Relevé de compte" onClose={onClose} large footer={<><Button onClick={onClose}>Fermer</Button><Button variant="primary" onClick={() => window.print()}>Imprimer</Button></>}>
      <div className="row" style={{ marginBottom: 8 }}>
        <Field label="Du"><Input type="date" value={du} max={au} onChange={(e) => setDu(e.target.value)} /></Field>
        <Field label="Au"><Input type="date" value={au} min={du} max={aujourdhui()} onChange={(e) => setAu(e.target.value)} /></Field>
      </div>
      <Charge q={q}>{(r) => <Document r={r} />}</Charge>
    </Modal>
  )
}

function Document({ r }: { r: Releve }) {
  const i = r.institution
  return (
    <div className="piece-doc" style={{ padding: 16, border: '1px solid var(--line, #d1d5db)', borderRadius: 8, background: '#fff', color: '#111' }}>
      <div style={{ display: 'flex', gap: 12, alignItems: 'center', borderBottom: '2px solid #111', paddingBottom: 8 }}>
        {i.logo && <img src={i.logo} alt="Logo" style={{ maxHeight: 56, maxWidth: 110, objectFit: 'contain' }} />}
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 18, fontWeight: 700 }}>{i.raison_sociale}{i.sigle ? ` (${i.sigle})` : ''}</div>
          <div style={{ fontSize: 12 }}>{[i.adresse, i.ville].filter(Boolean).join(', ')}{i.telephone ? ` — Tél. ${i.telephone}` : ''}</div>
          {r.agence && <div style={{ fontSize: 12 }}>Agence {r.agence.libelle} ({r.agence.code})</div>}
        </div>
      </div>
      <h2 style={{ textAlign: 'center', margin: '10px 0 2px' }}>RELEVÉ DE COMPTE</h2>
      <div style={{ textAlign: 'center' }}>du {fdate(r.du)} au {fdate(r.au)}</div>
      <p><strong>{r.client.nom}</strong> — client n° {r.client.numero}{r.client.telephone ? ` — ${r.client.telephone}` : ''}</p>

      {r.comptes.map((c) => (
        <div key={c.id} style={{ marginBottom: 12, breakInside: 'avoid' }}>
          <h3 style={{ margin: '8px 0 4px' }}>Compte d'épargne {c.numero} — {c.produit}</h3>
          <table className="t" style={{ width: '100%' }}>
            <thead><tr><th>Date</th><th>Opération</th><th className="num">Entrée</th><th className="num">Sortie</th><th className="num">Solde</th></tr></thead>
            <tbody>
              <tr><td colSpan={4}><em>Solde au {fdate(r.du)}</em></td><td className="num">{xof(c.solde_ouverture)}</td></tr>
              {c.mouvements.map((m) => (
                <tr key={m.id}><td>{fdate(m.date_operation)}</td><td>{TYPES[m.type] ?? m.type}{m.libelle ? ` — ${m.libelle}` : ''}</td>
                  <td className="num">{m.sens > 0 ? xof(m.montant) : ''}</td><td className="num">{m.sens < 0 ? xof(m.montant) : ''}</td><td className="num">{xof(m.solde)}</td></tr>
              ))}
              <tr><td colSpan={2}><strong>Totaux et solde au {fdate(r.au)}</strong></td><td className="num"><strong>{xof(c.total_entrees)}</strong></td><td className="num"><strong>{xof(c.total_sorties)}</strong></td><td className="num"><strong>{xof(c.solde_fin)}</strong></td></tr>
            </tbody>
          </table>
        </div>
      ))}

      {r.cycles.map((cy) => (
        <div key={cy.id} style={{ marginBottom: 12, breakInside: 'avoid' }}>
          <h3 style={{ margin: '8px 0 4px' }}>Tontine {cy.numero} — {cy.produit} (mise {xof(cy.mise_courante)}, {cy.statut === 'en_cours' ? 'en cours' : cy.statut})</h3>
          <table className="t" style={{ width: '100%' }}>
            <thead><tr><th>Date</th><th>Opération</th><th className="num">Montant</th></tr></thead>
            <tbody>
              {cy.lignes.map((l, n) => <tr key={n}><td>{fdate(l.date_collecte)}</td><td>Collecte</td><td className="num">{xof(l.montant_collecte)}</td></tr>)}
              {cy.retraits.map((t, n) => <tr key={`r${n}`}><td>{fdate(t.date_operation)}</td><td>Retrait ({t.nature.replace(/_/g, ' ')})</td><td className="num">{xof(t.montant)}</td></tr>)}
              <tr><td colSpan={2}><strong>Collecté sur la période / depuis l'ouverture</strong></td><td className="num"><strong>{xof(cy.total_periode)} / {xof(cy.total_collecte)}</strong></td></tr>
            </tbody>
          </table>
        </div>
      ))}

      {r.credits.length > 0 && (
        <div style={{ marginBottom: 12, breakInside: 'avoid' }}>
          <h3 style={{ margin: '8px 0 4px' }}>Crédits</h3>
          <table className="t" style={{ width: '100%' }}>
            <thead><tr><th>N°</th><th>Débloqué le</th><th className="num">Montant</th><th className="num">Capital restant</th><th>Prochaine échéance</th><th>Statut</th></tr></thead>
            <tbody>{r.credits.map((c) => <tr key={c.numero}><td>{c.numero}</td><td>{fdate(c.date_deblocage)}</td><td className="num">{xof(c.montant_accorde)}</td><td className="num">{xof(c.capital_restant)}</td><td>{c.prochaine_echeance ? fdate(c.prochaine_echeance) : '—'}</td><td>{c.statut.replace('_', ' ')}</td></tr>)}</tbody>
          </table>
        </div>
      )}
      {r.comptes.length === 0 && r.cycles.length === 0 && r.credits.length === 0 && <p className="muted">Aucune opération sur la période.</p>}
      <div style={{ fontSize: 11, marginTop: 12 }}>Édité le {r.edite_le.replace('T', ' à ')} par {r.edite_par}.</div>
      {i.pied_de_page && <div style={{ marginTop: 8, borderTop: '1px solid #999', paddingTop: 6, fontSize: 11, textAlign: 'center' }}>{i.pied_de_page}</div>}
    </div>
  )
}
