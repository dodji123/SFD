"""KYC (profil, pièces, liens, validation), garants de crédit et conformité LBC/FT (listes, alertes).

Le filtrage des noms et les règles de blocage du crédit vivent dans la base (module 17) ; l'API ne fait que
les exposer et contrôler les droits et le cloisonnement par agence."""
import datetime as dt
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field

from ..auth import User, agence_filter, require, verifier_agence
from ..db import all_rows, one_row, tx

router = APIRouter(prefix="/api", tags=["kyc-lbc"])

PROFIL = ("id, agence_id, numero, nom, telephone, type_client, sexe, date_naissance, profession, adresse, "
          "latitude_domicile, longitude_domicile, latitude_activite, longitude_activite, photo_ref, ppe, "
          "qualite_interne, statut_kyc, kyc_valide_le, kyc_valide_par")


class ProfilIn(BaseModel):
    type_client: Literal["physique", "groupe_solidaire", "personne_morale", "cooperative"] | None = None
    sexe: Literal["F", "M"] | None = None
    date_naissance: dt.date | None = None
    profession: str | None = None
    adresse: str | None = None
    latitude_domicile: float | None = Field(default=None, ge=-90, le=90)
    longitude_domicile: float | None = Field(default=None, ge=-180, le=180)
    latitude_activite: float | None = Field(default=None, ge=-90, le=90)
    longitude_activite: float | None = Field(default=None, ge=-180, le=180)
    photo_ref: str | None = None
    qualite_interne: Literal["aucune", "dirigeant", "personnel", "personne_liee"] | None = None


class PieceIn(BaseModel):
    type: Literal["cni", "passeport", "carte_electeur", "permis", "carte_consulaire", "registre_commerce", "statuts", "autre"]
    numero: str = Field(min_length=1, max_length=40)
    date_emission: dt.date | None = None
    date_expiration: dt.date | None = None
    fichier_ref: str | None = None


class LienIn(BaseModel):
    lie_a_id: int
    type: Literal["famille", "groupe", "employeur", "associe", "autre"]
    note: str | None = None


def _dossier(cur, client_id: int) -> dict:
    c = one_row(cur, f"SELECT {PROFIL} FROM client WHERE id = %s", (client_id,))
    c["manquants"] = one_row(cur, "SELECT kyc_manquants(%s) AS m", (client_id,))["m"]
    c["pieces"] = all_rows(cur, "SELECT id, type, numero, date_emission, date_expiration, fichier_ref FROM piece_identite WHERE client_id = %s ORDER BY id", (client_id,))
    c["liens"] = all_rows(
        cur, "SELECT l.id, l.type, l.note, l.lie_a_id, o.nom AS lie_a_nom, o.numero AS lie_a_numero FROM lien_client l "
             "JOIN client o ON o.id = l.lie_a_id WHERE l.client_id = %s ORDER BY l.id", (client_id,))
    c["alertes"] = all_rows(
        cur, "SELECT a.id, a.type, a.score, a.statut, a.note, s.nom AS nom_liste, s.source FROM alerte_lbc a "
             "JOIN liste_surveillance s ON s.id = a.liste_id WHERE a.client_id = %s ORDER BY a.id", (client_id,))
    return c


# ---------------------------------------------------------------- dossier KYC d'un client
@router.get("/clients/{client_id}/kyc")
def dossier_kyc(client_id: int, user: User = Depends(require("ref:read"))):
    with tx() as cur:
        verifier_agence(cur, user, "client", client_id)
        return _dossier(cur, client_id)


@router.put("/clients/{client_id}/profil")
def modifier_profil(client_id: int, body: ProfilIn, user: User = Depends(require("ref:write"))):
    champs = body.model_dump(exclude_unset=True)
    if not champs:
        raise HTTPException(status_code=422, detail="Aucune modification")
    with tx(user.login) as cur:
        verifier_agence(cur, user, "client", client_id)
        sets = ", ".join(f"{c} = %s" for c in champs)
        cur.execute(f"UPDATE client SET {sets} WHERE id = %s", (*champs.values(), client_id))
        return _dossier(cur, client_id)


@router.post("/clients/{client_id}/pieces", status_code=201)
def ajouter_piece(client_id: int, body: PieceIn, user: User = Depends(require("ref:write"))):
    with tx(user.login) as cur:
        verifier_agence(cur, user, "client", client_id)
        cur.execute("INSERT INTO piece_identite(client_id, type, numero, date_emission, date_expiration, fichier_ref) VALUES (%s,%s,%s,%s,%s,%s)",
                    (client_id, body.type, body.numero, body.date_emission, body.date_expiration, body.fichier_ref))
        return _dossier(cur, client_id)


@router.post("/clients/{client_id}/liens", status_code=201)
def ajouter_lien(client_id: int, body: LienIn, user: User = Depends(require("ref:write"))):
    with tx(user.login) as cur:
        ag = verifier_agence(cur, user, "client", client_id)
        autre = one_row(cur, "SELECT agence_id FROM client WHERE id = %s", (body.lie_a_id,))
        if autre is None or autre["agence_id"] != ag:
            raise HTTPException(status_code=422, detail="Le client lié doit exister dans la même agence")
        cur.execute("INSERT INTO lien_client(client_id, lie_a_id, type, note) VALUES (%s,%s,%s,%s)", (client_id, body.lie_a_id, body.type, body.note))
        return _dossier(cur, client_id)


@router.post("/clients/{client_id}/kyc/valider")
def valider_kyc(client_id: int, user: User = Depends(require("kyc:validate"))):
    """Valide le dossier. Un client PPE ne peut être validé que par la direction ou l'administrateur."""
    with tx(user.login) as cur:
        verifier_agence(cur, user, "client", client_id)
        c = one_row(cur, "SELECT ppe FROM client WHERE id = %s", (client_id,))
        if c["ppe"] and user.role not in ("admin", "directeur"):
            raise HTTPException(status_code=403, detail="La validation d'un client politiquement exposé revient à la direction")
        cur.execute("SELECT valider_kyc(%s, %s)", (client_id, user.id))
        return _dossier(cur, client_id)


@router.get("/kyc/pieces-a-renouveler")
def pieces_a_renouveler(agence_id: int | None = None, user: User = Depends(require("ref:read"))):
    """Pièces expirées ou qui expirent dans les 30 jours."""
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, "SELECT * FROM v_pieces_a_renouveler WHERE (%s::int IS NULL OR agence_id = %s) ORDER BY date_expiration", (ag, ag))


# ---------------------------------------------------------------- garants
class GarantIn(BaseModel):
    garant_client_id: int
    montant_caution: int = Field(gt=0)


def _garants(cur, demande_id: int) -> list[dict]:
    return all_rows(cur, "SELECT g.id, g.garant_client_id, c.nom, c.numero, g.montant_caution, g.statut FROM garant_credit g "
                         "JOIN client c ON c.id = g.garant_client_id WHERE g.demande_id = %s ORDER BY g.id", (demande_id,))


@router.post("/demandes-credit/{demande_id}/garants", status_code=201)
def ajouter_garant(demande_id: int, body: GarantIn, user: User = Depends(require("credit:request"))):
    with tx(user.login) as cur:
        ag = verifier_agence(cur, user, "demande_credit", demande_id)
        g = one_row(cur, "SELECT agence_id FROM client WHERE id = %s", (body.garant_client_id,))
        if g is None or g["agence_id"] != ag:
            raise HTTPException(status_code=422, detail="Le garant doit être un client de la même agence")
        cur.execute("INSERT INTO garant_credit(demande_id, garant_client_id, montant_caution) VALUES (%s,%s,%s)",
                    (demande_id, body.garant_client_id, body.montant_caution))
        return _garants(cur, demande_id)


@router.get("/demandes-credit/{demande_id}/garants")
def lister_garants(demande_id: int, user: User = Depends(require("credit:read"))):
    with tx() as cur:
        verifier_agence(cur, user, "demande_credit", demande_id)
        return _garants(cur, demande_id)


# ---------------------------------------------------------------- LBC/FT
ALERTE = ("SELECT a.id, a.client_id, c.numero AS client_numero, c.nom AS client, c.agence_id, a.type, a.score, a.statut, a.note, "
          "       s.nom AS nom_liste, s.source, s.reference, s.pays, a.cree_le, a.decide_le, u.login AS decide_par "
          "FROM alerte_lbc a JOIN client c ON c.id = a.client_id JOIN liste_surveillance s ON s.id = a.liste_id "
          "LEFT JOIN utilisateur u ON u.id = a.decide_par ")


@router.get("/lbc/alertes")
def lister_alertes(statut: Literal["a_examiner", "confirmee", "ecartee"] | None = None, agence_id: int | None = None,
                   limit: int = Query(200, ge=1, le=1000), user: User = Depends(require("lbc:read"))):
    ag = agence_filter(user, agence_id)
    with tx() as cur:
        return all_rows(cur, ALERTE + "WHERE (%s::int IS NULL OR c.agence_id = %s) AND (%s::text IS NULL OR a.statut = %s) "
                                      "ORDER BY (a.statut = 'a_examiner') DESC, a.score DESC, a.id DESC LIMIT %s", (ag, ag, statut, statut, limit))


class DecisionIn(BaseModel):
    decision: Literal["confirmee", "ecartee"]
    note: str | None = None


@router.post("/lbc/alertes/{alerte_id}/traiter")
def traiter_alerte(alerte_id: int, body: DecisionIn, user: User = Depends(require("lbc:write"))):
    with tx(user.login) as cur:
        a = one_row(cur, "SELECT client_id FROM alerte_lbc WHERE id = %s", (alerte_id,))
        if a is None:
            raise HTTPException(status_code=404, detail="Introuvable")
        verifier_agence(cur, user, "client", a["client_id"])
        cur.execute("SELECT traiter_alerte_lbc(%s, %s, %s, %s)", (alerte_id, body.decision, body.note, user.id))
        return one_row(cur, ALERTE + "WHERE a.id = %s", (alerte_id,))


class EntreeListe(BaseModel):
    nom: str = Field(min_length=2)
    date_naissance: dt.date | None = None
    pays: str | None = None
    reference: str | None = None


class ListeIn(BaseModel):
    source: str = Field(min_length=1, max_length=60)
    categorie: Literal["sanction", "ppe"]
    entrees: list[EntreeListe] = Field(min_length=1, max_length=5000)


@router.post("/lbc/listes", status_code=201)
def importer_liste(body: ListeIn, user: User = Depends(require("lbc:listes"))):
    """Ajoute des entrées à la liste de surveillance ; les clients existants sont aussitôt confrontés aux nouvelles entrées."""
    with tx(user.login) as cur:
        for e in body.entrees:
            cur.execute("INSERT INTO liste_surveillance(source, categorie, nom, date_naissance, pays, reference) VALUES (%s,%s,%s,%s,%s,%s)",
                        (body.source, body.categorie, e.nom, e.date_naissance, e.pays, e.reference))
        nb = one_row(cur, "SELECT count(*) AS n FROM alerte_lbc WHERE statut = 'a_examiner'")["n"]
    return {"entrees_ajoutees": len(body.entrees), "alertes_a_examiner": nb}


@router.get("/lbc/listes")
def resume_listes(user: User = Depends(require("lbc:read"))):
    with tx() as cur:
        return all_rows(cur, "SELECT source, categorie, count(*) FILTER (WHERE actif) AS entrees FROM liste_surveillance GROUP BY source, categorie ORDER BY source")
