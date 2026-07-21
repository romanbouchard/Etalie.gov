# Site officiel du gouvernement d'Étalie

Site statique en HTML/CSS pur, prêt à héberger sur GitHub Pages.
Refonte complète de l'ancien site (Quénada) : nouveau nom, nouveau drapeau,
nouvelle palette institutionnelle, et contenu réel migré depuis l'ancien site.

## Structure

```
index.html            → page d'accueil
gouvernement.html      → le Roi, les sous-rois et l'organigramme
actualites.html        → communiqués officiels (élections, INSPEQ, LLDE...)
documents.html          → textes de loi officiels (PDF téléchargeables)
histoire.html           → récit historique complet d'Étalie
provinces.html          → 37 provinces et 38 municipalités (données réelles, filtrables)
taxes.html               → régime fiscal complet
portail-citoyen.html   → espace citoyen (identification, chèques, prêts, messages)
voyage.html             → avis de sécurité INSPEQ (Étalie, Yhorule, Dimensionworld)
vote.html                → calendrier des élections
connexion.html          → accès réservé aux fonctionnaires (en migration)
contact.html            → coordonnées (à compléter)
css/styles.css          → feuille de style unique, partagée par toutes les pages
assets/                 → drapeau, blason, photos des dirigeants, PDF officiels
```

## Palette

Calibrée sur les couleurs exactes extraites du drapeau fourni : vert (#009246),
blanc, rouge (#CE2B37), or (#F7C702) et pourpre du blason (#742974).

## Publier sur GitHub Pages

1. Crée un dépôt sur GitHub (ex. `etalie-gouvernement`).
2. Ajoute tous les fichiers de ce dossier à la racine du dépôt (garde `css/` et `assets/`).
3. Pousse le tout :
   ```bash
   git init
   git add .
   git commit -m "Site officiel du gouvernement d'Étalie"
   git branch -M main
   git remote add origin https://github.com/TON-NOM-UTILISATEUR/etalie-gouvernement.git
   git push -u origin main
   ```
4. Dans le dépôt GitHub : **Settings → Pages → Source**, choisis la branche `main` et le dossier `/ (root)`.
5. Ton site sera en ligne à `https://TON-NOM-UTILISATEUR.github.io/etalie-gouvernement/`.

## Reste à faire

- **Portrait du Roi** manquant (roman.png n'était pas dans l'archive) — la fiche gouvernement affiche un espace réservé.
- **Documents PDF** (LLDE, INSPEQ) : ce sont encore les fichiers originaux, leur contenu interne mentionne encore l'ancien nom du pays — une réédition sous le nom d'Étalie reste à faire.
- **Protectorats d'Éton et de Chagne** : simple mention sur l'accueil pour l'instant, aucune fiche détaillée (aucune information fournie à ce jour).
- **connexion.html / contact.html** : pages d'attente, contenu à définir.
- **vote.html** : calendrier statique ; le système de scrutin protégé par mot de passe de l'ancien site n'a pas été reconstruit.
