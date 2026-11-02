"""Matrice des permissions : permission -> rôles autorisés.

L'auditeur est en lecture seule partout où la lecture existe. Le cloisonnement par agence est appliqué
séparément (voir auth.agence_scope) : seuls admin, directeur, comptable et auditeur peuvent être au siège
et voir plusieurs agences.
"""
ADMIN, DIR, CHEF, CAIS, COMPTA, AGENT, COLL, RH, AUD, COORD = (
    "admin", "directeur", "chef_agence", "caissier", "comptable", "agent", "collectrice", "rh", "auditeur", "coordinateur",
)
ALL = {ADMIN, DIR, CHEF, CAIS, COMPTA, AGENT, COLL, RH, AUD, COORD}

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
    "journee:admin": {ADMIN},   # ouverture et clôture de la date d'opération : institution entière, pas une seule agence
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
    "collecte:valider": {ADMIN, CHEF, CAIS},     # valide ou rejette les synchronisations de l'application mobile
    "cycle:prolongation-decider": {ADMIN, DIR, CHEF},
    "livret:controler": {ADMIN, DIR, CHEF, COORD},
    "livret:read": {ADMIN, DIR, CHEF, COORD, AUD},
    "livret:valider": {ADMIN, DIR, CHEF},
    "carnet:read": {ADMIN, DIR, CHEF, CAIS, COORD, AUD},
    "carnet:write": {ADMIN, DIR, CHEF},
    "paiement-mobile:read": {ADMIN, DIR, CHEF, CAIS, COMPTA, COORD, AUD},
    "paiement-mobile:rembourser": {ADMIN, CHEF, COMPTA},
    "demande-retrait:decider": {ADMIN, DIR, CHEF, CAIS},
    "operation:read": {ADMIN, DIR, CHEF, CAIS, COMPTA, AUD, COORD},
    "operation:param": {ADMIN, DIR, COMPTA},
    "operation:comptes-valider": {ADMIN, COMPTA},
    "operation:saisir": {ADMIN, CHEF, CAIS, COMPTA},
    "operation:valider": {ADMIN, DIR, CHEF},
    "charge:gerer": {ADMIN, DIR, CHEF, COMPTA},
    "budget:gerer": {ADMIN, DIR, CHEF, COMPTA},
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
    # sécurité des comptes et des données
    "securite:read": {ADMIN, DIR, AUD},
    "securite:write": {ADMIN},
    "securite:alertes": {ADMIN, DIR, AUD},
    "totp:reinitialiser": {ADMIN, DIR},
    "sauvegarde:write": {ADMIN},
    "sauvegarde:tester": {AUD, DIR},
    # réseaux d'agences
    "reseaux:read": {ADMIN, DIR, AUD, COORD},
    "reseaux:write": {ADMIN},
    # comité de gestion du crédit
    "comite:read": ALL,
    "comite:manage": {ADMIN, DIR, CHEF, COORD},
    "comite:participer": ALL,
    "delegation:write": {ADMIN, DIR, COORD},
    # recouvrement, procurations, chèques, comptes dormants
    "recouvrement:read": {ADMIN, DIR, CHEF, AGENT, COLL, COMPTA, AUD},
    "recouvrement:write": {ADMIN, CHEF, AGENT, COLL},
    "recouvrement:perte": {ADMIN, DIR},
    "procuration:write": {ADMIN, CHEF, CAIS},
    "procuration:valider": {ADMIN, CHEF},
    "cheque:read": {ADMIN, DIR, CHEF, COMPTA, AUD},
    "cheque:prepare": {ADMIN, CHEF, COMPTA, CAIS},
    "cheque:sign": {ADMIN, DIR, COMPTA},
    "epargne:dormant": {ADMIN, CHEF},
    # gestion des ressources humaines
    "grh:read": {ADMIN, DIR, CHEF, RH, AUD},
    "grh:write": {ADMIN, DIR, RH},
    "conge:decider": {ADMIN, DIR, CHEF, RH},
    "recrutement:decider": {ADMIN, DIR},
    "sanction:write": {ADMIN, DIR, CHEF, RH},
    "evaluation:ecrire": {ADMIN, DIR, CHEF, RH},
    "evaluation:valider": {ADMIN, DIR, RH},
    "sortie:write": {ADMIN, DIR, RH},
    "grh:self": ALL,
    # gestion des rôles et des affectations (module 53)
    "roles:gerer": {ADMIN},
    "roles:demander": {ADMIN, DIR, CHEF},
    "roles:valider": {ADMIN, DIR},
    # immobilisations et maintenance (module 52)
    "immobilisation:read": {ADMIN, DIR, CHEF, COMPTA, AUD, COORD},
    "immobilisation:gerer": {ADMIN, DIR, CHEF, COMPTA},
    "maintenance:signaler": {ADMIN, DIR, CHEF, CAIS, COMPTA, COORD},
    "maintenance:gerer": {ADMIN, DIR, CHEF, COMPTA},
    # stock des fournitures (module 57) ; la décision sur une demande vient toujours d'une autre personne que le demandeur
    "stock:read": {ADMIN, DIR, CHEF, CAIS, COMPTA, AUD},
    "stock:gerer": {ADMIN, DIR, CHEF},
    "stock:mouvoir": {ADMIN, DIR, CHEF, CAIS, COMPTA},
    "stock:valider": {ADMIN, DIR, CHEF, COMPTA},
    "appareil:read": {ADMIN, DIR, CHEF, AUD, COORD},
    "appareil:gerer": {ADMIN, DIR, CHEF, COORD},
}

# Le coordinateur de réseau a les droits du directeur, dans son réseau seulement (le cloisonnement vient du périmètre).
# Exceptions : ce qui relève de l'institution entière.
_SIEGE_SEUL = {"etats:consolide", "ratios:enregistrer", "ratios:saisir", "ratios:parametrer", "ratios:valider",
               "lbc:write", "lbc:listes", "params:write", "clients:transfer-agence", "provisions:parametrer", "audit:read",
               "securite:read", "securite:write", "securite:alertes", "totp:reinitialiser", "sauvegarde:write", "sauvegarde:tester", "cheque:sign", "cheque:read"}
for _perm, _roles in PERMS.items():
    if DIR in _roles and COORD not in _roles and _perm not in _SIEGE_SEUL:
        _roles.add(COORD)

# rôles autorisés à n'avoir aucune agence (siège)
ROLES_SIEGE = {ADMIN, DIR, COMPTA, AUD}
