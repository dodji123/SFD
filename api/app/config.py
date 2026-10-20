"""Configuration par variables d'environnement préfixées SFD_ (ou fichier .env)."""
import logging
import pathlib

from pydantic_settings import BaseSettings, SettingsConfigDict

log = logging.getLogger("sfd")

# .env cherché à côté du dossier app/, quel que soit le dossier de lancement
ENV_FILE = pathlib.Path(__file__).resolve().parents[1] / ".env"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_prefix="SFD_", env_file=str(ENV_FILE), extra="ignore")

    env: str = "dev"  # dev | test | prod
    database_url: str = "postgresql://postgres:sfd@localhost:5440/sfd"
    pool_max: int = 20
    jwt_secret: str = ""
    session_inactivity_minutes: int = 15  # guide du contrôle interne : session du personnel <= 15 min d'inactivité
    password_max_age_days: int = 90       # changement périodique obligatoire (0 = désactivé)
    password_history: int = 5             # nombre de derniers mots de passe interdits à la réutilisation
    reset_token_minutes: int = 30         # durée de vie du lien de récupération
    reset_max_per_hour: int = 3           # demandes de récupération par compte et par heure
    app_url: str = "http://localhost:5173"  # base des liens envoyés (récupération du mot de passe)
    mail_mode: str = "console"            # console (développement : message journalisé) | smtp | disabled
    smtp_host: str = ""
    smtp_port: int = 587
    smtp_user: str = ""
    smtp_password: str = ""
    smtp_from: str = ""                   # adresse expéditrice (obligatoire en mode smtp)
    smtp_starttls: bool = True
    backup_docker_container: str = ""     # ex. sfd-pg : utiliser pg_dump / psql de ce conteneur plutôt que ceux du poste
    heures_ouvrables: str = "06-21"       # connexions hors de cette plage : alerte (HH-HH, heure locale du serveur)
    cors_origins: str = "http://localhost:5173,http://127.0.0.1:5173"
    max_failed_logins: int = 5
    lockout_minutes: int = 15
    password_min_length: int = 10
    # espace client
    client_token_minutes: int = 15       # session courte
    otp_minutes: int = 5                 # durée de vie du code SMS
    otp_max_attempts: int = 3
    otp_max_per_15min: int = 3           # codes demandés par fenêtre de 15 minutes
    client_max_failed_pin: int = 5
    ip_max_attempts_10min: int = 30      # tentatives de connexion par adresse IP
    sms_mode: str = "console"            # console (développement : le code est journalisé) | disabled

    def secret(self) -> str:
        """Secret JWT : obligatoire hors développement."""
        if self.jwt_secret:
            return self.jwt_secret
        if self.env == "dev":
            log.warning("SFD_JWT_SECRET absent : secret de développement utilisé (jamais en production)")
            return "dev-secret-ne-pas-utiliser-en-production"
        raise RuntimeError("SFD_JWT_SECRET est obligatoire hors environnement dev")


settings = Settings()
