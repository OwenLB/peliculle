# PeliculleTests

Tests unitaires de la logique pure (batch H4) : `BurstGrouper`,
`SessionStore` (clés normalisées + récupération par contenu),
`LibraryScope`/`PhotoSource` (persistance), `TripMode.matches`,
`PhotoSort.areInOrder`, `AlbumDestination.resolvedTitle`.

Compatibles avec la règle projet « pas de debug simulateur » : la logique se
vérifie par `⌘U`, sans lancer l'app.

## Créer la cible (une fois, dans Xcode)

1. **File › New › Target… › Unit Testing Bundle**, produit `PeliculleTests`
   (framework **Swift Testing**, le défaut).
2. Xcode crée un dossier synchronisé `PeliculleTests/` à la racine — c'est
   **ce dossier** : il adopte les fichiers existants. Supprimer le fichier
   modèle `PeliculleTests.swift` généré s'il fait doublon.
3. Vérifier que la **Host Application** de la cible est `Peliculle`
   (nécessaire au `@testable import Peliculle`).

Ensuite `⌘U` exécute tout. Les tests `SessionStore` écrivent de vrais
fichiers de session dans l'Application Support du hôte de test puis les
suppriment (suite sérialisée).
