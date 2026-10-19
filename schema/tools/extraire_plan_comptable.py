import re,sys,csv
from collections import Counter
sys.stdout.reconfigure(encoding='utf-8')
src,out=sys.argv[1],sys.argv[2]
txt=open(src,encoding='utf-8').read()
parts=re.split(r'\n=== PAGE (\d+) ===\n',txt)
def despace(s):
    toks=s.split(' ')
    ne=[t for t in toks if t]
    if len(ne)>=6 and sum(len(t)==1 for t in ne)/len(ne)>0.6:   # ligne à lettres espacées
        return re.sub(r' {2,}','\x00',s).replace(' ','').replace('\x00',' ')
    return s
lines=[]
for i in range(1,len(parts),2):
    if 63<=int(parts[i])<=100:
        for ln in parts[i+1].split('\n'):
            ln=ln.replace(' ',' ').replace('–','-').replace('—','-')
            ln=despace(ln)
            ln=re.sub(r'(?<=[^\d\s])\s(?=\d{3,7}\s?-\s)','\n',ln)
            lines+=ln.split('\n')
skip=re.compile(r'^(ref compt sfd|Référentiel comptable spécifique|PLAN DE COMPTES\s*$|\d{1,3}\s*$)')
code_re=re.compile(r'^(\d(?:[\d ]*\d)?)\s*-\s*(\S.*)$')
rows=[]; classe=None; titre=False
for ln in lines:
    s=ln.strip()
    if not s or skip.match(s): continue
    m=re.match(r'^CLASSE\s+(\d)\s*$',s)
    if m: classe=m.group(1); titre=True; continue
    m=code_re.match(s)
    if m:
        code=m.group(1).replace(' ','')
        if 2<=len(code)<=7 and code[0]==classe:
            rows.append([code,m.group(2).strip(),classe]); titre=False; continue
    if titre: titre=False; continue
    if rows: rows[-1][1]+=' '+s
fix=[(r'D épôts','Dépôts'),(r'term e','terme'),(r'm ois','mois'),(r'Im m obilisations','Immobilisations'),
     (r'im m obilisations','immobilisations'),(r'Com pt','Compt'),(r'com pt','compt'),(r'logem ent','logement'),
     (r'Com m issions','Commissions'),(r'com m issions','commissions'),(r'som m es','sommes'),(r'régim e','régime'),
     (r'Bâtim ents','Bâtiments'),(r'agencem ents','agencements'),(r'M atériel','Matériel'),(r'\s+',' ')]
for r in rows:
    for a,b in fix: r[1]=re.sub(a,b,r[1])
    r[1]=r[1].strip()
codes=Counter(r[0] for r in rows)
dup=[c for c,n in codes.items() if n>1]
S=set(codes)
orph=[r[0] for r in rows if len(r[0])>2 and r[0][:-1] not in S]
# libellés suspects : contiennent un autre code, ou très longs
susp=[r for r in rows if re.search(r' \d{3,7} ?- ',r[1]) or len(r[1])>150]
print(len(rows),'comptes',dict(sorted(Counter(r[2] for r in rows).items())))
print('doublons:',len(dup),dup[:10]); print('orphelins (parent absent):',len(orph),orph[:25]); print('suspects:',len(susp))
for r in susp[:10]: print('  ',r[0],r[1][:100])
with open(out,'w',encoding='utf-8',newline='') as f:
    w=csv.writer(f,delimiter=';'); w.writerow(['code','libelle','classe']); w.writerows(rows)
