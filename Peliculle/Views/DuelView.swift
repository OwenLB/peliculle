import SwiftUI

/// Élément de présentation du duel (`fullScreenCover(item:)`).
struct DuelContext: Identifiable {
    let items: [PhotoItem]
    var id: PhotoItem.ID { items[0].id }
}

/// Idée 4 — comparaison de similaires pour garder **la ou les** meilleure(s).
/// Deux photos **l'une au-dessus de l'autre** (toujours : l'app se tient en
/// portrait), **zoom/pan synchronisé** — un seul geste, la même transformation
/// des deux côtés, le moyen le plus fiable de comparer le piqué au même endroit.
///
/// Modèle : la **référence** (la meilleure) est en haut ; la photo **à juger**
/// en bas, seule à porter la barre d'action. La photo 0 est référence d'entrée,
/// permutable.
/// - **Élire** : la photo du bas devient référence (monte) ; l'ancienne
///   référence **redescend** en bas pour être re-jugée — jamais rejetée d'office.
/// - **Garder** : gardée en plus (référence inchangée) ; photo suivante.
/// - **Rejeter** : écartée ; photo suivante.
/// Une **nouvelle** photo n'arrive que sur Garder/Rejeter ; Élire ne fait que
/// permuter. Fin (tournoi 3+) → récap pour tout revoir, puis `CullSession.resolve`
/// en une seule entrée d'annulation. Quitter (✕) n'applique rien.
struct DuelView: View {
    let session: CullSession
    /// Ordre chronologique ; ≥ 2 photos.
    let contenders: [PhotoItem]
    /// `true` si la résolution a été appliquée.
    var onDone: (Bool) -> Void

    /// Référence (haut) et photo à juger (bas). Photo 0 = référence d'entrée.
    @State private var referenceIndex = 0
    @State private var challengerIndex = 1
    /// Prochaine **nouvelle** photo à présenter (les deux premières sont déjà à
    /// l'écran). N'avance que sur Garder/Rejeter — Élire ne fait que permuter.
    @State private var nextContender = 2

    /// Gardées « en plus » (hors référence) ; `rejected` ne sert qu'au compteur.
    @State private var kept: Set<PhotoItem.ID> = []
    @State private var rejected: Set<PhotoItem.ID> = []

    @State private var steadyZoom: CGFloat = 1
    @GestureState private var pinchZoom: CGFloat = 1
    @State private var steadyOffset: CGSize = .zero
    @GestureState private var panOffset: CGSize = .zero
    @State private var hapticTrigger = 0

    @State private var showRecap = false
    @State private var finalReferenceID: PhotoItem.ID?

    private var zoom: CGFloat { min(max(steadyZoom * pinchZoom, 1), 8) }

    /// Décalage commun aux deux panneaux, uniquement en zoom.
    private var offset: CGSize {
        guard zoom > 1.01 else { return .zero }
        return CGSize(
            width: steadyOffset.width + panOffset.width,
            height: steadyOffset.height + panOffset.height
        )
    }

    private var isTournament: Bool { contenders.count > 2 }

    var body: some View {
        // Toujours haut/bas (l'app se tient en portrait).
        VStack(spacing: 2) {
            DuelPane(item: contenders[referenceIndex], role: .reference, zoom: zoom, offset: offset)
                .id(contenders[referenceIndex].id)
            DuelPane(item: contenders[challengerIndex], role: .challenger, zoom: zoom, offset: offset)
                .id(contenders[challengerIndex].id)
        }
        .simultaneousGesture(magnification)
        .simultaneousGesture(pan)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) { topBar }
        .safeAreaInset(edge: .bottom) { actionBar }
        .sensoryFeedback(.impact(weight: .medium), trigger: hapticTrigger)
        .statusBarHidden()
        .sheet(isPresented: $showRecap) {
            if let refID = finalReferenceID {
                DuelRecapView(
                    contenders: contenders,
                    referenceID: refID,
                    initiallyKept: kept.union([refID]),
                    onFinish: { keptIDs in applyResolution(keptIDs: keptIDs) },
                    onCancel: { onDone(false) }
                )
                .interactiveDismissDisabled()
            }
        }
    }

    // MARK: - Gestes de zoom (synchronisés)

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

    // MARK: - Décisions (photo du bas)

    /// « Élire » : le bas devient référence (monte) ; l'ancienne référence
    /// **redescend** pour être re-jugée. Simple permutation, rien n'est rejeté.
    private func elect() {
        hapticTrigger += 1
        let old = referenceIndex
        referenceIndex = challengerIndex
        challengerIndex = old
        // La nouvelle référence n'est plus une simple gardée/rejetée.
        let refID = contenders[referenceIndex].id
        kept.remove(refID)
        rejected.remove(refID)
        resetZoom()
    }

    /// « Garder » : la photo du bas est gardée en plus ; photo suivante.
    private func keep() {
        hapticTrigger += 1
        let id = contenders[challengerIndex].id
        kept.insert(id)
        rejected.remove(id)
        advance()
    }

    /// « Rejeter » : la photo du bas est écartée ; photo suivante.
    private func discard() {
        hapticTrigger += 1
        let id = contenders[challengerIndex].id
        rejected.insert(id)
        kept.remove(id)
        advance()
    }

    /// Amène la prochaine **nouvelle** photo en bas ; plus aucune → fin.
    private func advance() {
        if nextContender < contenders.count {
            challengerIndex = nextContender
            nextContender += 1
            resetZoom()
        } else {
            finish()
        }
    }

    /// Duel simple (2) → applique direct ; tournoi (3+) → récap pour vérifier.
    private func finish() {
        finalReferenceID = contenders[referenceIndex].id
        if isTournament {
            showRecap = true
        } else {
            applyResolution(keptIDs: kept.union([contenders[referenceIndex].id]))
        }
    }

    /// Applique la résolution à partir de l'ensemble **gardé** final (récap ou
    /// duel simple) : référence = la couronnée si gardée, sinon la 1ʳᵉ gardée
    /// dans l'ordre ; le reste rejeté. Aucune gardée → tout rejeté. Une seule
    /// entrée d'annulation (`CullSession.resolve`).
    private func applyResolution(keptIDs: Set<PhotoItem.ID>) {
        let keepers = contenders.filter { keptIDs.contains($0.id) }
        let rejects = contenders.filter { !keptIDs.contains($0.id) }
        let reference = keepers.first(where: { $0.id == finalReferenceID }) ?? keepers.first
        if let reference {
            session.resolve(
                reference: reference,
                keep: keepers.filter { $0.id != reference.id },
                reject: rejects
            )
        } else {
            // Aucune gardée : tout le groupe rejeté (une entrée d'annulation).
            session.setDecision(.reject, for: contenders)
        }
        onDone(true)
    }

    // MARK: - Chrome

    /// Titre **centré sur l'écran** (posé en ZStack, indépendant de la largeur
    /// du ✕), ✕ à gauche.
    private var topBar: some View {
        ZStack {
            if isTournament {
                Text("\(contenders.count) similaires")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular.tint(.black.opacity(0.25)), in: .capsule)
            }
            HStack {
                Button {
                    onDone(false)
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Quitter sans appliquer")
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    /// Barre unique, agit sur la photo du bas : Rejeter · Garder · Élire, plus
    /// un compteur (gardées / rejetées / à venir).
    private var actionBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                actionButton("Rejeter", symbol: "xmark", tint: .red, prominent: false, action: discard)
                actionButton("Garder", symbol: "plus", tint: nil, prominent: false, action: keep)
                actionButton("Élire", symbol: "crown.fill", tint: .green, prominent: true, action: elect)
            }
            Text(tallyText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var tallyText: String {
        let remaining = max(0, contenders.count - nextContender)
        var parts = [
            String(localized: "\(kept.count) gardée(s)"),
            String(localized: "\(rejected.count) rejetée(s)")
        ]
        if remaining > 0 { parts.append(String(localized: "\(remaining) à venir")) }
        return parts.joined(separator: " · ")
    }

    /// Bouton de décision : symbole + libellé, cible ≥ 56 pt. Élire en verre
    /// teinté prominent (vert), les autres en verre neutre — Rejeter teinté rouge.
    @ViewBuilder
    private func actionButton(
        _ title: LocalizedStringKey,
        symbol: String,
        tint: Color?,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let label = VStack(spacing: 3) {
            Image(systemName: symbol).font(.title3.weight(.bold))
            Text(title).font(.caption2.weight(.semibold))
        }
        .frame(maxWidth: .infinity, minHeight: 56)

        if prominent {
            Button(action: action) { label }
                .buttonStyle(.glassProminent)
                .tint(tint)
        } else {
            Button(action: action) { label }
                .buttonStyle(.glass)
                .tint(tint)
        }
    }
}

/// Rôle d'un panneau : la référence (haut, couronnée) ou la photo à juger (bas).
private enum PaneRole { case reference, challenger }

/// Un panneau du duel : aperçu 2048 px immédiat, pleine résolution chargée au
/// premier zoom. La transformation (zoom + pan) est **imposée par le parent**,
/// identique des deux côtés. Aucun bouton : la décision passe par la barre du bas.
private struct DuelPane: View {
    let item: PhotoItem
    let role: PaneRole
    let zoom: CGFloat
    let offset: CGSize

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
        // Repère de rôle : couronne (référence) au **coin haut-droit** pour ne
        // pas passer sous le ✕ ; « À juger » (challenger) au coin haut-gauche.
        .overlay(alignment: role == .reference ? .topTrailing : .topLeading) { roleBadge }
        // Spinner pleine résolution au coin bas-droit (loin de la couronne).
        .overlay(alignment: .bottomTrailing) {
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

    @ViewBuilder
    private var roleBadge: some View {
        switch role {
        case .reference:
            // Juste l'icône couronne (fixe), pas de texte.
            Image(systemName: "crown.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.yellow)
                .padding(8)
                .background(.black.opacity(0.5), in: .circle)
                .padding(8)
        case .challenger:
            Text("À juger")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.black.opacity(0.5), in: .capsule)
                .padding(8)
        }
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

/// Récap de fin de tournoi : **toutes** les photos dans l'ordre, chacune avec un
/// indicateur garder/rejeter **inversable** (tap). La référence porte en plus
/// une **couronne fixe** — même taille, même rang que les autres, jamais mise à
/// part. **Appui long** = aperçu agrandi (quick preview). Terminer applique tout ;
/// Annuler n'applique rien.
private struct DuelRecapView: View {
    let contenders: [PhotoItem]
    let referenceID: PhotoItem.ID
    let initiallyKept: Set<PhotoItem.ID>
    var onFinish: (Set<PhotoItem.ID>) -> Void
    var onCancel: () -> Void

    @State private var kept: Set<PhotoItem.ID>
    @State private var preview: PhotoItem?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    init(
        contenders: [PhotoItem],
        referenceID: PhotoItem.ID,
        initiallyKept: Set<PhotoItem.ID>,
        onFinish: @escaping (Set<PhotoItem.ID>) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.contenders = contenders
        self.referenceID = referenceID
        self.initiallyKept = initiallyKept
        self.onFinish = onFinish
        self.onCancel = onCancel
        _kept = State(initialValue: initiallyKept)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Touchez pour garder/rejeter · appui long pour agrandir.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(contenders) { item in
                            RecapThumb(
                                item: item,
                                isKept: kept.contains(item.id),
                                isReference: item.id == referenceID,
                                onToggle: { toggle(item.id) },
                                onPreview: { preview = item }
                            )
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Résultat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Terminer") { onFinish(kept) }
                        .fontWeight(.semibold)
                }
            }
        }
        // Aperçu agrandi (appui long) : plein écran, un tap referme. Rien d'autre.
        .overlay {
            if let preview {
                QuickPreview(item: preview) { self.preview = nil }
            }
        }
    }

    private func toggle(_ id: PhotoItem.ID) {
        if kept.contains(id) { kept.remove(id) } else { kept.insert(id) }
    }
}

/// Vignette du récap : aperçu 400 px + indicateur garder/rejeter (tap pour
/// inverser) et couronne fixe si c'est la référence. Appui long → aperçu.
private struct RecapThumb: View {
    let item: PhotoItem
    let isKept: Bool
    let isReference: Bool
    var onToggle: () -> Void
    var onPreview: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            // Assombri quand rejeté.
            .overlay { if !isKept { Color.black.opacity(0.5) } }
            // Couronne fixe (référence) au coin haut-gauche.
            .overlay(alignment: .topLeading) {
                if isReference {
                    Image(systemName: "crown.fill")
                        .font(.title3)
                        .foregroundStyle(.yellow)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            // Indicateur garder/rejeter au coin haut-droit.
            .overlay(alignment: .topTrailing) { keepBadge.padding(5) }
            .clipShape(.rect(cornerRadius: 8))
            .contentShape(.rect)
            .onTapGesture { onToggle() }
            .onLongPressGesture(minimumDuration: 0.3) { onPreview() }
            .task(id: item.id) {
                image = await ThumbnailLoader.load(item: item, maxPixel: 400)
            }
    }

    private var keepBadge: some View {
        Image(systemName: isKept ? "checkmark.circle.fill" : "xmark.circle.fill")
            .font(.title3)
            .foregroundStyle(.white, isKept ? .green : .red)
            .shadow(radius: 2)
    }
}

/// Aperçu agrandi « quick preview » (appui long au récap) : la photo en grand
/// sur fond sombre. Un tap referme — aucune autre action.
private struct QuickPreview: View {
    let item: PhotoItem
    var onDismiss: () -> Void

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding()
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onDismiss() }
        .task(id: item.id) {
            image = await ThumbnailLoader.load(item: item, maxPixel: 2048)
        }
    }
}
