"""Matrice des permissions : permission -> rôles autorisés.

L'auditeur est en lecture seule partout où la lecture existe. Le cloisonnement par agence est appliqué
séparément (voir auth.agence_scope) : seuls admin, directeur, comptable et auditeur peuvent être au siège
et voir plusieurs agences.
"""
ADMIN, DIR, CHEF, CAIS, COMPTA, AGENT, COLL, RH, AUD = (
    "admin", "directeur", "chef_agence", "caissier", "comptable", "agent", "collectrice", "rh", "auditeur",
)
ALL = {ADMIN, DIR, CHEF, CAIS, COMPTA, AGENT, COLL, RH, AUD}

PERMS: dict[str, set[str]] = {
    "ref:read": ALL,
    "ref:write": {ADMIN, DIR, CHEF},
    "clients:transfer-zone": {ADMIN, DIR, CHEF},
    "clients:transfer-agence": {ADMIN, DIR},
    "consent:write": {ADMIN, DIR, CHEF, CAIS},
    "acces_client:manage": {ADMIN, DIR, CHEF},
    "kyc:validate": {ADMIN, DIR, CHEF},
    "lbc:read": {ADMIN, DIR, CHEF, COMPTA, AUD},
    "lbc:write": {ADMIN, DIR},
    "lbc:listes": {ADMIN, DIR},
    "users:manage": {ADMIN},
    "agences:write": {ADMIN},
    "params:read": {ADMIN, DIR, CHEF, COMPTA, AUD},
    "params:write": {ADMIN},
    "epargne:read": {ADMIN, DIR, CHEF, CAIS, AGENT, COLL, COMPTA, AUD},
    "epargne:write": {ADMIN, CHEF, CAIS},
    "adhesion:write": {ADMIN, CHEF, CAIS},
    "depot:debloquer": {ADMIN, CHEF},
    "collecte:read": {ADMIN, DIR, CHEF, CAIS, AGENT, COLL, AUD},
    "collecte:write": {ADMIN, CHEF, AGENT, COLL},
    "collecte:admin": {ADMIN, CHEF},
    "versement:write": {ADMIN, CHEF, CAIS},
    "retrait:request": {ADMIN, CHEF, CAIS, AGENT, COLL},
    "retrait:ecart": {ADMIN, DIR, CHEF},
    "retrait:execute": {ADMIN, CHEF, CAIS},
    "credit:read": {ADMIN, DIR, CHEF, CAIS, AGENT, COLL, COMPTA, AUD},
    "credit:request": {ADMIN, CHEF, AGENT, COLL},
    "credit:approve": {ADMIN, DIR, CHEF},
    "credit:disburse": {ADMIN, CHEF, CAIS},
    "credit:repay": {ADMIN, CHEF, CAIS},
    "caisse:read": {ADMIN, DIR, CHEF, CAIS, COMPTA, AUD},
    "caisse:write": {ADMIN, CHEF, CAIS},
    "tresorerie:read": {ADMIN, DIR, CHEF, CAIS, COMPTA, AUD},
    "tresorerie:write": {ADMIN, DIR, CHEF},
    "taches:run": {ADMIN, CHEF},
    "rapports:read": {ADMIN, DIR, CHEF, CAIS, COMPTA, AUD},
    "compta:read": {ADMIN, DIR, CHEF, COMPTA, AUD},
    "compta:write": {ADMIN, COMPTA},
    "etats:consolide": {ADMIN, DIR, COMPTA, AUD},
    "ratios:enregistrer": {ADMIN, DIR, COMPTA},
    "ratios:saisir": {ADMIN, DIR, COMPTA, CHEF},
    "ratios:parametrer": {ADMIN, DIR, COMPTA},
    "ratios:valider": {ADMIN, DIR, COMPTA},
    "provisions:read": {ADMIN, DIR, CHEF, COMPTA, AUD},
    "provisions:generer": {ADMIN, COMPTA},
    "rapprochement:valider": {ADMIN, COMPTA},
    "provisions:parametrer": {ADMIN, DIR, COMPTA},
    "rh:read": {ADMIN, DIR, RH, AUD},
    "rh:write": {ADMIN, RH},
    "audit:read": {ADMIN, DIR, AUD},
}

# rôles autorisés à n'avoir aucune agence (siège)
ROLES_SIEGE = {ADMIN, DIR, COMPTA, AUD}
