import SwiftUI

/// Une cellule carrée de la grille (F2). Skeleton pendant le chargement,
/// badge de décision (F5) en surimpression, badges d'orientation et de note
/// (F10), coche de sélection façon Photos.app en mode sélection. Les photos
/// rejetées sont estompées pour balayer la grille d'un coup d'œil. Le
/// chargement est paresseux et annulé automatiquement quand la cellule quitte
/// l'écran.
///
/// Répartition des coins, pour que deux badges ne se disputent jamais la même
/// place : décision + « déjà enregistrée » en haut à droite (sur une ligne),
/// orientation + note en bas à gauche (idem), vidéo/sélection en bas à droite.
/// Le coin haut-**gauche** est laissé libre : `GridView` y pose le badge ≈ des
/// similaires par-dessus la cellule — il porte une action, il doit donc rester
/// hors du bouton qui ouvre le viewer, et ne peut pas être posé d'ici.
struct ThumbnailCell: View {
    let item: PhotoItem
    var isSelecting = false
    var isSelected = false

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
            .overlay(alignment: .bottomTrailing) { selectionBadge }
            .overlay(alignment: .bottomTrailing) { videoBadge }
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

    /// Statuts du coin haut-droit, sur **une seule ligne** : « déjà
    /// enregistrée » puis la décision de tri. La décision reste collée à
    /// l'angle et ne bouge donc jamais — c'est le badge qu'on balaie du regard
    /// en triant ; l'autre s'insère à sa gauche quand il a lieu d'être.
    ///
    /// « Déjà enregistrée » vivait en haut à **gauche**, où `GridView` pose
    /// aussi le badge ≈ des similaires : les deux se recouvraient dès qu'une
    /// photo était à la fois enregistrée et dans un lot.
    ///
    /// La **référence** (gagnante d'un tournoi) n'a volontairement pas de
    /// badge ici : la couronne appartient au tournoi et à son récap, où elle
    /// dit qui a gagné le duel qu'on vient de juger. Sortie de ce contexte,
    /// elle devenait une distinction permanente sur la grille sans rien
    /// ajouter au tri. Une référence y lit donc comme ce qu'elle est aussi :
    /// une photo gardée (`isReference` reste porté par le modèle).
    private var statusBadges: some View {
        HStack(spacing: 4) {
            if item.savedToLibrary {
                SavedBadge(font: .title3)
            }
            DecisionBadge(decision: item.decision, font: .title3)
        }
        .padding(5)
    }

    /// Repères de lecture du coin bas-gauche, sur **une seule ligne** : ils
    /// partagent le coin, ils ne doivent donc jamais se recouvrir. Chacun
    /// s'efface quand il n'a rien à dire (photo non notée, orientation pas
    /// encore connue), et l'`HStack` se referme sur ce qui reste.
    private var infoBadges: some View {
        HStack(spacing: 4) {
            orientationBadge
            RatingBadge(rating: item.rating)
        }
        .padding(5)
    }

    /// Orientation portrait / paysage. Nécessaire parce que les cellules sont
    /// **carrées** et l'aperçu rogné (`scaledToFill`) : le format d'origine
    /// est invisible sur la vignette, contrairement au viewer. Mêmes glyphes
    /// que le filtre d'orientation, pour qu'on relie le repère au filtre.
    ///
    /// Rien tant que l'EXIF n'est pas indexé — il arrive avec le `.task` de la
    /// cellule, le badge apparaît donc juste après la vignette. Rien non plus
    /// sur une vidéo : pas d'EXIF image (son format vit dans `videoAspect`,
    /// que seul le viewer charge).
    @ViewBuilder
    private var orientationBadge: some View {
        if !item.isVideo, let orientation = item.orientation {
            Image(systemName: orientation.icon)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                // Même capsule sombre que le badge vidéo : lisible sur
                // n'importe quelle photo, sans peser comme un statut de tri.
                .background(.black.opacity(0.45), in: .capsule)
                .accessibilityLabel(Text(orientation.label))
        }
    }

    /// Idée 18 — badge vidéo façon Photos.app (▶︎ + durée). Cède la place à
    /// la coche en mode sélection (même coin).
    @ViewBuilder
    private var videoBadge: some View {
        if item.isVideo, !isSelecting {
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
            .padding(5)
            .accessibilityLabel(Text("Vidéo"))
        }
    }

    /// Coche de sélection façon Photos.app (visible uniquement en mode sélection).
    @ViewBuilder
    private var selectionBadge: some View {
        if isSelecting {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(
                    isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.8)),
                    isSelected ? AnyShapeStyle(.blue) : AnyShapeStyle(.black.opacity(0.2))
                )
                .padding(5)
                .shadow(radius: 2)
        }
    }
}
