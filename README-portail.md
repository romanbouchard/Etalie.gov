# Brancher le portail citoyen à Supabase

## 1. Ce que tu m'as donné vs ce qu'il faut

Les clés **S3 / Storage** que tu as collées (`Access key`, endpoint `storage.supabase.co/storage/v1/s3`)
servent à connecter un client compatible S3 à ton **bucket de stockage de fichiers**. Ce n'est **pas**
ce qu'il faut pour connecter un site web à ta base de données/authentification. Ne les utilise pas ici
(et évite de les partager dans un chat si tu peux — même si dans ton cas seul le Key ID a été montré,
pas le secret).

Ce qu'il faut réellement, dans le tableau de bord Supabase → **Project Settings → API** :

| Trouvé dans Supabase | À coller dans `portail-citoyen.html` |
|---|---|
| **Project URL** (ex: `https://xxxxx.supabase.co`) | `SUPABASE_URL` |
| **anon public** (sous "Project API keys") | `SUPABASE_ANON_KEY` |

Ouvre `portail-citoyen.html`, tout en haut du `<script>` final, et remplace :
```js
const SUPABASE_URL = "METS_TON_PROJECT_URL_ICI";
const SUPABASE_ANON_KEY = "METS_TA_CLE_ANON_PUBLIC_ICI";
```
La clé `anon public` est **faite pour être publique** (elle est protégée par les RLS policies du
schéma SQL) — contrairement à la `service_role` que tu ne dois **jamais** mettre dans le site.

## 2. Réglages à activer dans Supabase

**Authentication → Providers → Email** :
- Laisse "Email" activé.
- Dans **Authentication → Settings**, désactive *"Confirm email"* si tu veux que l'inscription
  connecte l'utilisateur immédiatement (sinon il devra cliquer un lien de confirmation avant de
  pouvoir se connecter — la page gère les deux cas, mais l'expérience est plus fluide sans confirmation
  pour un site de jeu de rôle).

**Database → Extensions** : assure-toi que `pgcrypto` est activée (nécessaire pour `gen_random_uuid()` —
elle l'est par défaut sur les nouveaux projets).

## 3. Exécuter le schéma

1. Ouvre **Database → SQL Editor**.
2. Colle tout le contenu de `schema-portail-citoyen-v2.sql` et exécute (il supprime proprement l'ancienne
   v1 si tu l'avais déjà lancée, donc c'est sûr de le relancer).

## 4. Charger les vrais codes CAS

1. Sur ta machine (jamais publié en ligne), lance :
   ```bash
   python3 parse_cas.py assets/donnees/CAS/num_CAS.txt > inserts_cas.sql
   ```
2. Ouvre `inserts_cas.sql`, vérifie l'aperçu en commentaire en haut (ça te montre chaque CAS déchiffré
   pour validation humaine), puis colle le bloc `insert into cas_valides (...) values (...)` dans le
   SQL Editor de Supabase et exécute.
3. Le compte `ADMIN` (CAS `Q-Q-Q/Q-Q-Q/Q-Q-Q`) obtient automatiquement `est_admin = true` grâce au script.

## 5. Realtime

Le script active déjà `citoyens` et `messages` sur la publication `supabase_realtime`. Si jamais ça
échoue au premier lancement (le nom de la publication peut différer selon l'âge du projet), va dans
**Database → Replication** et active manuellement les deux tables.

## 6. Tester

1. Ouvre `portail-citoyen.html` dans un navigateur (ou héberge le site sur GitHub Pages).
2. Inscris-toi avec le CAS de test `982-391-743` (Frederic Cong) une fois que tu l'auras chargé dans
   `cas_valides`, ou avec le CAS `ADMIN` pour tester le panneau d'administration.
3. Vérifie que la trésorerie augmente à l'écran chaque seconde, et que `citoyens.tresorerie` se met à
   jour dans Supabase après ~5 minutes (ou change une valeur manuellement dans Supabase pour vérifier
   que le temps réel rafraîchit l'écran instantanément).

## 7. Ce qui reste ouvert / à ton choix

- **Âge de majorité** : la formule garde ta décision (×12,1666667, donc ~1 an 7 mois réels suffisent).
  Le seuil se change en une ligne dans `age_toutouien()` si tu changes d'avis plus tard.
- **Renouvellement du CAS** : la page affiche le message d'expiration et bloque la connexion, mais il
  n'y a pas encore d'interface pour qu'un employé du gouvernement mette à jour une date d'expiration
  depuis le site (pour l'instant ça se fait directement dans Supabase, table `cas_valides`, colonne
  `date_expiration`). Dis-moi si tu veux un outil pour ça dans le panneau admin.
- **Filtre anti-émoji** : la fonction `contient_emoji()` couvre les blocs Unicode les plus courants,
  pas 100% des émojis possibles.
