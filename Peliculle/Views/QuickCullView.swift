import SwiftUI

/// Contexte de lancement du tri rapide (idée 14) : le périmètre choisi.
struct QuickCullContext: Identifiable {
    let items: [PhotoItem]
    var id: PhotoItem.ID { items[0].id }
}

/// Sélecteur de périmètre du tri rapide : comptes en direct. Le périmètre
/// est déjà borné au Mode Voyage par l'appelant (`GridView`).
struct QuickCullSetupView: View {
    let untriaged: [PhotoItem]
    let today: [PhotoItem]
    let onStart: ([PhotoItem]) -> Void

    var body: some View {
        NavigationStack {
            List {
                scopeRow(
                    "Non triées",
                    subtitle: "Reprendre là où le tri s'est arrêté",
                    symbol: "questionmark.circle",
                    items: untriaged
                )
                scopeRow(
                    "Aujourd'hui",
                    subtitle: "Les photos prises aujourd'hui",
                    symbol: "sun.max",
                    items: today
                )
            }
            .navigationTitle("Tri rapide")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.height(260)])
    }

    private func scopeRow(
        _ title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        symbol: String,
        items: [PhotoItem]
    ) -> some View {
        Button {
            onStart(items)
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: symbol)
                }
                Spacer()
                Text("\(items.count)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .disabled(items.isEmpty)
    }
}

/// Idée 14 — écran « Tri rapide » : pile de cartes plein écran, une passe de
/// tri au swipe. **Droite = garder, gauche = rejeter, haut = ignorer** (la
/// carte repart en bas de la pile, reste non triée) ; le bas reste libre.
/// Retour de swipe riche (tilt + reflet + halo teinté), zoom d'inspection au
/// double-tap (swipes désactivés au zoom, via `PhotoDetailImage`). Les
/// **rafales** font une carte par pile (swipe = toute la pile, bouton Duel
/// pour départager). Partage la même `CullSession` que la grille ; boutons de
/// repli + ↩︎. **Bilan de fin de passe** quand tout est décidé ou ignoré.
struct QuickCullView: View {
    let session: CullSession
    let sourceItems: [PhotoItem]

    @Environment(\.dismiss) private var dismiss
    @AppStorage("burstThreshold") private var burstThreshold = 1.0
    @AppStorage("burstGrouping") private var groupBursts = true

    /// Une carte : photo seule ou pile de rafale entière (idée 3).
    private struct Card: Identifiable {
        let items: [PhotoItem]
        var id: PhotoItem.ID { items[0].id }
        var cover: PhotoItem { items[0] }
        var isStack: Bool { items.count > 1 }
    }

    private enum Action {
        case keep
        case reject
        case ignore
    }

    @State private var queue: [Card] = []
    @State private var didSetup = false
    /// Journal de la passe pour le ↩︎ local (les décisions passent aussi par
    /// le journal de la session, `session.undo()` les défait).
    @State private var history: [(card: Card, action: Action)] = []
    /// Cartes ignorées depuis la dernière décision : quand toute la file est
    /// ignorée, un tour complet a été fait → fin de passe.
    @State private var ignoredIDs = Set<PhotoItem.ID>()
    @State private var finished = false

    @State private var keptCount = 0
    @State private var rejectedCount = 0

    @State private var dragOffset: CGSize = .zero
    @State private var isZoomed = false
    @State private var isExiting = false
    @State private var duelContext: DuelContext?
    /// Format (largeur/hauteur) des photos de couverture, pour donner à
    /// chaque carte la forme de sa photo.
    @State private var cardRatios: [PhotoItem.ID: CGFloat] = [:]

    @State private var keepFeedback = 0
    @State private var rejectFeedback = 0
    @State private var ignoreFeedback = 0

    private var remainingPhotoCount: Int {
        queue.reduce(0) { $0 + $1.items.count }
    }

    /// Photos décidées (gardées + rejetées) sur le total de la passe. Les
    /// ignorées restent dans la file → comptées dans le restant, pas dans le
    /// fait : la barre ne se remplit que sur de vraies décisions.
    private var decidedPhotoCount: Int { keptCount + rejectedCount }
    private var totalPhotoCount: Int { decidedPhotoCount + remainingPhotoCount }

    var body: some View {
        NavigationStack {
            ZStack {
                // Fond adaptatif : suit l'apparence claire/sombre de l'iPhone.
                Color(.systemBackground).ignoresSafeArea()
                if finished || queue.isEmpty {
                    summaryView
                } else {
                    // Barre de progression épinglée en haut, boutons épinglés
                    // en bas, photo **centrée** entre les deux (retour Owen) :
                    // les Spacer de même poids maintiennent la carte au milieu
                    // quelle que soit sa hauteur (portrait vs paysage).
                    VStack(spacing: 0) {
                        progressBar
                        Spacer(minLength: 12)
                        cardStack
                        Spacer(minLength: 12)
                        actionBar
                            .padding(.bottom, 12)
                    }
                }
            }
            .navigationTitle(finished || queue.isEmpty ? "" : "\(remainingPhotoCount) à trier")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fermer", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Annuler la dernière action", systemImage: "arrow.uturn.backward") {
                        undoLast()
                    }
                    .disabled(history.isEmpty)
                }
            }
            .sensoryFeedback(.success, trigger: keepFeedback)
            .sensoryFeedback(.warning, trigger: rejectFeedback)
            .sensoryFeedback(.impact(weight: .light), trigger: ignoreFeedback)
            .fullScreenCover(item: $duelContext) { context in
                DuelView(session: session, contenders: context.items) { applied in
                    duelContext = nil
                    if applied { removeResolvedStack(context.items) }
                }
            }
            .task { setupIfNeeded() }
        }
    }

    // MARK: - Progression

    /// Barre de progression fine en haut : décisions prises sur le total de
    /// la passe (retour Owen). Complète le « n à trier » du titre.
    private var progressBar: some View {
        let fraction = totalPhotoCount > 0
            ? CGFloat(decidedPhotoCount) / CGFloat(totalPhotoCount)
            : 0
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.15))
                Capsule()
                    .fill(.primary)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 4)
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .animation(.snappy(duration: 0.3), value: decidedPhotoCount)
        .accessibilityLabel(Text("Progression du tri"))
        .accessibilityValue(Text("\(decidedPhotoCount) sur \(totalPhotoCount)"))
    }

    // MARK: - Pile de cartes

    private var cardStack: some View {
        // La carte du dessous adopte la **silhouette de la carte du dessus**
        // (retour Owen) : un portrait ne dépasse plus d'un paysage, la pile
        // reste une pile nette quelles que soient les orientations.
        let topRatio = queue.first.flatMap { cardRatios[$0.cover.id] }
        return ZStack {
            // La carte suivante, entrevue derrière la carte du dessus.
            if queue.count > 1 {
                cardView(queue[1], isTop: false, frameRatio: topRatio)
            }
            if let top = queue.first {
                cardView(top, isTop: true, frameRatio: topRatio)
                    // `.simultaneousGesture`, pas `.gesture` : posé au-dessus
                    // du UIScrollView de la carte, un gesture standard est
                    // différé par l'arène UIKit et ne reçoit ses updates
                    // qu'au relâchement (la carte « sautait » au lieu de
                    // suivre le doigt). En simultané, le drag est continu —
                    // le suivi façon Tinder (offset + tilt) marche en direct.
                    .simultaneousGesture(dragGesture)
                    // Redémarre l'état de geste proprement à chaque carte.
                    .id(top.id)
            }
        }
    }

    /// - Parameter frameRatio: silhouette imposée à la carte (celle du dessus
    ///   pour que la pile soit régulière). La photo se pose **au format** à
    ///   l'intérieur, sur un fond mat sombre : une photo d'orientation
    ///   différente est letterboxée dans la carte au lieu d'en déborder. La
    ///   carte du dessus a `frameRatio == son propre ratio` → photo pleine.
    private func cardView(_ card: Card, isTop: Bool, frameRatio: CGFloat?) -> some View {
        let offset = isTop ? dragOffset : .zero
        // 3:4 en attendant l'aperçu (déjà en cache la plupart du temps).
        let ratio = frameRatio ?? cardRatios[card.cover.id] ?? 0.75
        return ZStack {
            PhotoDetailImage(
                item: card.cover,
                onZoomChange: { isZoomed = $0 },
                // Pas de HUD à masquer dans le Tri rapide (pile de cartes, pas
                // de chrome sur la photo) : le tap simple n'a rien à basculer.
                onSingleTap: {},
                // Pas de raccourci swipe-haut natif ici : le drag simultané
                // gère lui-même le haut (= ignorer) avec le suivi visuel, et
                // deux détecteurs pour le même geste finiraient par doubler
                // l'action.
                onSwipeUp: {}
            )
            if card.isStack {
                stackControls(card)
            }
        }
        .aspectRatio(ratio, contentMode: .fit)
        // Fond mat sombre : quand la photo (au format) ne remplit pas la
        // silhouette de la carte (carte du dessous d'orientation différente),
        // les bords lisent comme une carte, pas comme un trou noir.
        .background(Color(white: 0.10))
        .clipShape(.rect(cornerRadius: 22))
        // Le retour de swipe vit **hors** du clip : l'ombre du halo peut
        // rayonner autour de la carte.
        .overlay { feedbackOverlay(offset) }
        // La carte entrevue derrière est assombrie : deux photos à pleine
        // luminosité (souvent d'orientations différentes) se disputaient
        // l'œil pendant le swipe.
        .overlay {
            if !isTop {
                RoundedRectangle(cornerRadius: 22)
                    .fill(.black.opacity(0.45))
            }
        }
        .padding(.horizontal, 14)
        .rotationEffect(.degrees(Double(offset.width / 18)))
        .offset(x: offset.width, y: offset.height)
        .scaleEffect(isTop ? 1 : 0.94)
        .animation(.snappy(duration: 0.25), value: isTop)
        .task(id: card.cover.id) {
            await loadRatio(of: card.cover)
        }
    }

    /// Format de la photo de couverture, depuis l'aperçu 400 px (cache
    /// partagé avec la grille — coût quasi nul).
    private func loadRatio(of item: PhotoItem) async {
        guard cardRatios[item.id] == nil else { return }
        guard let image = await ThumbnailLoader.load(item: item, maxPixel: 400),
              image.size.height > 0 else { return }
        cardRatios[item.id] = image.size.width / image.size.height
    }

    /// Retour de swipe : halo teinté selon l'action pressentie, reflet
    /// (sheen) qui suit le tilt, et libellé de l'action. Posé en overlay de
    /// la carte déjà mise au format de la photo : le liseré en suit le
    /// contour exact.
    @ViewBuilder
    private func feedbackOverlay(_ offset: CGSize) -> some View {
        let intensity = min(max(abs(offset.width), -offset.height) / 130, 1)
        if intensity > 0.05, let pending = pendingAction(offset) {
            let color: Color = switch pending {
            case .keep: .green
            case .reject: .red
            case .ignore: .yellow
            }
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(color.opacity(0.9 * intensity), lineWidth: 4)
                .shadow(color: color.opacity(0.6 * intensity), radius: 16)
            LinearGradient(
                colors: [.white.opacity(0.22 * intensity), .clear],
                startPoint: offset.width >= 0 ? .topLeading : .topTrailing,
                endPoint: .center
            )
            .clipShape(.rect(cornerRadius: 22))
            .allowsHitTesting(false)
            VStack {
                Label(
                    pending == .keep ? "Garder" : pending == .reject ? "Rejeter" : "Plus tard",
                    systemImage: pending == .keep
                        ? "checkmark" : pending == .reject ? "xmark" : "arrow.uturn.down"
                )
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(color.opacity(0.85), in: .capsule)
                .opacity(Double(intensity))
                Spacer()
            }
            .padding(.top, 24)
        }
    }

    /// Badge de pile + bouton Duel (idées 3/4) sur les cartes de rafale.
    private func stackControls(_ card: Card) -> some View {
        VStack {
            HStack {
                Label("\(card.items.count)", systemImage: "square.stack")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: .capsule)
                Spacer()
            }
            Spacer()
            Button {
                duelContext = DuelContext(items: card.items)
            } label: {
                Label("Duel", systemImage: "rectangle.split.2x1")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.glass)
        }
        .padding(26)
    }

    // MARK: - Gestes & actions

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !isZoomed, !isExiting else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                guard !isZoomed, !isExiting else { return }
                if let action = pendingAction(value.translation) {
                    perform(action)
                } else {
                    withAnimation(.snappy(duration: 0.3)) { dragOffset = .zero }
                }
            }
    }

    /// L'action qu'un relâchement déclencherait pour ce déplacement — aussi la
    /// source du retour visuel, pour que l'annonce et l'acte coïncident
    /// toujours. Le bas reste libre (pull sans effet).
    private func pendingAction(_ translation: CGSize) -> Action? {
        if -translation.height > 110, abs(translation.width) < 80 { return .ignore }
        if translation.width > 110 { return .keep }
        if translation.width < -110 { return .reject }
        return nil
    }

    /// Anime la sortie de la carte puis applique l'action. `isExiting`
    /// verrouille contre le double déclenchement (drag + recognizer natif).
    private func perform(_ action: Action) {
        guard let card = queue.first, !isExiting else { return }
        isExiting = true
        let fling: CGSize = switch action {
        case .keep: CGSize(width: 600, height: -40)
        case .reject: CGSize(width: -600, height: -40)
        case .ignore: CGSize(width: 0, height: -700)
        }
        withAnimation(.easeIn(duration: 0.18)) { dragOffset = fling }
        switch action {
        case .keep: keepFeedback += 1
        case .reject: rejectFeedback += 1
        case .ignore: ignoreFeedback += 1
        }
        Task {
            try? await Task.sleep(for: .seconds(0.18))
            apply(action, to: card)
            dragOffset = .zero
            isExiting = false
        }
    }

    private func apply(_ action: Action, to card: Card) {
        switch action {
        case .keep:
            session.setDecision(.keep, for: card.items)
            keptCount += card.items.count
            ignoredIDs.remove(card.id)
            queue.removeFirst()
        case .reject:
            session.setDecision(.reject, for: card.items)
            rejectedCount += card.items.count
            ignoredIDs.remove(card.id)
            queue.removeFirst()
        case .ignore:
            // Remise en bas de la pile, reste non triée (file mutable).
            queue.removeFirst()
            queue.append(card)
            ignoredIDs.insert(card.id)
            // Un tour complet sans décision → la passe est finie.
            if queue.allSatisfy({ ignoredIDs.contains($0.id) }) {
                finished = true
            }
        }
        history.append((card: card, action: action))
    }

    private func undoLast() {
        guard let last = history.popLast() else { return }
        finished = false
        switch last.action {
        case .keep:
            session.undo()
            keptCount -= last.card.items.count
            queue.insert(last.card, at: 0)
        case .reject:
            session.undo()
            rejectedCount -= last.card.items.count
            queue.insert(last.card, at: 0)
        case .ignore:
            if let index = queue.lastIndex(where: { $0.id == last.card.id }) {
                queue.remove(at: index)
            }
            ignoredIDs.remove(last.card.id)
            queue.insert(last.card, at: 0)
        }
    }

    /// Duel appliqué depuis une carte de pile : la pile est départagée (une
    /// gardée, le reste rejeté par `DuelView`), sa carte quitte la file. Le
    /// ↩︎ de la session sait défaire l'élection ; elle ne rentre pas dans le
    /// journal local de la passe.
    private func removeResolvedStack(_ items: [PhotoItem]) {
        guard let index = queue.firstIndex(where: { $0.id == items[0].id }) else { return }
        let card = queue.remove(at: index)
        keptCount += 1
        rejectedCount += card.items.count - 1
        ignoredIDs.remove(card.id)
        if !queue.isEmpty, queue.allSatisfy({ ignoredIDs.contains($0.id) }) {
            finished = true
        }
    }

    // MARK: - Boutons de repli

    private var actionBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                actionButton(symbol: "xmark", label: "Rejeter", tint: .red) {
                    perform(.reject)
                }
                actionButton(symbol: "arrow.uturn.down", label: "Plus tard", tint: .yellow) {
                    perform(.ignore)
                }
                actionButton(symbol: "checkmark", label: "Garder", tint: .green) {
                    perform(.keep)
                }
            }
        }
    }

    private func actionButton(
        symbol: String,
        label: LocalizedStringKey,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 56, height: 56)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(label)
    }

    // MARK: - Bilan de fin de passe

    private var summaryView: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.rectangle.stack")
                .font(.system(size: 54))
                .foregroundStyle(.green)
            Text("Passe terminée")
                .font(.title2.bold())
            VStack(alignment: .leading, spacing: 8) {
                summaryRow(
                    "checkmark.circle.fill", .green,
                    String(localized: "\(keptCount) gardée(s)")
                )
                summaryRow(
                    "xmark.circle.fill", .red,
                    String(localized: "\(rejectedCount) rejetée(s)")
                )
                if remainingPhotoCount > 0 {
                    summaryRow(
                        "arrow.uturn.down.circle.fill", .yellow,
                        String(localized: "\(remainingPhotoCount) à revoir")
                    )
                }
            }
            VStack(spacing: 12) {
                if remainingPhotoCount > 0 {
                    Button {
                        ignoredIDs.removeAll()
                        finished = false
                    } label: {
                        Text("Refaire une passe sur les ignorées")
                            .font(.headline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                }
                Button("Terminer") { dismiss() }
                    .buttonStyle(.glass)
            }
            .padding(.top, 8)
        }
        // Sur le fond adaptatif : `.primary` (blanc en sombre, noir en clair).
        // Les libellés sur les cartes/scrims gardent leur blanc dédié.
        .foregroundStyle(.primary)
        .padding(30)
    }

    private func summaryRow(_ symbol: String, _ color: Color, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.white, color)
        }
        .font(.body.weight(.medium))
    }

    // MARK: - Construction de la file

    private func setupIfNeeded() {
        guard !didSetup else { return }
        didSetup = true
        queue = makeCards(from: sourceItems)
    }

    /// Une carte par photo, sauf rafales groupées (mêmes réglages ⚙️ que la
    /// grille) : une carte par **pile**, dans l'ordre d'affichage.
    private func makeCards(from items: [PhotoItem]) -> [Card] {
        guard groupBursts else { return items.map { Card(items: [$0]) } }
        return BurstGrouper.entries(in: items, threshold: burstThreshold)
            .map { entry -> Card in
                switch entry {
                case .single(let item): Card(items: [item])
                case .stack(let members, _): Card(items: members)
                }
            }
    }
}
