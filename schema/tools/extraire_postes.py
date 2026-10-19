"""Extrait du référentiel comptable des SFD de l'UMOA (annexe 1.1) la nomenclature des postes des états financiers
et leur concordance avec le plan de comptes, ainsi que les libellés des postes (annexes 2 et 3).

Usage : python extraire_postes.py "NOUVEAU REF SFD.pdf" ../19_postes_data.sql [../05_plan_comptable_data.sql]
Sortie : INSERT dans mf.poste_etat et mf.poste_compte. Les préfixes sans compte correspondant dans le plan sont
listés sur la sortie d'erreur (à relire à la main : le texte du PDF contient des espaces parasites)."""
import re
import sys

import pypdf

sys.stdout.reconfigure(encoding="utf-8")
pdf, sortie = sys.argv[1], sys.argv[2]
plan_sql = sys.argv[3] if len(sys.argv) > 3 else None

lecteur = pypdf.PdfReader(pdf)
# annexe 1.1 : pages 353 à 371 ; bilan développé (annexe 2.0) et compte de résultat (annexe 3) pour les libellés
pages_concordance = range(353, 372)
pages_libelles = range(381, len(lecteur.pages) + 1)

BRUIT = re.compile(r"^(ref compt sfd|Référentiel comptable|A\d{1,3}$|ANNEXES?\s*$|Codes postes|CLASSE\b|[A-ZÉÈ' ,\-]{12,}$|A C T I F|P A S S I F|"
                   r"LES CHARGES|LES PRODUITS|HORS BILAN|\d{0,2}$|[ANXE]$|ANNEXE)")


def normaliser(l: str) -> str:
    return l.replace("\xa0", " ").replace("–", "-").replace("—", "-").replace("’", "'").strip()


def lignes_concordance():
    for n in pages_concordance:
        for l in (lecteur.pages[n - 1].extract_text() or "").split("\n"):
            l = normaliser(l)
            if l and not BRUIT.match(l):
                yield l


CODE = re.compile(r"^([A-Z])\s?([0-9A-Z])\s?([0-9A-Z])(?![0-9A-Za-z])\s*(.*)$")
postes: dict[str, list[str]] = {}
courant = None
for l in lignes_concordance():
    m = CODE.match(l)
    # une ligne qui commence par un signe ou un chiffre est une suite d'expression
    if m and not re.match(r"^[+\-\d]", l) and not l.lower().startswith("ex"):
        courant = m.group(1) + m.group(2) + m.group(3)
        postes.setdefault(courant, [])
        if m.group(4):
            postes[courant].append(m.group(4))
    elif courant:
        postes[courant].append(l)


# préfixes connus du plan (si fourni) pour détecter les erreurs d'extraction
connus_plan: set[str] = set()
if plan_sql:
    for c in re.findall(r"\('(\d{1,7})'", open(plan_sql, encoding="utf-8").read()):
        connus_plan.add(c)


def existe(pref: str) -> bool:
    return any(c.startswith(pref) for c in connus_plan) if connus_plan else True


def decouper(expr: str):
    """Retourne [(signe, ex, prefixe)] d'une expression de concordance."""
    expr = re.sub(r"(PASSIF|ACTIF)", " ", expr)
    expr = expr.replace("(", " ").replace(")", " ")                          # groupes de formules : les signes sont indifférents (voir 19_etats_reglementaires.sql)
    expr = re.sub(r"(?<=\d)[A-Za-zÉÈ]+\b", " ", expr)                        # lettres parasites collées (ex. « 49973PASSIF »)
    expr = re.sub(r"(\d)\s*-\s*", r"\1 - ", expr)
    expr = re.sub(r"\s{2,}", " | ", expr)            # deux espaces ou plus : séparation de nombres sans signe
    sorties = []
    signe = 1
    for morceau in re.split(r"(?=[+\-])|\|", expr):
        morceau = morceau.strip()
        if not morceau:
            continue
        s = signe
        if morceau[0] in "+-":
            s = 1 if morceau[0] == "+" else -1
            morceau = morceau[1:].strip()
        ex = False
        if morceau.lower().startswith("ex"):
            ex = True
            morceau = morceau[2:].strip()
        chiffres = re.sub(r"\s+", "", morceau)
        if re.fullmatch(r"\d{1,7}", chiffres):
            sorties.append((s, ex, chiffres))
        elif re.fullmatch(r"\d{8,14}", chiffres):                     # deux nombres collés : on cherche la coupure qui donne deux comptes du plan
            for k in range(3, len(chiffres) - 2):
                if existe(chiffres[:k]) and existe(chiffres[k:]) and len(chiffres[:k]) <= 7 and len(chiffres[k:]) <= 7:
                    sorties.append((s, ex, chiffres[:k]))
                    sorties.append((s, ex, chiffres[k:]))
                    break
            else:
                sorties.append((s, ex, "?" + chiffres))
        elif chiffres:
            sorties.append((s, ex, "?" + chiffres))
    return sorties


concordance: dict[str, list[tuple[int, bool, str]]] = {}
for code, morceaux in postes.items():
    concordance[code] = decouper(" ".join(morceaux))

# libellés : on cherche, dans les annexes 2 et 3, un code connu suivi d'un texte jusqu'au prochain code connu
texte_libelles = " \n ".join(normaliser(l) for n in pages_libelles for l in (lecteur.pages[n - 1].extract_text() or "").split("\n"))
connus = sorted(concordance, key=len, reverse=True)
motif = re.compile(r"(?<![0-9A-Za-z.])(" + "|".join(re.escape(c) for c in connus) + r")\s+(?=[A-Za-zÉÈ])")
repere = list(motif.finditer(texte_libelles))
libelles: dict[str, str] = {}
for i, m in enumerate(repere):
    fin = repere[i + 1].start() if i + 1 < len(repere) else m.end() + 120
    lib = re.sub(r"\s+", " ", texte_libelles[m.end():fin]).strip(" -")
    lib = re.split(r"ANNEXES|Référentiel|ref compt", lib)[0].strip()
    if m.group(1) not in libelles and 3 < len(lib) < 140:
        libelles[m.group(1)] = lib

def cote(code: str) -> str:
    c = code[0]
    if c in "ABCDE":
        return "actif"
    if c in "FGHKL":
        return "passif"
    if c in "MNPQ":
        return "hors_bilan"
    if c in "RST":
        return "charge"
    if c in "UVWX":
        return "produit"
    return "autre"


def q(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def parent_existant(pref: str):
    while len(pref) > 2:
        pref = pref[:-1]
        if len(pref) >= 3 and existe(pref):
            return pref
    return None


suspects, replis = [], []
with open(sortie, "w", encoding="utf-8") as w:
    w.write("-- Généré par tools/extraire_postes.py à partir du référentiel comptable des SFD de l'UMOA (annexe 1.1).\n")
    w.write("-- Ne pas modifier à la main : relancer le script. Voir les contrôles dans tests/test_19_etats_reglementaires.sql.\n")
    w.write("SET search_path = mf, public;\n")
    for code in sorted(concordance):
        w.write(f"INSERT INTO poste_etat(code, cote, libelle) VALUES ({q(code)}, {q(cote(code))}, {q(libelles.get(code, code))});\n")
    for code in sorted(concordance):
        vus = set()
        for signe, ex, pref in concordance[code]:
            if pref.startswith("?"):
                suspects.append((code, pref))
                continue
            if not existe(pref):
                par = parent_existant(pref)
                if par is None:
                    suspects.append((code, pref))
                    continue
                replis.append((code, pref, par))
                pref = par
            if (pref, ex) in vus:
                continue
            vus.add((pref, ex))
            w.write(f"INSERT INTO poste_compte(poste_code, prefixe, signe, ex) VALUES ({q(code)}, {q(pref)}, {signe}, {str(ex).lower()});\n")
print(f"{len(concordance)} postes, {sum(len(v) for v in concordance.values())} lignes de concordance, {len(libelles)} libellés", file=sys.stderr)
print(f"{len(replis)} préfixes absents du plan rattachés au compte parent : " + ", ".join(f"{c}:{a}->{b}" for c, a, b in replis), file=sys.stderr)
print(f"{len(suspects)} préfixes écartés (absents du plan ou illisibles) :", file=sys.stderr)
for code, pref in suspects:
    print(f"  {code}: {pref}", file=sys.stderr)
