import SwiftUI

/// Une cellule carrée de la grille (F2). Skeleton pendant le chargement,
/// badge de décision (F5) en surimpression, badge de note (F10), coche de
/// sélection façon Photos.app en mode sélection. Les photos rejetées sont
/// estompées pour balayer la grille d'un coup d'œil. Le chargement est
/// paresseux et annulé automatiquement quand la cellule quitte l'écran.
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
            .overlay(alignment: .topTrailing) { decisionBadge }
            .overlay(alignment: .topLeading) {
                savedBadge.padding(5)
            }
            .overlay(alignment: .bottomLeading) { ratingBadge }
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
                    if item.videoDuration == nil, let url = item.url {
                        item.videoDuration = await VideoInfo.duration(of: url)
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

    private var decisionBadge: some View {
        DecisionBadge(decision: item.decision, font: .title3)
            .padding(5)
    }

    /// Signale qu'une copie est déjà dans la pellicule (cette session).
    @ViewBuilder
    private var savedBadge: some View {
        if item.savedToLibrary {
            SavedBadge(font: .footnote)
        }
    }

    private var ratingBadge: some View {
        RatingBadge(rating: item.rating)
            .padding(5)
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
