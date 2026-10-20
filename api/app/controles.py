"""Contrôles internes appliqués aux opérations : seuils de retrait par niveau, anti-fractionnement, comptes dormants,
séparation des tâches. Le verdict vient du schéma (module 36) ; l'alerte est enregistrée dans une transaction à part
pour survivre au refus de l'opération."""
import datetime as dt

from fastapi import HTTPException

from .auth import User
from .db import one_row, tx
from .securite import alerter


def controler_seuil_retrait(cur, user: User, client_id: int, agence_id: int, montant: float, date: dt.date | None = None) -> None:
    """Refuse (403) un retrait au-dessus du plafond du rôle, ou qui fractionne un retrait plus gros ; alerte dans ce dernier cas."""
    v = one_row(cur, "SELECT * FROM controle_seuil_retrait(%s, %s, %s::smallint, %s, COALESCE(%s, current_date))",
                (user.role, client_id, agence_id, montant, date))
    if v["statut"] == "ok":
        return
    if v["statut"] == "fractionnement":
        with tx(user.login) as autre:        # connexion distincte : l'alerte est validée même si l'opération est refusée
            alerter(autre, "retraits_fractionnes",
                    f"Retrait de {int(montant)} F refusé pour {user.login} : avec {int(v['cumul'])} F déjà retirés aujourd'hui par ce client, "
                    f"le total dépasse le plafond de {int(v['seuil'])} F (fractionnement ?)", "elevee", user.id, agence_id)
        raise HTTPException(
            status_code=403,
            detail=f"Fractionnement suspect : {int(v['cumul'])} F déjà retirés aujourd'hui par ce client ; avec ce retrait le total dépasse "
                   f"votre plafond de {int(v['seuil'])} F. Le chef d'agence ou la direction doit traiter ce retrait.")
    raise HTTPException(status_code=403,
                        detail=f"Ce retrait dépasse votre plafond de {int(v['seuil'])} F : il doit être exécuté par le chef d'agence ou la direction.")


def compte_dormant(cur, compte_id: int) -> dict | None:
    return one_row(cur, "SELECT jours_inactif, dernier_mouvement FROM v_compte_dormant WHERE compte_id = %s", (compte_id,))
