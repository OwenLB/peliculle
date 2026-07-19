# Landing page — Peliculle

Landing page marketing de l'app, développée en [Astro](https://astro.build),
indépendante du projet iOS (aucune dépendance croisée).

- **Bilingue** : `/` (français) et `/en/` (anglais) — dictionnaires dans
  `src/i18n/ui.ts`, hreflang + sitemap générés.
- **Visuel hero** : carte SD en verre pré-rendue (`public/images/sd-card.webp`,
  ~8 Ko, flottement CSS) — remplace l'ancienne scène Three.js (~525 Ko de JS).
- **Animations** : GSAP + ScrollTrigger (`src/scripts/animations.js`) —
  intro du hero, révélations au scroll, démo « Tri rapide », wordmark animé.
- **SEO** : meta/OG/hreflang dans `src/layouts/Base.astro`, JSON-LD
  (SoftwareApplication + FAQPage), `robots.txt`, sitemap, image OG
  (`public/og-image.png`), favicons + webmanifest.
- **Waitlist & audience** : Supabase — tables `peliculle_waitlist` (emails,
  uniques par adresse, insensible à la casse) et `peliculle_pageviews`
  (pages vues, sans cookie). Les deux sont en **insertion anonyme seule**
  (RLS), aucune lecture publique ; URL + clé publishable dans `src/config.ts`.
  Export des emails : dashboard Supabase → Table editor → `peliculle_waitlist`.

## Commandes

```bash
cd landing
npm install
npm run dev       # http://localhost:4321
npm run build     # build de production dans dist/
npm run preview   # prévisualisation du build
```

## À brancher avant le lancement

| Quoi | Où |
|---|---|
| **Captures d'écran** | `public/images/screens/` — voir le README de ce dossier (le plus gros manque actuel : montrer l'app et de vraies photos) |
| **Lien App Store** | remplacer le badge placeholder (`src/components/AppStoreBadge.astro`) par le badge officiel + lien |
| **Domaine** | `astro.config.mjs` (`site`) si différent de `peliculle.com` |

## Branding

Voir [`../BRANDING.md`](../BRANDING.md) : le wordmark **Pelicull(e)** est
réservé au visuel (hero, footer, étiquette 3D) ; la graphie simple
**Peliculle** apparaît dans les titres, meta et textes courants (SEO/ASO).
