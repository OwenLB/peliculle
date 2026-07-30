import SwiftUI

/// Revue UX (UX3) — filmstrip du viewer : bande horizontale de miniatures
/// au-dessus des contrôles du bas, photo courante centrée et mise en
/// évidence (liseré blanc + légère échelle), façon Photos.app / Photo
/// Mechanic. Un tap saute directement à la photo : le pager (`PhotoPager`)
/// anime le saut **du bon côté**, en avant comme en arrière, et ne traverse
/// pas les pages intermédiaires — sauter de 200 photos coûte un défilement,
/// pas deux cents. La bande, elle, anime son recentrage
/// (`scrollPosition(id:anchor: .center)`).
///
/// La bande sert aussi de **carte de progression** : rejetées assombries
/// (même voile que la grille), gardées marquées d'un point vert — les
/// « trous » non triés se voient d'un coup d'œil. Pas d'autres badges à
/// cette taille (bruit). Vignettes servies par `ThumbnailLoader` au même
/// `maxPixel` que la grille → cache déjà chaud, coût quasi nul.
struct FilmstripView: View {
    let items: [PhotoItem]
    @Binding var index: Int

    /// Id de la photo ancrée au centre de la bande. Piloté dans les deux
    /// sens : le pager recentre la bande (via `onChange`), et l'utilisateur
    /// peut faire défiler la bande librement sans changer de page.
    @State private var scrolledID: PhotoItem.ID?

    /// Hauteur des vignettes (~44-48 pt d'après la revue) : 44 pt = cible
    /// tactile minimale HIG, l'échelle de la courante reste dans la marge.
    private static let thumbSide: CGFloat = 44

    init(items: [PhotoItem], index: Binding<Int>) {
        self.items = items
        self._index = index
        // Position initiale posée avant le premier rendu : un `onAppear`
        // ferait défiler la bande depuis son bord au lieu d'ouvrir centré.
        if items.indices.contains(index.wrappedValue) {
            self._scrolledID = State(initialValue: items[index.wrappedValue].id)
        }
    }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                    Button {
                        // Saut direct : le pager s'occupe de l'animation et
                        // de sa direction (voir en-tête).
                        index = offset
                    } label: {
                        FilmstripThumb(item: item, isCurrent: offset == index)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(item.filename)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $scrolledID, anchor: .center)
        // L'anchor de `scrollPosition` ne vaut que pour les **changements**
        // de la valeur ; la position initiale (celle posée dans l'init)
        // utilise l'ancre par défaut du ScrollView — topLeading, qui collait
        // la photo ouverte au bord gauche au lieu du centre.
        .defaultScrollAnchor(.center)
        .scrollIndicators(.hidden)
        // Marge verticale : l'échelle 1.18× de la vignette courante (+ son
        // ombre portée) ne doit pas être rognée par le clip du ScrollView.
        .frame(height: Self.thumbSide + 16)
        .onChange(of: index) {
            guard items.indices.contains(index) else { return }
            withAnimation(.snappy(duration: 0.25)) {
                scrolledID = items[index].id
            }
        }
        .accessibilityLabel(Text("Bande de miniatures"))
    }
}

/// Une vignette de la bande. Struct dédiée : chaque vignette porte son
/// propre chargement paresseux (`.task` annulé quand elle sort de l'écran,
/// comme `ThumbnailCell`).
private struct FilmstripThumb: View {
    let item: PhotoItem
    let isCurrent: Bool

    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .frame(width: 44, height: 44)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            // Rejetée : assombrie (voile noir, couleur d'origine conservée),
            // qu'elle soit courante ou non — c'est un statut, pas un effet de
            // mise en avant. Gardée et non triée gardent leurs couleurs
            // pleines : la mise en avant de la courante se joue sur le
            // contour/l'échelle/l'ombre, pas en assourdissant tout le reste
            // de la bande.
            .overlay {
                if item.decision == .reject {
                    Color.black.opacity(0.55)
                }
            }
            .overlay(alignment: .bottom) {
                // Gardée : point vert discret (un liseré entrerait en
                // conflit avec le liseré blanc de la photo courante).
                if item.decision == .keep {
                    Circle()
                        .fill(.green)
                        .frame(width: 5, height: 5)
                        .padding(.bottom, 3)
                        .shadow(radius: 1)
                }
            }
            .clipShape(.rect(cornerRadius: 6))
            .overlay {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.white, lineWidth: 2.5)
                }
            }
            .shadow(color: .black.opacity(isCurrent ? 0.35 : 0), radius: isCurrent ? 3 : 0, y: 1)
            .scaleEffect(isCurrent ? 1.18 : 1)
            .animation(.snappy(duration: 0.2), value: isCurrent)
            .task(id: item.id) {
                // Même taille cible que la grille → cache partagé, la
                // vignette est le plus souvent déjà décodée.
                image = await ThumbnailLoader.load(item: item, maxPixel: 400)
            }
    }
}
