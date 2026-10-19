"""Point d'entrée : uvicorn app.main:app"""
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from . import errors
from .config import settings
from .db import close_pool, init_pool, one_row, tx
from .routers import admin as r_admin
from .routers import adhesion as r_adhesion
from .routers import auth as r_auth
from .routers import caisse as r_caisse
from .routers import collecte as r_collecte
from .routers import compta as r_compta
from .routers import credits as r_credits
from .routers import depots as r_depots
from .routers import epargne as r_epargne
from .routers import rapports as r_rapports
from .routers import espace as r_espace
from .routers import etats as r_etats
from .routers import kyc as r_kyc
from .routers import provisions as r_provisions
from .routers import reglementaire as r_reglementaire
from .routers import rapprochement as r_rapprochement
from .routers import referentiels as r_referentiels
from .routers import retraits as r_retraits
from .routers import rh as r_rh
from .routers import transferts as r_transferts
from .routers import tresorerie as r_tresorerie
from .routers import utilisateurs as r_utilisateurs

ROUTERS = [r_auth.router, r_utilisateurs.router, r_referentiels.router, r_epargne.router, r_collecte.router, r_adhesion.router, r_depots.router,
           r_caisse.router, r_retraits.router, r_credits.router, r_rapports.router, r_compta.router, r_admin.router, r_rh.router, r_tresorerie.router, r_transferts.router, r_etats.router, r_kyc.router, r_espace.router, r_espace.admin_router, r_reglementaire.router, r_provisions.router, r_rapprochement.router]


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings.secret()  # échoue au démarrage si le secret JWT manque hors développement
    init_pool()
    yield
    close_pool()


def create_app() -> FastAPI:
    prod = settings.env == "prod"
    # documentation interactive désactivée en production
    app = FastAPI(title="Plateforme SFD", version="0.1.0", lifespan=lifespan,
                  docs_url=None if prod else "/docs", redoc_url=None, openapi_url=None if prod else "/openapi.json")
    app.add_middleware(
        CORSMiddleware,
        allow_origins=[o.strip() for o in settings.cors_origins.split(",") if o.strip()],
        allow_methods=["*"],
        allow_headers=["Authorization", "Content-Type"],
    )
    errors.install(app)

    @app.middleware("http")
    async def entetes_securite(request, call_next):
        reponse = await call_next(request)
        reponse.headers["X-Content-Type-Options"] = "nosniff"
        reponse.headers["X-Frame-Options"] = "DENY"
        reponse.headers["Referrer-Policy"] = "no-referrer"
        reponse.headers["Permissions-Policy"] = "geolocation=(), camera=(), microphone=()"
        if request.url.path.startswith("/api/"):
            reponse.headers["Cache-Control"] = "no-store"          # aucune donnée de compte dans les caches
        return reponse
    for r in ROUTERS:
        app.include_router(r)

    @app.get("/api/health", tags=["sante"])
    def health():
        with tx() as cur:
            ok = one_row(cur, "SELECT 1 AS ok") is not None
        return {"status": "ok" if ok else "ko"}

    return app


app = create_app()
