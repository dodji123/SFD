# Conformité au guide méthodologique du contrôle interne (état au 20/10/2026)

Légende : ✔ couvert · ◐ partiel · ✗ manquant · ⚙ organisationnel (hors logiciel).
Matrice établie sur les fiches lues (crédit, sécurité informatique, audit, épargne, caisse, recouvrement). Les chapitres RH, contrôle de gestion, communication aux autorités et « autres produits » n'ont pas été relus en détail.

## Crédit
| Exigence | État | Où / limite |
|---|---|---|
| Instruction du dossier, analyse de capacité | ✔ | modules 31-32 |
| Comité de crédit : convocation, quorum + majorité, votes motivés, décision motivée, PV signé et figé | ✔ | module 35, page « Comité de crédit » |
| Compétence par montant, niveaux agence / réseau / siège, délégations | ✔ | module 35 |
| Conflit d'intérêts | ◐ | récusation déclarée ; pas de détection automatique |
| Visite et contre-visite selon le montant | ✔ | seuils provisoires à valider |
| Séparation approbation / décaissement | ◐ | paramètre `separation_decaissement`, désactivé par défaut |
| Contrat de crédit à signer, certificat de clôture | ✔ | page Recouvrement › « Contrat et certificat » (impression ; pas de signature électronique) |
| Recouvrement par étapes (amiable → mise en demeure → avals / garanties), actions non modifiables | ✔ | module 37 |
| Passage en perte (mise en demeure, visite, retard minimal, approbateur ≠ agent) | ◐ | enregistré (radiation) ; le passage en charges comptable n'est pas automatisé et le crédit n'est pas encore exclu des rapports de portefeuille |
| Rééchelonnement = nouveau dossier décidé par le comité | ◐ | la demande est créée ; le règlement de l'ancien crédit à la mise en place du nouveau reste manuel |
| Courrier de mise en demeure généré | ✗ | l'action est enregistrée, pas le courrier |

## Caisse et épargne
| Exigence | État | Où / limite |
|---|---|---|
| Plafond de retrait par niveau + anti-fractionnement + alerte | ✔ | module 36, seuils provisoires |
| Procuration validée par une autre personne, bornée (période, plafond) | ✔ | module 38 |
| Double / triple signature des chèques (préparateur ≠ signataire) | ✔ | module 38 ; le président du conseil est représenté par un administrateur |
| Comptes dormants : liste, blocage du caissier, clôture (solde nul) ou blocage | ✔ | modules 36 et 38 |
| Reçus numérotés immuables | ✔ | module 29 |
| Écarts de caisse, rapprochement bancaire | ✔ | modules 02, 13, 22 |
| Petite caisse | ✗ | |

## Sécurité
| Exigence | État | Où / limite |
|---|---|---|
| Mot de passe temporaire, politique, historique, validité | ✔ | module 34 |
| Récupération du mot de passe (lien à usage unique) | ◐ | envoi par SMTP (`SFD_MAIL_MODE=smtp`) ; non essayé avec un vrai serveur de messagerie |
| Session ≤ 15 min d'inactivité | ✔ | |
| Verrouillage, journal des connexions (ajout seul), alertes | ✔ | |
| Sauvegarde automatisée + test de restauration | ◐ | `python -m app.cli sauvegarder --dossier D --tester` (essayé sur Docker : 117 tables restaurées) ; **à planifier** avec le planificateur du système (cron / tâche Windows) |
| Test de restauration par une personne distincte | ✔ | onglet Sécurité |
| Chiffrement au repos, HTTPS | ⚙ | à l'hébergement |

## Rôles
Périmètre agence / réseau / siège (module 33), rôle « coordinateur ».

## Rapports aux autorités, programme d'inspection
✗ Non couverts.
