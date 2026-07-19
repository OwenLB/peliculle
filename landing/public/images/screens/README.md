# Captures d'écran de l'app

Les visuels « app » de la landing sont de **vraies captures**, en paire
clair/sombre — le composant `src/components/AppShot.astro` affiche la version
correspondant au thème de la page (crossfade au basculement du toggle).

- `clair/` et `sombre/` : mêmes noms de fichiers dans les deux dossiers.
- Emplacements : `Hero.astro` (visionneuse-tri), `HowItWorks.astro`
  (grille, swipe-garder, passe-terminee), `Features.astro` (filtres-section,
  swipe-garder, comparaison).
- La barre de statut iOS est reconstruite en CSS au-dessus des captures
  (`PhoneStatusBar.astro`, prop `bar` d'`AppShot`) — heure « 9:41 »,
  Dynamic Island, batterie propres et identiques partout.

## Préparation d'une capture

Source : `../../../../screenshots/{clair,sombre}/` (exports iPhone bruts,
1179 × 2556). Conversion avec sharp (dispo dans `node_modules`) :

- rogner la barre de statut iOS : 177 px en haut (59 pt @3x) — sauf pour les
  écrans plein écran sans barre de statut (ex. la comparaison) ;
- redimensionner à 800 px de large, exporter en WebP qualité 82.

Les cadres iPhone autour des captures restent en CSS (voir `.hero-phone`,
`.how-phone`, `.bento-shot-frame`) : nets à toutes les résolutions, et le
ratio `9 / 17.7` correspond à la capture rognée.

Les photos des mini-démos encore reconstruites (SwipeShowcase, bento) vivent
dans `public/images/swipe/`.
