"""Fiche de l'institution et coordonnées des agences : en-tête des pièces justificatives et des documents."""
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..auth import User, require
from ..db import one_row, tx

router = APIRouter(prefix="/api", tags=["institution"])

LOGO = r"^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$"


class InstitutionIn(BaseModel):
    raison_sociale: str = Field(min_length=1, max_length=200)
    sigle: str | None = Field(default=None, max_length=20)
    agrement: str | None = Field(default=None, max_length=300)
    immatriculation: str | None = Field(default=None, max_length=200)
    adresse: str | None = Field(default=None, max_length=300)
    ville: str | None = Field(default=None, max_length=100)
    telephone: str | None = Field(default=None, max_length=40)
    email: str | None = Field(default=None, max_length=200)
    site_web: str | None = Field(default=None, max_length=200)
    logo: str | None = Field(default=None, pattern=LOGO, max_length=400000)       # image PNG, JPEG ou WebP en base64 (400 Ko au plus)
    pied_de_page: str | None = Field(default=None, max_length=500)


@router.get("/institution")
def lire(user: User = Depends(require("ref:read"))):
    with tx() as cur:
        return one_row(cur, "SELECT * FROM institution WHERE id = 1")


@router.put("/institution")
def modifier(body: InstitutionIn, user: User = Depends(require("params:write"))):
    """La fiche de l'institution est unique ; seul l'administrateur la modifie."""
    champs = body.model_dump()
    with tx(user.login) as cur:
        cur.execute("UPDATE institution SET " + ", ".join(f"{c} = %s" for c in champs) + ", modifie_le = now() WHERE id = 1", list(champs.values()))
        return one_row(cur, "SELECT * FROM institution WHERE id = 1")


class AgenceCoordonneesIn(BaseModel):
    libelle: str | None = Field(default=None, min_length=1, max_length=200)
    adresse: str | None = Field(default=None, max_length=300)
    ville: str | None = Field(default=None, max_length=100)
    telephone: str | None = Field(default=None, max_length=40)
    email: str | None = Field(default=None, max_length=200)


@router.patch("/agences/{agence_id}")
def modifier_agence(agence_id: int, body: AgenceCoordonneesIn, user: User = Depends(require("agences:write"))):
    """Coordonnées d'une agence (reprises dans l'en-tête des pièces qu'elle émet). Seuls les champs transmis changent."""
    champs = body.model_dump(exclude_unset=True)
    if champs.get("libelle", "") is None:
        raise HTTPException(status_code=422, detail="Le libellé de l'agence est obligatoire")
    if not champs:
        raise HTTPException(status_code=422, detail="Aucun champ à modifier")
    with tx(user.login) as cur:
        r = one_row(cur, "UPDATE agence SET " + ", ".join(f"{c} = %s" for c in champs) + " WHERE id = %s RETURNING *", [*champs.values(), agence_id])
        if r is None:
            raise HTTPException(status_code=404, detail="Agence inconnue")
        return r
