"""Planificateur des traitements quotidiens, à lancer chaque jour par cron ou la tâche planifiée Windows :

    python -m app.cli planifier [--date AAAA-MM-JJ] [--agence-code LOM] [--forcer]

Pour chaque agence active, appelle en base les fonctions de tâche du schéma, dans cet ordre :
clôture des cycles échus, prélèvement des échéances sur compte, passage des échéances en retard (pénalités),
saisie des garanties, purge des dates, écritures de provisions (mode automatique seulement). L'ordre place le prélèvement avant le calcul des retards : une échéance
prélevée le jour même n'est pas marquée en retard.

Chaque (agence, date, tâche) réussie est inscrite dans `execution_tache` ; un index unique empêche d'en inscrire
deux : relancer la même date ne refait pas ce qui est déjà fait (rejouable sans doublon). Une tâche en échec est
journalisée et n'empêche ni les autres tâches ni les autres agences ; elle est retentée au prochain lancement.
`forcer` rejoue aussi les tâches déjà réussies (la réussite précédente passe à « remplace »).
Les règles métier restent dans les fonctions SQL : ce module ne fait que les appeler et les tracer.
"""
import dataclasses
import datetime as dt
import logging

import psycopg2

from .config import settings

log = logging.getLogger("sfd.planificateur")

# ordre d'exécution ; noms = fonctions du schéma et valeurs autorisées de execution_tache.tache
TACHES = (
    "cloturer_cycles_echus",
    "prelever_echeances_compte",
    "maj_statuts_credit",
    "saisir_garantie_echeances",
    "purger_dates",
    "generer_provisions_auto",   # ne fait rien tant que le paramètre prov_mode vaut « manuel »
)
UTILISATEUR = "planificateur"
_VERROU = 47_120_001  # verrou consultatif : un seul planificateur à la fois


@dataclasses.dataclass
class Resultat:
    agence: str
    tache: str
    statut: str  # ok | deja_fait | echec
    nb: int | None = None
    message: str | None = None


def _connexion():
    return psycopg2.connect(settings.database_url, options="-c search_path=mf,public")


def _executer(conn, agence_id: int, tache: str, jour: dt.date, forcer: bool) -> tuple[str, int | None]:
    """Une tâche pour une agence, dans sa propre transaction. Retourne (statut, nombre)."""
    with conn, conn.cursor() as cur:
        cur.execute("SELECT set_config('mf.utilisateur', %s, true)", (UTILISATEUR,))
        if forcer:
            cur.execute(
                "UPDATE execution_tache SET statut = 'remplace' "
                "WHERE agence_id = %s AND date_tache = %s AND tache = %s AND statut = 'ok'",
                (agence_id, jour, tache),
            )
        else:
            cur.execute(
                "SELECT 1 FROM execution_tache WHERE agence_id = %s AND date_tache = %s AND tache = %s AND statut = 'ok'",
                (agence_id, jour, tache),
            )
            if cur.fetchone():
                return "deja_fait", None
        debut = dt.datetime.now(dt.timezone.utc)
        # nom de fonction pris dans la liste blanche TACHES, jamais d'une entrée externe
        cur.execute(f"SELECT {tache}(%s::smallint, %s::date)", (agence_id, jour))
        nb = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO execution_tache(agence_id, date_tache, tache, statut, nb_traites, debut, fin) "
            "VALUES (%s, %s, %s, 'ok', %s, %s, now())",
            (agence_id, jour, tache, nb, debut),
        )
        return "ok", nb


def _journaliser_echec(conn, agence_id: int, tache: str, jour: dt.date, message: str) -> None:
    try:
        with conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO execution_tache(agence_id, date_tache, tache, statut, message, fin) "
                "VALUES (%s, %s, %s, 'echec', %s, now())",
                (agence_id, jour, tache, message[:2000]),
            )
    except psycopg2.Error:
        log.exception("impossible de journaliser l'échec de %s (agence %s)", tache, agence_id)


def planifier(jour: dt.date | None = None, agence_code: str | None = None, forcer: bool = False) -> list[Resultat]:
    """Lance les tâches quotidiennes pour `jour` (aujourd'hui par défaut). Retourne un résultat par agence et par tâche."""
    jour = jour or dt.date.today()
    if jour > dt.date.today():
        raise ValueError(f"Date future refusée : {jour}")
    verrou = _connexion()
    verrou.autocommit = True
    conn = _connexion()
    resultats: list[Resultat] = []
    try:
        with verrou.cursor() as c:
            c.execute("SELECT pg_try_advisory_lock(%s)", (_VERROU,))
            if not c.fetchone()[0]:
                raise RuntimeError("Un autre planificateur est déjà en cours d'exécution")
        with conn, conn.cursor() as cur:
            if agence_code:
                cur.execute("SELECT id, code FROM agence WHERE code = %s AND actif", (agence_code,))
            else:
                cur.execute("SELECT id, code FROM agence WHERE actif ORDER BY id")
            agences = cur.fetchall()
        if agence_code and not agences:
            raise ValueError(f"Agence active inconnue : {agence_code}")
        log.info("début du planificateur : date %s, %d agence(s), forcer=%s", jour, len(agences), forcer)
        for agence_id, code in agences:
            for tache in TACHES:
                try:
                    statut, nb = _executer(conn, agence_id, tache, jour, forcer)
                    r = Resultat(code, tache, statut, nb)
                except Exception as e:  # une tâche en échec ne bloque ni les suivantes ni les autres agences
                    conn.rollback()
                    r = Resultat(code, tache, "echec", None, str(e).strip())
                    _journaliser_echec(conn, agence_id, tache, jour, r.message or "")
                    log.error("agence %s, %s : ÉCHEC : %s", code, tache, r.message)
                else:
                    log.info("agence %s, %s : %s%s", code, tache, statut, "" if nb is None else f" ({nb})")
                resultats.append(r)
        echecs = sum(r.statut == "echec" for r in resultats)
        log.info("fin du planificateur : %d tâche(s), %d échec(s)", len(resultats), echecs)
        return resultats
    finally:
        conn.close()
        verrou.close()  # libère le verrou consultatif
