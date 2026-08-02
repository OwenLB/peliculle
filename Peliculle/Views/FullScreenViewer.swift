import AVFoundation
import Photos
import SwiftUI
import TipKit
import UIKit

/// F3 + F4 + F5 + F9 — viewer plein écran paginé sur l'ensemble **affiché**
/// (respecte le filtre de la grille). Le défilement est porté par
/// `PhotoPager` (`UIPageViewController`) : geste continu au doigt, rubber-band
/// aux extrémités, snap à la vélocité — et **la même animation** quand
/// l'avance vient d'un bouton de tri ou du filmstrip. La transition d'entrée
/// (zoom hero) et le pull-to-dismiss sont apportés par
/// `.navigationTransition(.zoom:)` côté grille.
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
/// disponibles sur les boutons. L'avance après décision **fait glisser** la
/// page vers la suivante, sans délai : la confirmation est portée par un
/// overlay indépendant de la page (pastille) et par le liseré qui part avec la
/// photo décidée — la carte qui s'en va **est** l'accusé de réception. Les
/// voisines sont préchauffées (`prefetchNeighbors`), donc la page qui entre
/// glisse sur une vraie image.
struct FullScreenViewer: View {
    let session: CullSession
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
    /// Photo **sur laquelle** le liseré de décision se joue. On avance
    /// immédiatement après une décision : le liseré doit rester sur la photo
    /// décidée pendant qu'elle glisse hors de l'écran, pas se rejouer sur la
    /// suivante (qui n'a rien demandé).
    @State private var flashItemID: PhotoItem.ID?
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
    /// Vrai quand `saveError` vient d'un accès photothèque insuffisant
    /// (`SaveFlow.Outcome.offersSettingsShortcut`) : l'alerte propose alors
    /// Réglages plutôt qu'un simple OK. Sans rapport avec `DeleteFlow`, qui
    /// partage la même alerte mais jamais ce cas — remis à faux à son message.
    @State private var saveErrorOffersSettings = false
    /// Revue UX (UX4), aligné sur la grille par la factorisation `SaveFlow` :
    /// succès en toast qui s'efface seul, échec en alerte (`saveError`).
    @State private var successToast: String?
    /// Sheet de l'album de destination (idée 8bis). `saveAfterAlbumSetup`
    /// distingue la confirmation du premier enregistrement (on enchaîne sur
    /// la sauvegarde) du simple réglage via le menu ⋯.
    @State private var showAlbumSettings = false
    @State private var saveAfterAlbumSetup = false
    @State private var confirmDelete = false
    @State private var showExport = false
    /// Groupes de similaires (id → membres), transmis par la grille : alimente
    /// le badge ≈ cliquable du viewer et le tournoi qu'il ouvre.
    let similarGroups: [PhotoItem.ID: [PhotoItem]]
    /// Rang du lot de similaires (id → rang 0-based), transmis par la grille :
    /// le badge affiche le **même numéro de lot** qu'elle (« 2.10 »), sinon on
    /// ne saurait pas qu'on regarde le lot qu'on venait de repérer en grille.
    let similarRanks: [PhotoItem.ID: Int]
    /// Tournoi ouvert depuis le badge ≈ (sous-ensemble des sosies de la photo).
    @State private var duelContext: DuelContext?
    /// Préchauffage des pages voisines, **annulable** : un défilement rapide
    /// doit abandonner les décodages devenus inutiles au lieu de les empiler.
    @State private var prefetchTasks: [Task<Void, Never>] = []

    @AppStorage("cullModeEnabled") private var cullMode = false
    @AppStorage("ratingRowVisible") private var showRatingRow = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    /// Idée 23 — ② : un enregistrement qui se termine hors écran envoie son
    /// récap en notification (via `SaveFlow`).
    @Environment(\.scenePhase) private var scenePhase

    init(
        session: CullSession,
        items: [PhotoItem],
        startIndex: Int,
        similarGroups: [PhotoItem.ID: [PhotoItem]] = [:],
        similarRanks: [PhotoItem.ID: Int] = [:]
    ) {
        self.session = session
        self._items = State(initialValue: items)
        self._index = State(initialValue: startIndex)
        self.similarGroups = similarGroups
        self.similarRanks = similarRanks
    }

    private var currentItem: PhotoItem { items[index] }

    /// Sosies de la photo courante (≥ 2 pour être un vrai groupe), pour le
    /// badge ≈ et le tournoi.
    private var currentSimilars: [PhotoItem]? {
        guard let members = similarGroups[currentItem.id], members.count > 1 else { return nil }
        return members
    }

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
    ///
    /// Pas de badge « référence » : la couronne du gagnant vit dans le
    /// tournoi et son récap, pas ailleurs (voir `ThumbnailCell`). Une
    /// référence est de toute façon gardée, elle porte donc la coche verte.
    private enum StatusBadgeKind: Hashable {
        case decision
        case saved
        case rating
    }

    private var activeBadges: [StatusBadgeKind] {
        var badges: [StatusBadgeKind] = []
        if currentItem.decision != .undecided { badges.append(.decision) }
        if currentItem.savedToLibrary || currentItem.isLibraryBacked { badges.append(.saved) }
        if currentItem.rating > 0 { badges.append(.rating) }
        return badges
    }

    /// Le chrome (capsule de titre, contrôles du bas, barre de navigation,
    /// barre d'état) n'est visible qu'hors zoom **et** hors mode immersif.
    private var showsChrome: Bool { !isZoomed && !hudHidden }

    var body: some View {
        // Défilement natif (`PhotoPager` / `UIPageViewController`) : le geste
        // suit le doigt et snappe à la vélocité, et l'avance après décision
        // emprunte **exactement** la même animation en passant par le binding
        // `index`. Le pager reste maître de l'horizontal ; le vertical (donc
        // le pull-to-dismiss natif) lui échappe entièrement, ce qui était tout
        // le problème d'un `DragGesture` SwiftUI.
        //
        // Mode immersif : le pager déborde de la safe area pour que la photo
        // aille bord à bord. Hors immersif il la respecte, ce qui lui fait
        // aussi respecter l'inset des contrôles du bas (`safeAreaInset`) —
        // chaque page se cadre alors dans la zone qui lui reste.
        photoPager
            .ignoresSafeArea(edges: hudHidden ? .all : [])
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
        // Retrait du flash une fois joué. Il ne retarde plus rien : l'avance
        // a déjà eu lieu, le liseré part avec la photo décidée et la pastille
        // s'estompe par-dessus la suivante.
        .task(id: flashCount) {
            guard flashDecision != nil else { return }
            // Couvre le délai + la durée du fondu de `DecisionFlashBorder`
            // (0,15 + 0,45 s) : le retirer plus tôt le coupait avant la fin de
            // son animation.
            try? await Task.sleep(for: .seconds(0.65))
            guard !Task.isCancelled else { return }
            flashDecision = nil
            flashItemID = nil
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: hapticTrigger)
        .sensoryFeedback(.success, trigger: keepFeedback)
        .sensoryFeedback(.warning, trigger: rejectFeedback)
        .toolbar(showsChrome ? .visible : .hidden, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            // Badge ≈ des similaires : n'apparaît que si la photo courante a des
            // sosies dans le périmètre. Le toucher ouvre le tournoi
            // (`DuelView`) sur le sous-ensemble, comme depuis la grille.
            ToolbarItem(placement: .topBarLeading) {
                if let similars = currentSimilars {
                    // « lot.compte », comme en grille. Neutre ici (pas de
                    // teinte par lot) : au milieu des icônes monochromes de la
                    // barre (↩︎, ⋯, ⓘ…), une couleur qui tourne au fil des
                    // photos y détonnait plutôt qu'elle n'orientait.
                    let lot = (similarRanks[currentItem.id] ?? 0) + 1
                    Button {
                        duelContext = DuelContext(items: similars)
                    } label: {
                        Label("\(lot).\(similars.count)", systemImage: "square.on.square.dashed")
                    }
                    .tint(.primary)
                    .accessibilityLabel("Lot de similaires \(lot), \(similars.count) photos — départager")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Annuler la dernière action", systemImage: "arrow.uturn.backward") {
                    session.undo()
                    hapticTrigger += 1
                }
                .disabled(!session.canUndo)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    // Partager : les deux sources. Un fichier a une URL toute
                    // prête (`ShareLink` direct) ; un asset photothèque n'en a
                    // pas — l'item à partager se prépare de façon asynchrone
                    // (voir `shareCurrentLibraryItem`).
                    if let url = currentItem.url {
                        ShareLink(item: url) {
                            Label("Partager", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button {
                            Task { await shareCurrentLibraryItem() }
                        } label: {
                            Label("Partager", systemImage: "square.and.arrow.up")
                        }
                    }
                    // Export d'originaux vers Fichiers : réservé aux sources
                    // fichier — un asset photothèque n'a rien à « exporter »,
                    // il est déjà géré par l'app Photos.
                    if currentItem.url != nil {
                        Button {
                            showExport = true
                        } label: {
                            Label("Exporter vers Fichiers", systemImage: "folder")
                        }
                    }
                    // Pas d'entrée « Album » ici (retour Owen) : c'est un
                    // réglage de **session**, pas de cette photo — géré
                    // depuis la grille (⚙️ Réglages, ou la confirmation au
                    // premier enregistrement via `showAlbumSettings`, encore
                    // câblée plus bas).
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
        // Tournoi des sosies ouvert depuis le badge ≈ : mêmes règles que
        // depuis la grille (garde la championne, rejette les autres).
        .fullScreenCover(item: $duelContext) { context in
            DuelView(session: session, contenders: context.items) { _ in
                duelContext = nil
            }
        }
        .sheet(isPresented: $showExport) {
            DocumentExporter(urls: [currentItem.url].compactMap { $0 }) { showExport = false }
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
        // Préchauffe les pages voisines dès l'ouverture et à chaque changement
        // de page : le swipe (et l'avance après décision) glisse alors sur une
        // image déjà décodée.
        .onChange(of: index, initial: true) {
            prefetchNeighbors()
        }
        // Fermeture du viewer : rien à préchauffer pour un écran qu'on quitte.
        .onDisappear {
            prefetchTasks.forEach { $0.cancel() }
            prefetchTasks = []
        }
        .task(id: currentItem.id) {
            // Idée 18 — un clip n'a ni signaux Vision ni EXIF image ; seule
            // sa durée est chargée (pour la fiche et les badges).
            if currentItem.isVideo {
                if currentItem.videoDuration == nil {
                    currentItem.videoDuration = await VideoInfo.duration(of: currentItem.backing)
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
            if saveErrorOffersSettings {
                Button("Réglages") {
                    saveError = nil
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
            }
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
        // Revue UX (UX4), même politique que la grille : succès en toast.
        .successToast(message: $successToast)
    }

    /// Le pager lui-même. Le zoom lui coupe le défilement : pendant une
    /// inspection, le pan recadre l'image et ne doit pas tourner la page.
    private var photoPager: some View {
        PhotoPager(items: items, index: $index, pagingEnabled: !isZoomed) { item in
            photoPage(for: item)
        }
    }

    /// Une page du pager (photo ou vidéo). Le pager possède la page entière :
    /// une vidéo se parcourt donc au swipe comme une photo, alors que les
    /// anciens recognizers, posés sur la seule vue image, la laissaient sans
    /// navigation gestuelle.
    private func photoPage(for item: PhotoItem) -> some View {
        PhotoDetailImage(
            item: item,
            // Hors immersif, la photo devient une carte aux coins arrondis ; en
            // immersif elle repart bord à bord. Lié à `hudHidden`, pas au zoom.
            framed: !hudHidden,
            cornerRadius: 18,
            // La pilule d'en-tête flotte sur la zone photo : la carte se centre
            // sous elle tant qu'elle y tient, et ne passe derrière que pour
            // gagner de la hauteur (portrait).
            topInset: showsChrome ? headerHeight : 0,
            onZoomChange: { zoomed in
                // Idée 21 — tip ③ : éligible après le premier zoom manuel ; un
                // zoom suivant vaut geste accompli.
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
            },
            // Liseré de décision qui épouse la carte photo
            // (`DecisionFlashBorder`), porté par la **photo décidée** : il
            // reste sur elle pendant qu'elle glisse hors de l'écran.
            flash: item.id == flashItemID ? flashDecision : nil,
            flashID: flashCount
        )
        // Bord à bord en immersif (et photo) ; en mode carte on respecte la safe
        // area et l'inset des contrôles. Une vidéo respecte toujours la safe
        // area (barre AVKit au-dessus des contrôles).
        .ignoresSafeArea(edges: (item.isVideo || !hudHidden) ? [] : .all)
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
            SavedBadge(font: .footnote, native: currentItem.isLibraryBacked)
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
                saveErrorOffersSettings = outcome.offersSettingsShortcut
                saveError = message
            } else {
                successToast = outcome.successToast
                hapticTrigger += 1
            }
        }
    }

    // MARK: - Partage (source photothèque)

    /// Prépare l'item à partager pour un asset photothèque (`PhotoSharing`,
    /// partagé avec le menu contextuel de la grille), puis présente la
    /// feuille système.
    private func shareCurrentLibraryItem() async {
        let items = await PhotoSharing.libraryItems(for: currentItem)
        guard !items.isEmpty else { return }
        PhotoSharing.present(items)
    }

    // MARK: - Contrôles bas (mode tri)

    /// Revue UX (UX3) — le filmstrip s'efface quand il n'apporte rien (une
    /// seule page).
    private var showsFilmstrip: Bool {
        items.count > 1
    }

    /// Contrôles du mode tri (barre Garder/Rejeter, note). L'entrée « Trier »
    /// du viewer épuré, elle, vit dans `sortEntryRow`, fondue à la ligne du
    /// filmstrip.
    private var bottomControls: some View {
        VStack(spacing: 12) {
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
        // Retour UX3 — pas de GlassEffectContainer : à faible écart il fait
        // fusionner les verres voisins, et le mélange verre sombre + verres
        // colorés délave la teinte en gris. Chaque bouton rend son verre seul.
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
        // Revue UX (UX2) — toute la pastille est tappable, pas seulement le
        // glyphe : avec `.buttonStyle(.plain)` et le verre posé en fond (donc
        // hors du contenu du bouton), SwiftUI ne teste que les pixels opaques
        // du label. Sans cette forme, le rembourrage et la largeur mini
        // restaient morts au toucher — la cible réelle tombait bien sous les
        // 52 pt visés, d'où des boutons « durs à cliquer ». La capsule épouse
        // le verre de fond.
        .contentShape(.capsule)

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

    /// Toggle de la décision + retour visuel/haptique, puis avance **tout de
    /// suite**. Pas de délai : le liseré teinté part avec la photo décidée
    /// pendant qu'elle glisse, la pastille s'estompe par-dessus — la
    /// confirmation est portée par le mouvement, pas par une attente
    ///. Remettre à « non triée » avance aussi, sans flash.
    private func decide(_ decision: CullDecision) {
        let item = currentItem
        let target: CullDecision = (item.decision == decision) ? .undecided : decision
        session.setDecision(target, for: [item])
        signalDecision(target, on: item)
        advance()
    }

    /// Swipe vers le haut : garde la photo (sans toggle), flash, puis avance.
    private func keepAndAdvance(_ item: PhotoItem) {
        session.setDecision(.keep, for: [item])
        signalDecision(.keep, on: item)
        if item.id == currentItem.id { advance() }
    }

    /// Idée 13 — retour transitoire de décision : liseré autour de la photo
    /// décidée + pastille (`DecisionFlashOverlay`) et haptique **différenciée**
    /// garder/rejeter. Remettre à « non triée » garde l'haptique neutre
    /// historique, sans flash.
    private func signalDecision(_ decision: CullDecision, on item: PhotoItem) {
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
        flashItemID = item.id
        flashCount += 1
    }

    /// Avance d'une photo. Point d'entrée unique de l'avance : boutons de tri,
    /// swipe-haut « garder » et filmstrip le partagent — et comme le pager
    /// anime lui-même le changement d'`index`, c'est le **même** défilement
    /// que celui du geste horizontal.
    private func advance() {
        guard index < items.count - 1 else { return }
        index += 1
    }

    /// Préchauffe l'aperçu des pages **voisines** (biais avant : en tri on
    /// avance) pour que le défilement glisse sur une vraie image, pas sur un
    /// spinner. Résultats mis en cache (`ImageCache`) : la page voisine,
    /// quand on l'atteint, s'affiche sans temps de décodage. Vidéos exclues
    /// (le lecteur se monte à l'écran).
    ///
    /// Les tâches de la position précédente sont **annulées** : sur un
    /// défilement rapide, une photo dépassée n'a plus à être décodée, et
    /// `ThumbnailLoader` sait s'arrêter en cours de route. Sans ça, traverser
    /// cent photos lançait cent décodages 2048 px qui allaient tous au bout,
    /// volant le CPU à la page qu'on regarde vraiment.
    private func prefetchNeighbors() {
        prefetchTasks.forEach { $0.cancel() }
        prefetchTasks = []
        let lower = max(0, index - 1)
        let upper = min(items.count - 1, index + 3)
        guard lower <= upper else { return }
        for offset in lower...upper where offset != index {
            let neighbor = items[offset]
            guard !neighbor.isVideo else { continue }
            prefetchTasks.append(
                Task { _ = await ThumbnailLoader.load(item: neighbor, maxPixel: PhotoDetailImage.previewPixels) }
            )
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
                saveErrorOffersSettings = false
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

