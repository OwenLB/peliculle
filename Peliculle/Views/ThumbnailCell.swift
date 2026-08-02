import SwiftUI

/// Une cellule carrée de la grille (F2). Skeleton pendant le chargement,
/// badges de décision et de note (F10), coche de sélection façon Photos.app
/// en mode sélection. Les photos rejetées sont estompées pour balayer la
/// grille d'un coup d'œil. Le chargement est paresseux et annulé
/// automatiquement quand la cellule quitte l'écran.
///
/// Répartition des coins, pour que deux badges ne se disputent jamais la même
/// place :
/// - **haut-droite** : décision de tri + note, sur une ligne — la décision
///   reste collée à l'angle (repère qu'on balaie du regard en triant), la
///   note s'insère à sa gauche quand il y en a une ;
/// - **bas-gauche** : orientation portrait/paysage (togglable, voir
///   `showOrientation`), photo comme vidéo ; la **durée** s'y ajoute pour une
///   vidéo, à côté de l'orientation, pas à sa place ;
/// - **bas-droite** : « déjà dans la pellicule » + « dans l'album », sur une
///   ligne ; la coche de sélection s'**empile en dessous** en mode sélection,
///   elle ne remplace plus rien.
///
/// Le coin haut-**gauche** est laissé libre : `GridView` y pose le badge ≈ des
/// similaires par-dessus la cellule — il porte une action, il doit donc rester
/// hors du bouton qui ouvre le viewer, et ne peut pas être posé d'ici.
struct ThumbnailCell: View {
    let item: PhotoItem
    var isSelecting = false
    var isSelected = false
    /// Réglage « Afficher l'orientation » (menu Affichage) : masque le badge
    /// bas-gauche d'une photo à la demande. Sans effet sur une vidéo, dont le
    /// coin affiche la durée, pas l'orientation.
    var showOrientation = true

    @State private var image: UIImage?

    private let targetPixels = 400

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .overlay { ProgressView().controlSize(.small) }
                }
            }
            .overlay {
                if item.decision == .reject {
                    Color.black.opacity(0.45)
                }
                if isSelected {
                    Color.white.opacity(0.2)
                }
            }
            .overlay(alignment: .topTrailing) { statusBadges }
            .overlay(alignment: .bottomLeading) { infoBadges }
            .overlay(alignment: .bottomTrailing) { saveBadges }
            .clipped()
            // `.clipped()` coupe le rendu mais pas le hit-testing : l'image
            // `scaledToFill` d'une cellule déborderait sur ses voisines et
            // volerait leurs taps (photo de droite ouverte à la place).
            .contentShape(.rect)
            .task(id: item.id) {
                image = await ThumbnailLoader.load(item: item, maxPixel: targetPixels)
                // Idée 18 — une vidéo n'a ni EXIF image ni signaux Vision :
                // seule sa durée est chargée (paresseusement, comme le reste).
                if item.isVideo {
                    if item.videoDuration == nil {
                        item.videoDuration = await VideoInfo.duration(of: item.backing)
                    }
                    // Orientation du clip (badge bas-gauche, partagé avec la
                    // durée) : `PhotoItem.orientation` la dérive de ce ratio,
                    // même règle que pour une photo.
                    if item.videoAspect == nil {
                        item.videoAspect = await VideoInfo.aspectRatio(of: item.backing)
                    }
                    return
                }
                // Index EXIF (Jalon 8) paresseux : à l'apparition de la
                // cellule (date/orientation/boîtier pour tri et filtres),
                // jamais en balayage au scan. Annulé avec le `.task` quand la
                // cellule quitte l'écran. L'**analyse Vision** (esthétique)
                // n'est plus chargée ici : plus aucun badge de cellule ne la
                // lit — elle se calcule à la demande dans la fiche EXIF et par
                // la passe de session du tri esthétique (`GridView`).
                if item.exif == nil {
                    item.exif = await ExifIndexer.shared.exif(for: item.backing)
                }
            }
    }

    // Badges partagés avec le viewer (voir `StatusBadges.swift`).

    /// Statuts du coin haut-droit, sur **une seule ligne** : la note puis la
    /// décision de tri. La décision reste collée à l'angle et ne bouge donc
    /// jamais — c'est le badge qu'on balaie du regard en triant ; la note
    /// s'insère à sa gauche quand il y en a une.
    ///
    /// La **référence** (gagnante d'un tournoi) n'a volontairement pas de
    /// badge ici : la couronne appartient au tournoi et à son récap, où elle
    /// dit qui a gagné le duel qu'on vient de juger. Sortie de ce contexte,
    /// elle devenait une distinction permanente sur la grille sans rien
    /// ajouter au tri. Une référence y lit donc comme ce qu'elle est aussi :
    /// une photo gardée (`isReference` reste porté par le modèle).
    private var statusBadges: some View {
        HStack(spacing: 4) {
            RatingBadge(rating: item.rating)
            DecisionBadge(decision: item.decision, font: .title3)
        }
        .padding(5)
    }

    /// Repère du coin bas-gauche : orientation (photo **ou** vidéo, togglable)
    /// puis durée pour une vidéo — les deux ensemble sur un clip, orientation
    /// seule sur une photo.
    private var infoBadges: some View {
        HStack(spacing: 4) {
            if showOrientation {
                orientationBadge
            }
            if item.isVideo {
                videoDurationBadge
            }
        }
        .padding(5)
    }

    /// Orientation portrait / paysage. Nécessaire parce que les cellules sont
    /// **carrées** et l'aperçu rogné (`scaledToFill`) : le format d'origine
    /// est invisible sur la vignette, contrairement au viewer. Mêmes glyphes
    /// que le filtre d'orientation, pour qu'on relie le repère au filtre.
    ///
    /// Rien tant que la source n'est pas connue — EXIF pour une photo,
    /// `videoAspect` pour un clip, les deux arrivent avec le `.task` de la
    /// cellule, le badge apparaît donc juste après la vignette.
    @ViewBuilder
    private var orientationBadge: some View {
        if let orientation = item.orientation {
            Image(systemName: orientation.icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                // Même capsule sombre que la durée vidéo : lisible sur
                // n'importe quelle photo, sans peser comme un statut de tri.
                .background(.black.opacity(0.45), in: .capsule)
                .accessibilityLabel(Text(orientation.label))
        }
    }

    /// Idée 18 — durée d'un clip, façon Photos.app (▶︎ + durée), déplacée ici
    /// (bas-gauche, avec l'orientation) pour laisser le bas-droit aux badges
    /// de sauvegarde.
    @ViewBuilder
    private var videoDurationBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
            if let duration = item.videoDuration {
                Text(VideoInfo.formattedDuration(duration))
            }
        }
        .font(.caption2.weight(.bold).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(.black.opacity(0.45), in: .capsule)
        .accessibilityLabel(Text("Vidéo"))
    }

    /// Coin bas-droit : « déjà dans la pellicule » + « dans l'album », puis la
    /// coche de sélection **empilée dessous** en mode sélection — elle ne
    /// remplace plus rien, les deux informations restent lisibles en même
    /// temps qu'on sélectionne.
    private var saveBadges: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                if item.savedToLibrary || item.isLibraryBacked {
                    SavedBadge(font: .title3, native: item.isLibraryBacked)
                }
                if item.inDestinationAlbum {
                    AlbumBadge(font: .title3)
                }
            }
            if isSelecting {
                selectionBadge
            }
        }
        .padding(5)
    }

    /// Coche de sélection façon Photos.app (visible uniquement en mode sélection).
    private var selectionBadge: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(
                isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.8)),
                isSelected ? AnyShapeStyle(.blue) : AnyShapeStyle(.black.opacity(0.2))
            )
            .shadow(radius: 2)
    }
}
