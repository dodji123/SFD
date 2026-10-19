import { useEffect, useState } from 'react'
import { api } from '../lib/api'
import { useSession } from '../lib/session'
import { Alert, Button, Card, Charge, Field, FormModal, Input, Table, useAction, useFetch } from '../components/ui'

interface Institution {
  raison_sociale: string; sigle: string | null; agrement: string | null; immatriculation: string | null; adresse: string | null; ville: string | null
  telephone: string | null; email: string | null; site_web: string | null; logo: string | null; pied_de_page: string | null
}
interface AgenceFiche { id: number; code: string; libelle: string; adresse: string | null; ville: string | null; telephone: string | null; email: string | null }

const TAILLE_LOGO_MAX = 300_000       // octets du fichier (la base accepte 400 000 caractères en base64)

/** En-tête des pièces : fiche de l'institution et coordonnées de chaque agence. */
export default function InstitutionAdmin() {
  const { can } = useSession()
  const inst = useFetch(() => api.get<Institution>('/api/institution'), [])
  const agences = useFetch(() => api.get<AgenceFiche[]>('/api/agences'), [])
  const [modif, setModif] = useState<AgenceFiche | null>(null)
  return (
    <div className="stack">
      <Alert tone="info">Ces informations forment l'en-tête des pièces justificatives : l'institution en haut, puis l'agence qui émet la pièce.</Alert>
      <Charge q={inst}>{(i) => <FicheInstitution i={i} peut={can('params:write')} onFait={inst.reload} />}</Charge>
      <Card title="Coordonnées des agences" flush>
        <Charge q={agences}>
          {(rows) => (
            <Table rows={rows} vide="Aucune agence" cols={[
              { titre: 'Agence', render: (a) => <><strong>{a.code}</strong> — {a.libelle}</> },
              { titre: 'Adresse', render: (a) => [a.adresse, a.ville].filter(Boolean).join(', ') || <span className="muted">non renseignée</span> },
              { titre: 'Contact', render: (a) => [a.telephone, a.email].filter(Boolean).join(' — ') || <span className="muted">non renseigné</span> },
              { titre: '', render: (a) => (can('agences:write') ? <Button small onClick={() => setModif(a)}>Modifier</Button> : null) },
            ]} />
          )}
        </Charge>
      </Card>
      {modif && <ModifierAgence a={modif} onClose={() => setModif(null)} onFait={() => { setModif(null); agences.reload() }} />}
    </div>
  )
}

function FicheInstitution({ i, peut, onFait }: { i: Institution; peut: boolean; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState<Institution>(i)
  const [erreurLogo, setErreurLogo] = useState<string | null>(null)
  useEffect(() => setF(i), [i])
  const maj = (k: keyof Institution) => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...f, [k]: e.target.value })
  const vide = (v: string | null) => (v && v.trim() ? v.trim() : null)

  function choisirLogo(e: React.ChangeEvent<HTMLInputElement>) {
    setErreurLogo(null)
    const fichier = e.target.files?.[0]
    if (!fichier) return
    if (!['image/png', 'image/jpeg', 'image/webp'].includes(fichier.type)) { setErreurLogo('Format accepté : PNG, JPEG ou WebP.'); return }
    if (fichier.size > TAILLE_LOGO_MAX) { setErreurLogo('Image trop lourde (300 Ko au plus).'); return }
    const lecteur = new FileReader()
    lecteur.onload = () => setF((cur) => ({ ...cur, logo: String(lecteur.result) }))
    lecteur.readAsDataURL(fichier)
  }

  return (
    <Card title="Institution" actions={peut && <Button variant="primary" small disabled={busy || !f.raison_sociale.trim()}
      onClick={() => void run(() => api.put('/api/institution', {
        raison_sociale: f.raison_sociale.trim(), sigle: vide(f.sigle), agrement: vide(f.agrement), immatriculation: vide(f.immatriculation), adresse: vide(f.adresse),
        ville: vide(f.ville), telephone: vide(f.telephone), email: vide(f.email), site_web: vide(f.site_web), logo: f.logo, pied_de_page: vide(f.pied_de_page),
      }), 'Fiche de l\'institution enregistrée', onFait)}>Enregistrer</Button>}>
      <div className="row">
        <Field label="Raison sociale"><Input value={f.raison_sociale} disabled={!peut} onChange={maj('raison_sociale')} /></Field>
        <Field label="Sigle"><Input value={f.sigle ?? ''} maxLength={20} disabled={!peut} onChange={maj('sigle')} /></Field>
        <Field label="Agrément" hint="ex. décision d'agrément"><Input value={f.agrement ?? ''} disabled={!peut} onChange={maj('agrement')} /></Field>
        <Field label="N° d'immatriculation (RCCM…)"><Input value={f.immatriculation ?? ''} disabled={!peut} onChange={maj('immatriculation')} /></Field>
      </div>
      <div className="row">
        <Field label="Adresse"><Input value={f.adresse ?? ''} disabled={!peut} onChange={maj('adresse')} /></Field>
        <Field label="Ville"><Input value={f.ville ?? ''} disabled={!peut} onChange={maj('ville')} /></Field>
        <Field label="Téléphone"><Input value={f.telephone ?? ''} disabled={!peut} onChange={maj('telephone')} /></Field>
        <Field label="Courriel"><Input type="email" value={f.email ?? ''} disabled={!peut} onChange={maj('email')} /></Field>
        <Field label="Site web"><Input value={f.site_web ?? ''} disabled={!peut} onChange={maj('site_web')} /></Field>
      </div>
      <div className="row">
        <Field label="Pied de page des pièces"><Input value={f.pied_de_page ?? ''} maxLength={500} disabled={!peut} onChange={maj('pied_de_page')} /></Field>
        {peut && <Field label="Logo (PNG, JPEG ou WebP, 300 Ko au plus)"><Input type="file" accept="image/png,image/jpeg,image/webp" onChange={choisirLogo} /></Field>}
        {f.logo && (
          <div>
            <img src={f.logo} alt="Logo de l'institution" style={{ maxHeight: 64, maxWidth: 160, objectFit: 'contain', display: 'block' }} />
            {peut && <Button small onClick={() => setF({ ...f, logo: null })}>Retirer le logo</Button>}
          </div>
        )}
      </div>
      {erreurLogo && <Alert tone="bad">{erreurLogo}</Alert>}
    </Card>
  )
}

function ModifierAgence({ a, onClose, onFait }: { a: AgenceFiche; onClose: () => void; onFait: () => void }) {
  const { run, busy } = useAction()
  const [f, setF] = useState({ adresse: a.adresse ?? '', ville: a.ville ?? '', telephone: a.telephone ?? '', email: a.email ?? '' })
  const maj = (k: keyof typeof f) => (e: React.ChangeEvent<HTMLInputElement>) => setF({ ...f, [k]: e.target.value })
  const vide = (v: string) => (v.trim() ? v.trim() : null)
  return (
    <FormModal titre={`Coordonnées de l'agence ${a.code}`} onClose={onClose} busy={busy} valider="Enregistrer"
      onSubmit={() => void run(() => api.patch(`/api/agences/${a.id}`, { adresse: vide(f.adresse), ville: vide(f.ville), telephone: vide(f.telephone), email: vide(f.email) }), 'Coordonnées enregistrées', onFait)}>
      <Field label="Adresse"><Input value={f.adresse} onChange={maj('adresse')} /></Field>
      <Field label="Ville"><Input value={f.ville} onChange={maj('ville')} /></Field>
      <Field label="Téléphone"><Input value={f.telephone} onChange={maj('telephone')} /></Field>
      <Field label="Courriel"><Input type="email" value={f.email} onChange={maj('email')} /></Field>
    </FormModal>
  )
}
