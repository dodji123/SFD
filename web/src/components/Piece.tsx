import { useState } from 'react'
import { api } from '../lib/api'
import { date as fdate, xof } from '../lib/format'
import { Button, Charge, Modal, useFetch } from './ui'

export interface PieceDetail {
  id: number; numero: string; titre: string; type: string; date_piece: string; libelle: string; montant: number
  client: string; client_numero: string; compte: string | null; agence: string; agence_code: string; utilisateur: string | null
  lignes: { ligne: number; libelle: string; montant: number }[]
  agence_adresse: string | null; agence_ville: string | null; agence_telephone: string | null; agence_email: string | null
  institution: {
    raison_sociale: string; sigle: string | null; agrement: string | null; immatriculation: string | null; adresse: string | null; ville: string | null
    telephone: string | null; email: string | null; site_web: string | null; logo: string | null; pied_de_page: string | null
  }
}

/** Pièce justificative prête à imprimer (reçu remis au client). L'impression ne garde que le document. */
function Document({ p }: { p: PieceDetail }) {
  const i = p.institution
  return (
    <div className="piece-doc" style={{ padding: 16, border: '1px solid var(--line, #d1d5db)', borderRadius: 8, background: '#fff', color: '#111' }}>
      <div style={{ display: 'flex', gap: 12, alignItems: 'center', borderBottom: '2px solid #111', paddingBottom: 8 }}>
        {i.logo && <img src={i.logo} alt="Logo" style={{ maxHeight: 64, maxWidth: 120, objectFit: 'contain' }} />}
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 18, fontWeight: 700 }}>{i.raison_sociale}{i.sigle ? ` (${i.sigle})` : ''}</div>
          {i.agrement && <div style={{ fontSize: 12 }}>{i.agrement}</div>}
          {i.immatriculation && <div style={{ fontSize: 12 }}>{i.immatriculation}</div>}
          <div style={{ fontSize: 12 }}>{[i.adresse, i.ville].filter(Boolean).join(', ')}</div>
          <div style={{ fontSize: 12 }}>{[i.telephone && `Tél. ${i.telephone}`, i.email, i.site_web].filter(Boolean).join(' — ')}</div>
        </div>
      </div>
      <div style={{ display: 'flex', justifyContent: 'space-between', gap: 16, marginTop: 8 }}>
        <div>
          <strong>Agence {p.agence}</strong> <span className="muted">({p.agence_code})</span>
          <div style={{ fontSize: 12 }}>{[p.agence_adresse, p.agence_ville].filter(Boolean).join(', ')}</div>
          <div style={{ fontSize: 12 }}>{[p.agence_telephone && `Tél. ${p.agence_telephone}`, p.agence_email].filter(Boolean).join(' — ')}</div>
        </div>
        <div style={{ textAlign: 'right' }}><strong>{p.titre}</strong><div>N° {p.numero}</div><div>Date : {fdate(p.date_piece)}</div></div>
      </div>
      <hr />
      <div>Client : <strong>{p.client}</strong> ({p.client_numero}){p.compte ? <> — compte {p.compte}</> : null}</div>
      <table className="t" style={{ width: '100%', marginTop: 12 }}>
        <thead><tr><th>#</th><th>Désignation</th><th className="num">Montant</th></tr></thead>
        <tbody>
          {p.lignes.map((l) => <tr key={l.ligne}><td>{l.ligne}</td><td>{l.libelle}</td><td className="num">{xof(l.montant)}</td></tr>)}
          <tr><td colSpan={2}><strong>Total</strong></td><td className="num"><strong>{xof(p.montant)}</strong></td></tr>
        </tbody>
      </table>
      <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 32 }}>
        <div>Le client<div style={{ height: 48 }} /></div>
        <div style={{ textAlign: 'right' }}>L'agent{p.utilisateur ? ` (${p.utilisateur})` : ''}<div style={{ height: 48 }} /></div>
      </div>
      {i.pied_de_page && <div style={{ marginTop: 16, borderTop: '1px solid #999', paddingTop: 6, fontSize: 11, textAlign: 'center' }}>{i.pied_de_page}</div>}
    </div>
  )
}

export function PieceModal({ id, onClose }: { id: number; onClose: () => void }) {
  const q = useFetch(() => api.get<PieceDetail>(`/api/pieces/${id}`), [id])
  return (
    <Modal titre="Pièce justificative" onClose={onClose} large footer={<><Button onClick={onClose}>Fermer</Button><Button variant="primary" onClick={() => window.print()}>Imprimer</Button></>}>
      <Charge q={q}>{(p) => <Document p={p} />}</Charge>
    </Modal>
  )
}

/** Ouvre la pièce d'une opération qui vient d'être enregistrée : `ouvrir(piece_id)` puis afficher `modal`. */
export function useAffichagePiece() {
  const [id, setId] = useState<number | null>(null)
  return {
    ouvrir: (pieceId: number | null | undefined) => { if (pieceId) setId(pieceId) },
    modal: id !== null ? <PieceModal id={id} onClose={() => setId(null)} /> : null,
  }
}
