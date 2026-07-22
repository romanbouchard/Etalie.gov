"""
Décodeur/convertisseur pour assets/donnees/CAS/num_CAS.txt
Usage : python3 parse_cas.py num_CAS.txt > inserts_cas.sql
Format d'une ligne :
[CAS encrypté]$$$[NOM]###[PRENOM]@@@[chiffre]&&&[jour]*[mois]?[annee]=[O/N]
"""
import sys, re

TABLE_INV = {'Q':'1','E':'2','Z':'3','V':'4','X':'5','T':'6','H':'7','N':'8','B':'9','K':'0'}

def decoder_cas(code_encrypte):
    """Reconvertit un CAS encrypté en chiffres, pour vérification humaine seulement."""
    groupes = code_encrypte.split('/')
    parties = []
    for g in groupes:
        lettres = g.split('-')
        parties.append(''.join(TABLE_INV.get(l, '?') for l in lettres))
    return ' '.join(parties)

def parser_ligne(ligne):
    ligne = ligne.strip()
    if not ligne:
        return None
    m = re.match(r'^(.*?)\$\$\$(.*?)###(.*?)@@@(\d+)&&&(\d{1,2})\*(\d{1,2})\?(\d{4})=(O|N)$', ligne)
    if not m:
        raise ValueError(f"Ligne invalide, format non reconnu : {ligne}")
    code_encrypte, nom, prenom, chiffre, jour, mois, annee, gouv = m.groups()
    return {
        'code_encrypte': code_encrypte,
        'nom': nom.strip().upper(),
        'prenom': prenom.strip().upper(),
        'chiffre': int(chiffre),
        'date_expiration': f"{annee}-{int(mois):02d}-{int(jour):02d}",
        'gouvernement': gouv == 'O',
        'cas_clair': decoder_cas(code_encrypte),
    }

def sql_escape(s):
    return s.replace("'", "''")

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 parse_cas.py num_CAS.txt", file=sys.stderr)
        sys.exit(1)
    lignes = open(sys.argv[1], encoding='utf-8').read().splitlines()
    valeurs = []
    apercu = []
    for i, ligne in enumerate(lignes, 1):
        try:
            d = parser_ligne(ligne)
        except ValueError as e:
            print(f"-- IGNORÉ (ligne {i}): {e}", file=sys.stderr)
            continue
        if d is None:
            continue
        est_admin = (d['nom'] == 'ADMIN' and d['prenom'] == 'ADMIN')
        valeurs.append(
            f"  ('{sql_escape(d['code_encrypte'])}', '{sql_escape(d['nom'])}', "
            f"'{sql_escape(d['prenom'])}', {d['chiffre']}, '{d['date_expiration']}', "
            f"{'true' if d['gouvernement'] else 'false'}, {'true' if est_admin else 'false'})"
        )
        apercu.append(f"-- {d['prenom']} {d['nom']} ({d['chiffre']}) — CAS {d['cas_clair']} — expire {d['date_expiration']} — gouv={d['gouvernement']}")

    print("-- Généré automatiquement par parse_cas.py — NE PAS committer publiquement")
    print("-- (le fichier num_CAS.txt source contient des CAS réels encryptés)")
    print()
    print("\n".join(apercu))
    print()
    print("insert into cas_valides")
    print("  (code_encrypte, nom_legal, prenom_legal, chiffre_identification, date_expiration, protection_gouvernementale, est_admin)")
    print("values")
    print(",\n".join(valeurs))
    print("on conflict (code_encrypte) do nothing;")

if __name__ == '__main__':
    main()
