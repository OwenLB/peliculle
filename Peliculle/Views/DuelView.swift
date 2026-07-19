import SwiftUI

/// Élément de présentation du duel (`fullScreenCover(item:)`).
struct DuelContext: Identifiable {
    let items: [PhotoItem]
    var id: PhotoItem.ID { items[0].id }
}

/// Idée 4 — duel A/B et tournoi. Deux photos l'une au-dessus de l'autre en
/// portrait (côte à côte en paysage), **zoom synchronisé** : un seul geste de
/// pincement/pan, la même transformation appliquée aux deux panneaux — le
/// moyen le plus fiable de comparer le piqué au même endroit.
///
/// Tap sur la meilleure → elle devient championne et affronte la photo
/// suivante ; à la fin, la championne est **gardée** et toutes les autres
/// **rejetées**, en une seule entrée d'annulation (`CullSession.elect`).
/// À deux photos, le premier tap conclut : c'est le duel simple. Quitter en
/// cours de route (✕) n'applique rien.
struct DuelView: View {
    let session: CullSession
    /// Ordre chronologique ; ≥ 2 photos.
    let contenders: [PhotoItem]
    /// `true` si le tournoi est allé au bout (élection appliquée).
    var onDone: (Bool) -> Void

    @State private var championIndex = 0
    @State private var challengerIndex = 1

    @State private var steadyZoom: CGFloat = 1
    @GestureState private var pinchZoom: CGFloat = 1
    @State private var steadyOffset: CGSize = .zero
    @GestureState private var panOffset: CGSize = .zero
    @State private var hapticTrigger = 0

    private var zoom: CGFloat {
        min(max(steadyZoom * pinchZoom, 1), 8)
    }

    /// Décalage commun aux deux panneaux, uniquement en zoom (au repos, les
    /// photos restent calées).
    private var offset: CGSize {
        guard zoom > 1.01 else { return .zero }
        return CGSize(
            width: steadyOffset.width + panOffset.width,
            height: steadyOffset.height + panOffset.height
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let isPortrait = geometry.size.height >= geometry.size.width
            duelLayout(portrait: isPortrait)
        }
        // Fond adaptatif clair/sombre selon l'apparence de l'iPhone.
        .background(Color(.systemBackground))
        .overlay(alignment: .top) { topBar }
        .sensoryFeedback(.impact(weight: .medium), trigger: hapticTrigger)
        .statusBarHidden()
    }

    // MARK: - Panneaux

    private var isTournament: Bool { contenders.count > 2 }

    /// Vrai dès qu'un premier choix a eu lieu : avant ça, les deux photos
    /// sont à égalité — pas de « Championne », pas de « Challenger ».
    private var hasChampion: Bool { challengerIndex > 1 }

    /// Championne (ou 1ʳᵉ prétendante) toujours **en haut** (à gauche en
    /// paysage), challenger toujours **en bas** (à droite). En duel simple,
    /// aucun label : juste deux photos et leurs boutons.
    @ViewBuilder
    private func duelLayout(portrait: Bool) -> some View {
        let top = DuelPane(
            item: contenders[championIndex],
            caption: isTournament
                ? (hasChampion ? String(localized: "Championne") : "1 / \(contenders.count)")
                : nil,
            isChampion: isTournament && hasChampion,
            zoom: zoom,
            offset: offset
        ) {
            win(championIndex)
        }
        // `.id` : repartir d'un panneau vierge à chaque nouvelle photo (état,
        // aperçu, pleine résolution), pour que le challenger suivant s'affiche
        // toujours au lieu de laisser l'ancienne image pendant le chargement.
        .id(contenders[championIndex].id)

        let bottom = DuelPane(
            item: contenders[challengerIndex],
            caption: isTournament ? "\(challengerIndex + 1) / \(contenders.count)" : nil,
            isChampion: false,
            zoom: zoom,
            offset: offset
        ) {
            win(challengerIndex)
        }
        .id(contenders[challengerIndex].id)

        Group {
            if portrait {
                VStack(spacing: 2) {
                    top
                    bottom
                }
            } else {
                HStack(spacing: 2) {
                    top
                    bottom
                }
            }
        }
        .simultaneousGesture(magnification)
        .simultaneousGesture(pan)
    }

    // MARK: - Gestes partagés

    private var magnification: some Gesture {
        MagnifyGesture()
            .updating($pinchZoom) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                steadyZoom = min(max(steadyZoom * value.magnification, 1), 8)
                if steadyZoom <= 1.01 { resetZoom() }
            }
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($panOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                guard zoom > 1.01 else { return }
                steadyOffset.width += value.translation.width
                steadyOffset.height += value.translation.height
            }
    }

    private func resetZoom() {
        steadyZoom = 1
        steadyOffset = .zero
    }

    // MARK: - Tournoi

    /// Dernière manche : on élit et on ferme **sans** toucher aux index — la
    /// vue peut être re-rendue pendant l'animation de fermeture, un
    /// `challengerIndex` poussé hors limites ferait crasher `contenders[...]`.
    private func win(_ index: Int) {
        hapticTrigger += 1
        guard challengerIndex + 1 < contenders.count else {
            session.elect(contenders[index], among: contenders)
            onDone(true)
            return
        }
        championIndex = index
        challengerIndex += 1
        resetZoom()
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Button {
                onDone(false)
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    // Adaptatif : contraste sur le verre en apparence claire
                    // comme sombre (le fond du duel suit désormais l'iPhone).
                    .foregroundStyle(.primary)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Quitter sans appliquer")

            Spacer()

            if contenders.count > 2 {
                Text("Duel \(challengerIndex) / \(contenders.count - 1)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular.tint(.black.opacity(0.25)), in: .capsule)
            }

            Spacer()

            // Équilibre le xmark pour garder le compteur centré.
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }
}

/// Un panneau du duel : aperçu 2048 px immédiat, pleine résolution chargée au
/// premier zoom (même stratégie que `PhotoDetailImage`). La transformation
/// (zoom + pan) est **imposée par le parent**, identique des deux côtés.
/// La photo se choisit par le **bouton « Choisir »** de son bandeau — jamais
/// par un tap sur l'image, trop exposé aux missclicks en manipulant le zoom.
private struct DuelPane: View {
    let item: PhotoItem
    /// nil = pas de label (duel simple).
    let caption: String?
    let isChampion: Bool
    let zoom: CGFloat
    let offset: CGSize
    var onChoose: () -> Void

    @State private var preview: UIImage?
    @State private var fullRes: UIImage?
    @State private var isLoadingFull = false

    var body: some View {
        Group {
            if let image = fullRes ?? preview {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .offset(offset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { paneBar }
        .overlay(alignment: .topTrailing) {
            if isLoadingFull {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .padding(10)
            }
        }
        .task(id: item.id) {
            fullRes = nil
            preview = await ThumbnailLoader.load(item: item, maxPixel: 2048)
        }
        .onChange(of: zoom > 1.01) { _, zoomed in
            if zoomed { requestFullResolution() }
        }
    }

    /// Bandeau bas du panneau : label à gauche (s'il y en a un), bouton de
    /// choix à droite — dans le panneau, donc jamais sous le ✕ ni le compteur.
    private var paneBar: some View {
        HStack {
            if let caption {
                HStack(spacing: 4) {
                    if isChampion {
                        Image(systemName: "crown.fill")
                            .foregroundStyle(.yellow)
                    }
                    Text(caption)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.black.opacity(0.5), in: .capsule)
            }

            Spacer()

            Button(action: onChoose) {
                Label("Choisir", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(.green)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func requestFullResolution() {
        guard fullRes == nil, !isLoadingFull else { return }
        isLoadingFull = true
        Task {
            fullRes = await FullResLoader.load(item: item)
            isLoadingFull = false
        }
    }
}
