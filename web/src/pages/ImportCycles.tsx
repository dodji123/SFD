import { useState } from 'react'
import { session } from '../lib/api'
import { Alert, Card, Page, Table } from '../components/ui'

interface Erreur { ligne: number; champ: string; motif: string }
interface Apercu { ligne: number; numero: string; client_numero: string; produit_code: string; date_debut: string; date_fin: string; mise: number }
interface Resultat { lignes_lues: number; lignes_valides: number; erreurs: Erreur[]; apercu: Apercu[] }

// Import des cycles de la machine depuis un fichier Excel. Étape 1 : contrôle seul, rien n'est enregistré.
export default function ImportCycles() {
  const [resultat, setResultat] = useState<Resultat | null>(null)
  const [erreur, setErreur] = useState<string | null>(null)
  const [occupe, setOccupe] = useState(false)

  async function controler(fichier: File) {
    setOccupe(true)
    setErreur(null)
    setResultat(null)
    try {
      const corps = new FormData()
      corps.append('fichier', fichier)
      const t = session.getToken()
      const r = await fetch('/api/import/cycles/verifier', { method: 'POST', body: corps, headers: t ? { Authorization: `Bearer ${t}` } : {} })
      const d = await r.json().catch(() => ({}))
      if (!r.ok) throw new Error(d.detail ?? `Erreur ${r.status}`)
      setResultat(d as Resultat)
    } catch (e) {
      setErreur(e instanceof Error ? e.message : 'Contrôle impossible')
    } finally {
      setOccupe(false)
    }
  }

  return (
    <Page title="Import des cycles de la machine" subtitle="Contrôle du fichier Excel avant mise en production. Rien n'est enregistré à cette étape.">
      <Card>
        <p className="muted" style={{ marginTop: 0 }}>Colonnes : numero, client_numero, produit_code, date_debut, date_fin, mise (facultatives : objectif, type_cycle).</p>
        <input type="file" accept=".xlsx" disabled={occupe} onChange={(e) => { const f = e.target.files?.[0]; if (f) void controler(f) }} />
      </Card>
      {occupe && <p className="muted">Contrôle en cours…</p>}
      {erreur && <Alert tone="bad">{erreur}</Alert>}
      {resultat && (
        <>
          <Card>
            <p style={{ margin: 0 }}>
              <strong>{resultat.lignes_lues}</strong> ligne(s) lue(s) · <strong>{resultat.lignes_valides}</strong> acceptée(s) · <strong>{resultat.erreurs.length}</strong> erreur(s)
            </p>
          </Card>
          {resultat.erreurs.length > 0 && (
            <div style={{ marginTop: 16 }}>
              <Card title="Erreurs à corriger" flush>
                <Table rows={resultat.erreurs} cols={[
                  { titre: 'Ligne', num: true, render: (e) => e.ligne },
                  { titre: 'Colonne', render: (e) => e.champ },
                  { titre: 'Motif', render: (e) => e.motif },
                ]} />
              </Card>
            </div>
          )}
          {resultat.apercu.length > 0 && (
            <div style={{ marginTop: 16 }}>
              <Card title="Aperçu des lignes acceptées" flush>
                <Table rows={resultat.apercu} cols={[
                  { titre: 'Cycle', render: (a) => a.numero },
                  { titre: 'Client', render: (a) => a.client_numero },
                  { titre: 'Produit', render: (a) => a.produit_code },
                  { titre: 'Début', render: (a) => a.date_debut },
                  { titre: 'Fin', render: (a) => a.date_fin },
                  { titre: 'Mise', num: true, render: (a) => a.mise },
                ]} />
              </Card>
            </div>
          )}
        </>
      )}
    </Page>
  )
}
