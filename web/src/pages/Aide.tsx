import { useState } from 'react'
import { CHAPITRES, type Chapitre, type Section } from '../aide/manuel'
import { Card, Page } from '../components/ui'

/** Manuel d'utilisation intégré : un chapitre à la fois, sommaire à gauche, impression possible. */
export default function Aide() {
  const [actif, setActif] = useState(CHAPITRES[0].id)
  const chapitre = CHAPITRES.find((c) => c.id === actif) ?? CHAPITRES[0]
  return (
    <Page title="Aide et manuel d'utilisation" subtitle="Mode d'emploi des écrans, chapitre par chapitre. Ce qui n'est pas encore disponible est signalé.">
      <div className="aide-grille">
        <nav className="aide-sommaire" aria-label="Chapitres du manuel">
          {CHAPITRES.map((c) => (
            <button key={c.id} type="button" className={`aide-lien ${c.id === actif ? 'actif' : ''}`} aria-current={c.id === actif ? 'true' : undefined} onClick={() => setActif(c.id)}>
              {c.titre}
            </button>
          ))}
        </nav>
        <article className="aide-contenu">
          <ChapitreVue chapitre={chapitre} />
          <div className="aide-pied no-print">
            <button type="button" className="btn btn-sm" onClick={() => window.print()}>Imprimer ce chapitre</button>
          </div>
        </article>
      </div>
    </Page>
  )
}

function ChapitreVue({ chapitre }: { chapitre: Chapitre }) {
  return (
    <Card title={chapitre.titre}>
      <p className="muted">{chapitre.intro}</p>
      {chapitre.sections.map((s) => <SectionVue key={s.titre} section={s} />)}
    </Card>
  )
}

function SectionVue({ section }: { section: Section }) {
  return (
    <section className="aide-section">
      <h3>{section.titre}</h3>
      {section.paragraphes?.map((p, i) => <p key={i}>{p}</p>)}
      {section.etapes && (
        <ol>{section.etapes.map((e, i) => <li key={i}>{e}</li>)}</ol>
      )}
      {section.notes?.map((n, i) => (
        <p key={i} className="aide-note"><strong>À noter :</strong> {n}</p>
      ))}
    </section>
  )
}
