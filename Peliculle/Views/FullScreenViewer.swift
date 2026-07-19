import SwiftUI
import TipKit

/// F3 + F4 + F5 + F9 — viewer plein écran paginé sur l'ensemble **affiché**
/// (respecte le filtre de la grille). Le `TabView` en style page fournit
/// l'inertie/snap natifs ; la transition d'entrée (zoom hero) et le
/// pull-to-dismiss sont apportés par `.navigationTransition(.zoom:)` côté grille.
/// Chaque page est zoomable (`ZoomableImageView`). Barres en **Liquid Glass**,
/// effacées pendant l'inspection au zoom. Haptique native.
///
/// Le viewer est **épuré par défaut** (la photo d'abord) : le tri s'active via
/// la pastille « Trier », qui déplie la barre Garder/Rejeter ; la notation
/// étoiles (secondaire) se déplie à la demande dans ce mode. Les deux
/// préférences sont mémorisées (`@AppStorage`). Un **filmstrip**
/// (`FilmstripView`, revue UX3) longe le bas hors zoom : carte de
/// progression du tri et saut direct à une photo.
///
/// Gestes de tri (voir ROADMAP) : la navigation prend l'horizontal et le
/// pull-to-dismiss natif prend le bas ; on dédie donc le **swipe vers le haut =
/// garder** (accélérateur, actif uniquement en mode tri), keep/reject restant
/// disponibles sur les boutons. L'avance après décision est **instantanée**
/// (façon Photo Mechanic) : animer la sélection du pager provoque un défilement
/// glitché de pages en cours de chargement.
struct FullScreenViewer: View {
    let session: CullSession
    /// Vrai quand le viewer est scopé à une **pile de rafale** (idée 3) :
    /// affiche la rangée Élire / Duel au-dessus de la barre de tri.
    let isStack: Bool
    /// Snapshot local : la suppression d'une photo retire sa page sans
    /// toucher à l'ordre des autres.
    @State private var items: [PhotoItem]
    @State var index: Int
    @State private var hapticTrigger = 0
    /// Idée 13 — flash de confirmation de décision : la valeur affichée et un
    /// compteur pour rejouer le flash même deux fois de suite sur la même
    /// décision. Haptique différenciée via deux triggers dédiés.
    @State private var flashDecision: CullDecision?
    @State private var flashCount = 0
    @State private var keepFeedback = 0
    @State private var rejectFeedback = 0
    /// Page à quitter une fois le flash joué (retour Owen : avancer à
    /// l'instant du tap remplaçait la photo avant qu'on voie le retour).
    /// Nil si rien n'est en attente ; invalidé si l'utilisateur change de
    /// page lui-même entre-temps.
    @State private var pendingAdvanceIndex: Int?
    @State private var isZoomed = false
    /// Tap simple = mode immersif : la photo occupe tout l'écran, le HUD
    /// (capsule de titre, contrôles, barre de navigation, barre d'état) se
    /// masque. Un second tap le ramène. Persiste d'une photo à l'autre
    /// (on parcourt sans chrome, façon Photos.app) ; le zoom le force en plus.
    @State private var hudHidden = false
    /// Hauteur mesurée de la capsule d'en-tête (overlay flottant) : inset
    /// haut des pages vidéo et zone réservée du centrage des cartes photo.
    @State private var headerHeight: CGFloat = 0
    @State private var showExif = false
    @State private var isSavingCurrent = false
    @State private var saveError: String?
    /// Revue UX (UX4), aligné sur la grille par la factorisation `SaveFlow` :
    /// succès en toast qui s'efface seul, échec en alerte (`saveError`).
    @State private var successToast: String?
    /// Sheet de l'album de destination (idée 8bis). `saveAfterAlbumSetup`
    /// distingue la confirmation du premier enregistrement (on enchaîne sur
    /// la sauvegarde) du simple réglage via le menu ⋯.
    @State private var showAlbumSettings = false
    @State private var saveAfterAlbumSetup = false
    @State private var duelContext: DuelContext?
    @State private var confirmDelete = false
    @State private var showExport = false

    @AppStorage("cullModeEnabled") private var cullMode = false
    @AppStorage("ratingRowVisible") private var showRatingRow = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    /// Idée 23 — ② : un enregistrement qui se termine hors écran envoie son
    /// récap en notification (via `SaveFlow`).
    @Environment(\.scenePhase) private var scenePhase

    init(session: CullSession, items: [PhotoItem], startIndex: Int, isStack: Bool = false) {
        self.session = session
        self.isStack = isStack
        self._items = State(initialValue: items)
        self._index = State(initialValue: startIndex)
    }

    private var currentItem: PhotoItem { items[index] }

    /// Jalon 10 / H5 — décidé **par photo** : un asset photothèque
    /// « s'enregistre » en l'ajoutant à l'album (rien à copier ni exporter,
    /// suppression photothèque) ; un fichier se copie dans la pellicule. Le
    /// viewer ne montre qu'une photo à la fois, donc la provenance de la photo
    /// courante fait foi — correct en session simple comme combinée.
    private var isLibrarySource: Bool { currentItem.isLibraryBacked }

    /// Revue UX (UX2) — badges de statut de la capsule de titre, par ordre
    /// d'importance : la décision (l'état central du tri), puis les statuts
    /// secondaires. La capsule n'en montre que **deux** + « +n » : au-delà,
    /// capsules dans la capsule sur toute la largeur — le détail vit dans la
    /// fiche ⓘ et les contrôles.
    private enum StatusBadgeKind: Hashable {
        case decision
        case saved
        case rating
    }

    private var activeBadges: [StatusBadgeKind] {
        var badges: [StatusBadgeKind] = []
        if currentItem.decision != .undecided { badges.append(.decision) }
        if currentItem.savedToLibrary { badges.append(.saved) }
        if currentItem.rating > 0 { badges.append(.rating) }
        return badges
    }

    /// Le chrome (capsule de titre, contrôles du bas, barre de navigation,
    /// barre d'état) n'est visible qu'hors zoom **et** hors mode immersif.
    private var showsChrome: Bool { !isZoomed && !hudHidden }

    var body: some View {
        TabView(selection: $index) {
            ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                PhotoDetailImage(
                    item: item,
                    // Hors plein écran, la photo devient une carte aux coins
                    // arrondis ; en immersif elle repart bord à bord. **Toutes**
                    // les pages sont encadrées, pas seulement la courante :
                    // conditionner au `index` re-layoutait les deux pages au
                    // snap et cassait l'animation de défilement (impression de
                    // décharge/recharge). Le blocage « entre deux » du pager est
                    // traité dans `FramedPhoto` (taille externe de page stable,
                    // le ratio chargé ne redimensionne que la carte intérieure).
                    // Lié à `hudHidden`, pas au zoom.
                    framed: !hudHidden,
                    cornerRadius: 18,
                    // La pilule d'en-tête flotte sur la zone photo : la carte
                    // se centre sous elle tant qu'elle y tient, et ne passe
                    // derrière que pour gagner de la hauteur (portrait).
                    topInset: showsChrome ? headerHeight : 0,
                    onZoomChange: { zoomed in
                        // Idée 21 — tip ③ : éligible après le premier zoom
                        // manuel ; un zoom suivant vaut geste accompli.
                        if zoomed {
                            if ZoomFullResTip.hasZoomed {
                                ZoomFullResTip().invalidate(reason: .actionPerformed)
                            } else {
                                ZoomFullResTip.hasZoomed = true
                            }
                        }
                        isZoomed = zoomed
                    },
                    onSingleTap: { hudHidden.toggle() },
                    onSwipeUp: {
                        if cullMode {
                            // Idée 21 — tip ① : le geste est acquis.
                            SwipeKeepTip().invalidate(reason: .actionPerformed)
                            keepAndAdvance(item)
                        }
                    }
                )
                // Chaque page photo ignore la safe area individuellement :
                // sans ça, les pages recyclées par le pager héritent parfois
                // d'un inset haut fantôme et la photo apparaît décalée vers le
                // bas. Bord à bord en immersif seulement ; en mode carte,
                // **chaque** page respecte la safe area et l'inset des
                // contrôles du bas (une safe area qui bascule au changement
                // d'`index` re-layoutait les pages au snap et cassait le
                // défilement). Une page vidéo, elle, respecte toujours la safe
                // area — la vue du lecteur, ajustée au format du clip par
                // `FramedPhoto`, garde ainsi la barre AVKit au-dessus des
                // contrôles du viewer, même hors chrome.
                .ignoresSafeArea(edges: (item.isVideo || !hudHidden) ? [] : .all)
                .tag(offset)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Fond **adaptatif** : blanc en apparence claire, noir en sombre — il
        // suit le réglage de l'iPhone (comme partout dans l'app). Il déborde
        // seul de la safe area (comportement par défaut de `background(_:)`) ;
        // le pager, lui, la laisse filtrer jusqu'aux pages — chacune choisit
        // (photo plein écran, vidéo dégagée).
        .background(Color(.systemBackground))
        // En **inset de safe area** (pas en overlay) : la fiche EXIF et les
        // contrôles du bas rognent la zone que les pages vidéo respectent —
        // la barre de progression AVKit se place au-dessus de la pastille
        // « Trier » ou de la barre de tri, jamais dessous. Les photos, plein
        // écran, passent dessous comme avant.
        .safeAreaInset(edge: .bottom) {
            if showsChrome {
                Group {
                    if showExif {
                        ExifSheet(item: currentItem) { showExif = false }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        // Revue UX (UX3) — filmstrip au-dessus des contrôles :
                        // masqué au zoom (branche englobante) et quand la
                        // fiche EXIF occupe le bas (branche ci-dessus).
                        VStack(spacing: 10) {
                            // Mode tri : la bande surmonte les contrôles.
                            // Viewer épuré : la bande et l'entrée « Trier »
                            // partagent une ligne (plus de rangée dédiée).
                            if cullMode {
                                if showsFilmstrip {
                                    FilmstripView(items: items, index: $index)
                                }
                                bottomControls
                            } else {
                                sortEntryRow
                            }
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                // Revue UX (UX2) — même plafond que la capsule de titre : le
                // chrome posé sur la photo ne doit jamais l'engloutir aux
                // tailles d'accessibilité (la fiche ⓘ, ancrée ici, y gagne
                // aussi de ne pas dépasser l'écran — elle ne défile pas).
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
        }
        // Nom + position sous la barre de navigation : la barre est trop
        // chargée (statut à gauche, quatre actions à droite) pour un titre —
        // il finissait systématiquement en « … ».
        // En **overlay flottant**, plus en inset (façon Photos.app) : la zone
        // photo monte jusqu'à la barre de navigation, et un portrait limité
        // par la hauteur regagne la hauteur de la pilule en glissant dessous
        // (le verre au scrim sombre reste lisible sur la photo). La hauteur
        // mesurée sert d'inset aux vidéos et au centrage des cartes photo.
        .overlay(alignment: .top) {
            if showsChrome {
                photoHeader
                    // Idée 21 — tip ③ : sous la capsule de titre, visible
                    // seulement hors zoom (comme le reste du chrome).
                    .popoverTip(ZoomFullResTip(), arrowEdge: .top)
                    // Décollée du bord haut de la zone : sans cette marge, la
                    // pilule affleurait le haut d'une carte pleine hauteur —
                    // alignement fortuit qui lisait bizarrement. Mesurée
                    // **avec** la marge : la zone libre commence sous la pilule.
                    .padding(.top, 8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        headerHeight = $0
                    }
                    // La pilule flotte sur la photo mais n'a aucun élément
                    // interactif : transparente aux touches, pour que le tap
                    // (bascule du mode immersif) marche partout sur la photo.
                    .allowsHitTesting(false)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isZoomed)
        .animation(.easeInOut(duration: 0.25), value: hudHidden)
        .animation(.snappy(duration: 0.25), value: showExif)
        .animation(.snappy(duration: 0.25), value: cullMode)
        .animation(.snappy(duration: 0.25), value: showRatingRow)
        // Idée 13 — flash de confirmation, au-dessus de tout le chrome, jamais
        // interactif. Retiré après 0,7 s (le fondu vit dans l'overlay).
        .overlay {
            if let flashDecision {
                DecisionFlashOverlay(decision: flashDecision)
                    .id(flashCount)
                    .allowsHitTesting(false)
            }
        }
        .task(id: flashCount) {
            guard flashDecision != nil else { return }
            try? await Task.sleep(for: .seconds(0.35))
            guard !Task.isCancelled else { return }
            flashDecision = nil
            // Le flash s'est joué sur la photo décidée → on avance maintenant
            // (toujours sans animation de pager), sauf si l'utilisateur a
            // changé de page entre-temps.
            if let pending = pendingAdvanceIndex {
                pendingAdvanceIndex = nil
                if pending == index { advance() }
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: hapticTrigger)
        .sensoryFeedback(.success, trigger: keepFeedback)
        .sensoryFeedback(.warning, trigger: rejectFeedback)
        .toolbar(showsChrome ? .visible : .hidden, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Annuler la dernière action", systemImage: "arrow.uturn.backward") {
                    session.undo()
                    hapticTrigger += 1
                }
                .disabled(!session.canUndo)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Partage et export d'originaux : sources fichier
                    // uniquement (une photo de la photothèque se partage
                    // depuis Photos).
                    if let url = currentItem.url {
                        ShareLink(item: url) {
                            Label("Partager", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            showExport = true
                        } label: {
                            Label("Exporter vers Fichiers", systemImage: "folder")
                        }
                    }
                    Button {
                        saveAfterAlbumSetup = false
                        showAlbumSettings = true
                    } label: {
                        // Libellé court (tenir sur une ligne de menu) — le
                        // titre de la sheet garde le nom complet.
                        Label("Album", systemImage: "photo.stack")
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Supprimer", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                saveButton
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showExif.toggle()
                } label: {
                    Image(systemName: showExif ? "info.circle.fill" : "info.circle")
                }
            }
        }
        // Alerte centrée (façon demande d'autorisation), pas de sheet du bas.
        .alert("Supprimer cette photo ?", isPresented: $confirmDelete) {
            Button("Annuler", role: .cancel) {}
            Button("Supprimer", role: .destructive) { deleteCurrent() }
        } message: {
            // Texte partagé avec la grille (`DeleteFlow`), décidé par photo.
            Text(DeleteFlow.confirmationMessage(for: currentItem))
        }
        .sheet(isPresented: $showExport) {
            DocumentExporter(urls: [currentItem.url].compactMap { $0 }) { showExport = false }
        }
        .fullScreenCover(item: $duelContext) { context in
            DuelView(session: session, contenders: context.items) { applied in
                duelContext = nil
                // Tournoi appliqué : la pile est départagée, retour à la grille.
                if applied { dismiss() }
            }
        }
        .sheet(isPresented: $showAlbumSettings, onDismiss: { saveAfterAlbumSetup = false }) {
            AlbumSettingsView(
                session: session,
                // `confirmLabel` est un String brut : sans `String(localized:)`
                // les libellés partaient tels quels en anglais.
                confirmLabel: saveAfterAlbumSetup
                    ? (isLibrarySource
                        ? String(localized: "Ajouter à l'album")
                        : String(localized: "Enregistrer la photo"))
                    : String(localized: "OK")
            ) {
                let resume = saveAfterAlbumSetup
                saveAfterAlbumSetup = false
                showAlbumSettings = false
                if resume { performSaveCurrent() }
            }
        }
        .statusBarHidden(!showsChrome)
        // Jalons 7/8 : on peut arriver sur une page dont la cellule n'a
        // jamais été affichée (ouverture + swipes) → le viewer déclenche
        // aussi analyse et index EXIF de la photo courante (coût nul si déjà
        // en cache), puis résout le lieu pour la fiche (bonus GPS).
        .task(id: currentItem.id) {
            // Idée 18 — un clip n'a ni signaux Vision ni EXIF image ; seule
            // sa durée est chargée (pour la fiche et les badges).
            if currentItem.isVideo {
                if currentItem.videoDuration == nil, let url = currentItem.url {
                    currentItem.videoDuration = await VideoInfo.duration(of: url)
                }
                return
            }
            if currentItem.analysis == nil {
                currentItem.analysis = await VisionAnalyzer.shared.analysis(for: currentItem.backing)
            }
            if currentItem.exif == nil {
                currentItem.exif = await ExifIndexer.shared.exif(for: currentItem.backing)
            }
            if currentItem.place == nil,
               let latitude = currentItem.exif?.latitude,
               let longitude = currentItem.exif?.longitude {
                currentItem.place = await PlaceResolver.shared.place(
                    latitude: latitude,
                    longitude: longitude
                )
            }
        }
        .alert("Peliculle", isPresented: Binding(isPresenting: $saveError)) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        // Revue UX (UX4), même politique que la grille : succès en toast.
        .successToast(message: $successToast)
    }

    /// Capsule glass sous la barre : nom du fichier (tronqué au milieu pour
    /// garder l'extension lisible), position dans l'ensemble, compteur de
    /// gardées et **badges de statut** (enregistrée, décision, note, signaux
    /// d'analyse). Les badges vivaient en `ToolbarItem`, mais dès que la barre
    /// manquait de place le système les repliait dans un « ⋯ » inerte — ici
    /// ils ont la largeur de l'écran et se masquent au zoom avec le reste.
    private var photoHeader: some View {
        HStack(spacing: 8) {
            // Provenance de la photo courante (« où aller la retrouver ») :
            // type (icône) + nom du dossier / album. Toujours affichée.
            provenanceChip
            VStack(spacing: 1) {
                Text(currentItem.filename)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(headerDetail)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            // Le nom de fichier garde la priorité si le nom de source est long.
            .layoutPriority(1)
            if !activeBadges.isEmpty {
                HStack(spacing: 4) {
                    ForEach(activeBadges.prefix(2), id: \.self) { badge in
                        badgeView(badge)
                    }
                    if activeBadges.count > 2 {
                        overflowBadge(activeBadges.count - 2)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        // Scrim sombre renforcé en apparence claire : le texte blanc de la
        // capsule garde du contraste par-dessus une photo claire.
        .glassEffect(.regular.tint(.black.opacity(colorScheme == .dark ? 0.25 : 0.5)), in: .capsule)
        .frame(maxWidth: .infinity)
        // Revue UX (UX2) — le chrome plafonne aux premières tailles
        // d'accessibilité : au-delà, la capsule (nom + badges sur une ligne)
        // recouvrirait la photo — qui reste l'écran. Les contenus pleine
        // page (fiche ⓘ, grille, réglages), eux, suivent le réglage système.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    @ViewBuilder
    private func badgeView(_ badge: StatusBadgeKind) -> some View {
        switch badge {
        case .decision:
            DecisionBadge(decision: currentItem.decision, font: .footnote)
        case .saved:
            SavedBadge(font: .footnote)
        case .rating:
            RatingBadge(rating: currentItem.rating)
        }
    }

    /// « +n » : n badge(s) de plus que les deux affichés — même graphie que
    /// les capsules de statut (pile, vidéo, note).
    private func overflowBadge(_ count: Int) -> some View {
        Text("+\(count)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: .capsule)
            .accessibilityLabel(String(localized: "\(count) autre(s) statut(s)"))
    }

    /// Pastille de provenance de la photo courante : **icône** du support
    /// (elle distingue dossier/carte d'un album/photothèque) + **nom** de la
    /// source (`displayName` : nom du dossier, titre de l'album, période).
    /// Toujours visible — même en source simple : dans le viewer plein écran la
    /// pilule de la grille n'est plus là, et pour un asset (nom de fichier =
    /// date) c'est le seul repère du « d'où vient cette photo ». Le nom est
    /// tronqué au besoin pour laisser la place au nom de fichier.
    @ViewBuilder
    private var provenanceChip: some View {
        if let origin = currentItem.origin {
            HStack(spacing: 3) {
                Image(systemName: origin.icon)
                Text(origin.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.white.opacity(0.18), in: .capsule)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(String(localized: "Source : \(origin.displayName)"))
        }
    }

    private var headerDetail: String {
        var parts = ["\(index + 1) / \(items.count)"]
        if session.keeperCount > 0 {
            parts.append(String(localized: "\(session.keeperCount) gardée(s)"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Enregistrement à l'unité

    /// Enregistre la photo affichée dans la pellicule (source carte) ou
    /// l'ajoute à l'album de destination (source photothèque, Jalon 10),
    /// indépendamment du tri. Toujours l'icône d'action : « déjà
    /// enregistrée » est un **statut**, porté par le badge bleu côté gauche
    /// (voir `SavedBadge`), et ne bloque jamais une redite volontaire.
    private var saveButton: some View {
        Button {
            saveCurrent()
        } label: {
            if isSavingCurrent {
                ProgressView()
            } else {
                Image(systemName: isLibrarySource
                    ? "rectangle.stack.badge.plus"
                    : "square.and.arrow.down")
            }
        }
        .disabled(isSavingCurrent)
        .accessibilityLabel(isLibrarySource
            ? "Ajouter à l'album"
            : "Enregistrer dans la pellicule")
    }

    /// Premier enregistrement de la session : confirmer d'abord l'album de
    /// destination (même flux que la grille), puis ne plus jamais interrompre.
    private func saveCurrent() {
        guard session.albumConfirmed else {
            saveAfterAlbumSetup = true
            showAlbumSettings = true
            return
        }
        performSaveCurrent()
    }

    /// Flux partagé avec la grille (`SaveFlow`, revue qualité) : garde-fous
    /// album et espace disque, tâche d'arrière-plan, enregistrement,
    /// persistance, messages et notification hors écran — le viewer ne garde
    /// que sa présentation (spinner du bouton, toast/alerte, haptique).
    private func performSaveCurrent() {
        let item = currentItem
        isSavingCurrent = true
        Task {
            defer { isSavingCurrent = false }
            let outcome = await SaveFlow.run(
                [item],
                session: session,
                isAppActive: scenePhase == .active
            )
            if let message = outcome.errorMessage {
                saveError = message
            } else {
                successToast = outcome.successToast
                hapticTrigger += 1
            }
        }
    }

    // MARK: - Contrôles bas (mode tri)

    /// Revue UX (UX3) — le filmstrip s'efface quand il n'apporte rien (une
    /// seule page) et **cède la place à la rangée Élire/Duel** sur les piles
    /// quand la hauteur est comptée (paysage iPhone) : trois rangées de
    /// contrôles + la bande engloutiraient la photo, qui reste l'écran.
    private var showsFilmstrip: Bool {
        guard items.count > 1 else { return false }
        if isStack && cullMode && verticalSizeClass == .compact { return false }
        return true
    }

    /// Contrôles du mode tri (barre Garder/Rejeter, rangée de pile, note).
    /// L'entrée « Trier » du viewer épuré, elle, vit dans `sortEntryRow`,
    /// fondue à la ligne du filmstrip.
    private var bottomControls: some View {
        VStack(spacing: 12) {
            if isStack { stackRow }
            if showRatingRow { starRow }
            cullBar
                // Idée 21 — tip ① : ancré sur la barre de tri, la surface
                // où le swipe-haut agit.
                .popoverTip(SwipeKeepTip(), arrowEdge: .bottom)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 20)
    }

    /// Viewer épuré — la bande de progression et l'entrée « Trier » sur une
    /// seule ligne : le bouton n'a plus sa rangée dédiée, qui alourdissait le
    /// bas. Le filmstrip occupe **toute** la largeur et défile **sous** le
    /// bouton (posé en overlay au bord droit) plutôt que de s'arrêter avant
    /// lui — la photo courante, toujours recentrée, ne passe jamais dessous.
    /// Photo unique (pas de bande) : le bouton reste seul, centré.
    @ViewBuilder
    private var sortEntryRow: some View {
        if showsFilmstrip {
            FilmstripView(items: items, index: $index)
                .overlay(alignment: .trailing) {
                    trierButton
                        .padding(.trailing, 12)
                }
                .padding(.bottom, 20)
        } else {
            trierButton
                .padding(.bottom, 20)
        }
    }

    /// Entrée du mode tri, compacte (icône seule) pour tenir sur la ligne du
    /// filmstrip sans lui voler de largeur. Le libellé « Trier » reste porté
    /// par l'accessibilité. Même verre sombre prominent (44 pt, cible HIG) que
    /// les boutons ronds de la barre de tri.
    private var trierButton: some View {
        Button {
            cullMode = true
        } label: {
            Image(systemName: "checkmark.rectangle.stack")
                .font(.headline)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
        }
        // Verre neutre translucide (pas `.glassProminent` teinté, qui force le
        // contenu en blanc → invisible sur verre clair). Il s'adapte seul au
        // thème, contenu en `.primary`.
        .buttonStyle(.glass)
        .accessibilityLabel("Trier")
    }

    /// Actions de pile (idées 3/4), sur leur propre rangée pour ne jamais
    /// élargir la barre de tri : Élire = garder la photo affichée et rejeter
    /// le reste de la pile (un seul ↩︎) ; Duel = tournoi sur la pile.
    private var stackRow: some View {
        // Retour UX3 — pas de GlassEffectContainer : à 10 pt d'écart il fait
        // fusionner les verres voisins, et le mélange verre sombre + verres
        // colorés délavait la teinte en gris. Chaque bouton rend son verre
        // seul, comme la pastille « Trier » (la référence de rendu).
        HStack(spacing: 10) {
            Button {
                session.elect(currentItem, among: items)
                hapticTrigger += 1
                dismiss()
            } label: {
                Label("Élire cette photo", systemImage: "crown.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.glassProminent)
            .tint(.yellow)

            Button {
                duelContext = DuelContext(items: items)
            } label: {
                Label("Duel", systemImage: "rectangle.split.2x1")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.glass)
        }
    }

    private var starRow: some View {
        StarRatingView(rating: currentItem.rating) { newRating in
            session.setRating(newRating, for: [currentItem])
            hapticTrigger += 1
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        // Verre neutre adaptatif, comme les boutons de tri.
        .glassEffect(.regular, in: .capsule)
    }

    /// Quatre éléments (note, Rejeter, Garder, repli) — le ↩︎ vit dans la
    /// barre du haut avec les autres actions. Revue UX (UX2) — hiérarchie
    /// des cibles inversée : Garder/Rejeter, les deux boutons les plus
    /// martelés de l'app (souvent en mobilité), sont les **plus gros**
    /// (≥ 52 pt) ; les ronds secondaires font le minimum HIG (44 pt).
    /// Le tout tient sur 375 pt avec de la marge (~300 pt). Le repli est **à
    /// droite**, du même côté que la pastille « Trier » qui ouvre le mode :
    /// ouvrir et refermer se font sous le même pouce.
    private var cullBar: some View {
        // Retour UX3 — même raison que `stackRow` : sans container, chaque
        // verre garde sa teinte pleine au lieu de se fondre en gris.
        HStack(spacing: 10) {
            roundButton(
                symbol: showRatingRow ? "star.fill" : "star",
                label: showRatingRow ? "Masquer la note" : "Afficher la note",
                tint: showRatingRow ? .yellow : nil
            ) {
                showRatingRow.toggle()
            }

            decisionButton(.reject, title: "Rejeter", symbol: "xmark", tint: .red)
            decisionButton(.keep, title: "Garder", symbol: "checkmark", tint: .green)

            roundButton(
                symbol: "chevron.down",
                label: "Masquer le tri"
            ) {
                cullMode = false
            }
        }
    }

    /// Petit bouton circulaire glass (repli du mode tri, toggle de la note).
    /// `label` en `LocalizedStringKey` : les littéraux des call sites sont
    /// extraits vers le String Catalog (Jalon 11).
    private func roundButton(
        symbol: String,
        label: LocalizedStringKey,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint ?? .primary)
                // Revue UX (UX2) — 44 pt : le minimum HIG pour une cible.
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .accessibilityLabel(label)
    }

    /// Bouton de décision Liquid Glass : symbole au-dessus d'un libellé
    /// compact, dimensionné à son contenu (jamais tronqué), prominent quand la
    /// décision est active sur la photo courante.
    @ViewBuilder
    private func decisionButton(
        _ decision: CullDecision,
        title: LocalizedStringKey,
        symbol: String,
        tint: Color
    ) -> some View {
        let isActive = currentItem.decision == decision
        // Revue UX (UX2) — les actions principales du tri : symbole plus
        // gros, cible ≥ 52 pt de haut et 64 pt de large. « Fat fingers » :
        // on tape ces deux boutons des centaines de fois par session.
        let label = VStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.title3.weight(.bold))
            Text(title)
                .font(.caption2.weight(.semibold))
        }
        .lineLimit(1)
        .frame(minWidth: 64)
        // Rembourrage à la main : le style .plain n'apporte pas celui des
        // styles à verre — valeurs calées sur l'encombrement des voisins.
        .padding(.vertical, 14)
        .padding(.horizontal, 18)

        // Retour UX3 — le verre en **fond** du bouton, pas en style de
        // bouton : le libellé n'appartient alors pas au contenu du verre,
        // sa couleur rouge/verte n'est plus fondue dedans par la vibrance
        // (c'est elle qui délavait le fond en gris), et on garde le vrai
        // matériau et son contour, identiques aux boutons ronds voisins.
        if isActive {
            Button { decide(decision) } label: { label.foregroundStyle(.white) }
                .buttonStyle(.plain)
                .background {
                    Color.clear.glassEffect(.regular.tint(tint), in: .capsule)
                }
        } else {
            Button { decide(decision) } label: { label.foregroundStyle(tint) }
                .buttonStyle(.plain)
                .background {
                    // Verre neutre adaptatif : le libellé rouge/vert porte la
                    // couleur, le verre suit le thème (clair/sombre).
                    Color.clear.glassEffect(.regular, in: .capsule)
                }
        }
    }

    /// Toggle de la décision + retour visuel/haptique, puis avance **après le
    /// flash** (~0,35 s, via la tâche de flash) pour que le retour se lise
    /// sur la photo décidée. Remettre à « non triée » avance tout de suite
    /// (pas de flash).
    private func decide(_ decision: CullDecision) {
        let target: CullDecision = (currentItem.decision == decision) ? .undecided : decision
        session.setDecision(target, for: [currentItem])
        signalDecision(target)
        if target == .undecided {
            advance()
        } else {
            pendingAdvanceIndex = index
        }
    }

    /// Swipe vers le haut : garde la photo (sans toggle), flash, puis avance.
    private func keepAndAdvance(_ item: PhotoItem) {
        session.setDecision(.keep, for: [item])
        signalDecision(.keep)
        if item.id == currentItem.id { pendingAdvanceIndex = index }
    }

    /// Idée 13 — retour transitoire de décision : flash de bord + pastille
    /// (`DecisionFlashOverlay`) et haptique **différenciée** garder/rejeter.
    /// Remettre à « non triée » garde l'haptique neutre historique, sans flash.
    private func signalDecision(_ decision: CullDecision) {
        switch decision {
        case .keep:
            keepFeedback += 1
        case .reject:
            rejectFeedback += 1
        case .undecided:
            hapticTrigger += 1
            return
        }
        flashDecision = decision
        flashCount += 1
    }

    /// Avance **sans animation** : animer la sélection du `TabView` déclenche
    /// un défilement visuel de pages en cours de chargement (glitch connu).
    private func advance() {
        if index < items.count - 1 {
            index += 1
        }
    }

    // MARK: - Suppression

    /// Supprime la photo affichée de la carte (après confirmation) via le
    /// flux partagé (`DeleteFlow` retire aussi la photo de la session),
    /// retire sa page et reste sur place ; ferme le viewer s'il ne reste rien.
    private func deleteCurrent() {
        let item = currentItem
        Task {
            let outcome = await DeleteFlow.run([item], session: session)
            // Dialogue système refusé : un choix, pas un échec — rien à dire.
            guard !outcome.cancelled else { return }
            if let message = outcome.errorMessage {
                saveError = message
                return
            }
            if let position = items.firstIndex(of: item) {
                items.remove(at: position)
            }
            if items.isEmpty {
                dismiss()
                return
            }
            if index >= items.count {
                index = items.count - 1
            }
            hapticTrigger += 1
        }
    }
}
