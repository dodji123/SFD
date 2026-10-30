import { SoldeARetirer } from './RapportSoldeARetirer'

// Soldes que les clients pouvaient retirer à une date donnée.
export default function RapportSoldeARetirerDate() {
  return <SoldeARetirer titre="Solde à retirer à une date" subtitre="Ce que les clients pouvaient retirer à la date choisie, par produit, client et cycle" alaDate />
}
