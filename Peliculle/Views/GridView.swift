import SwiftUI
import TipKit
import UIKit

/// Photographie de la liste filtrée au moment de l'ouverture du viewer : si le
/// viewer naviguait sur `filteredItems` en direct, une décision prise avec un
/// filtre actif (ex. « Non triées ») retirerait la photo de la liste et ferait
/// sauter les pages du pager en pleine session.
struct ViewerContext: Hashable, Identifiable {
    let start: PhotoItem
    let items: [PhotoItem]
    /// Vrai quand le viewer est scopé à une **pile de rafale** (idée 3) :
    /// active les actions Élire / Duel.
    var isStack = false

    var id: PhotoItem.ID { start.id }
}

/// F2 — grille de miniatures, avec filtres **format** (F8), **note** (F10) et
/// **état de tri**. Tap → viewer plein écran avec transition zoom hero native.
/// Un mode **sélection** façon Photos.app permet d'enregistrer n'importe quel
/// sous-ensemble dans la pellicule, indépendamment du keep/reject.
///
/// Jalon 10 — la grille est **agnostique de la source** (dossier, album,
/// photothèque) : mêmes filtres, tri, sélection, viewer. Ce qui change :
/// le bouton **Source** (conscient de la source courante, avec les albums
/// récents), le titre/sous-titre d'orientation, et la couche destination
/// (copier dans la pellicule ↔ ajouter à l'album, supprimer de la carte ↔
/// de la photothèque, export fichiers réservé à la carte).
struct GridView: View {
    let session: CullSession
    var recentAlbums: [RecentAlbum] = []
    var recentFolders: [RecentFolder] = []
    var onChangeSource: (SourceRequest) -> Void

    /// Contexte d'ouverture du viewer. Le snapshot des items voyage **dans**
    /// l'item de navigation : `navigationDestination(item:)` peut évaluer sa
    /// closure avec un état de vue périmé, donc un `@State` posé « en même
    /// temps » que la sélection (ex. un tableau séparé) peut y être vu vide →
    /// crash `items[index]`. Seul le paramètre débalé est toujours à jour.
    @State private var viewerContext: ViewerContext?
    /// L'état complet des filtres (revue qualité) : une seule valeur
    /// (`GridFilters`), un seul binding vers la sheet Filtres.
    @State private var filters = GridFilters()
    /// Membres de l'album de destination (`localIdentifier`), sondés en réel
    /// (Batch H5) : c'est la vérité du filtre « dans l'album » pour les sources
    /// photothèque. Vide hors source photothèque ou destination « aucun album ».
    /// Rafraîchi par `.task(id:)` (titre d'album) et après chaque enregistrement.
    @State private var destinationAlbumIDs: Set<String> = []
    /// Idée 12 — sections par jour de prise de vue dans la grille.
    @AppStorage("groupByDay") private var groupByDay = false
    /// Revue UX (UX5) — les filtres et les réglages vivent en sheets, plus
    /// en menus de toolbar (voir `FilterSheet` / `SettingsSheet`).
    @State private var showFilters = false
    @State private var showSettings = false
    /// Jalon 9 — tri rapide (idée 14) et Mode Voyage (idée 15). Le périmètre
    /// choisi transite par `pendingQuickCull` : présenter le fullScreenCover
    /// seulement à la fermeture de la sheet de périmètre évite le conflit de
    /// présentations simultanées.
    @State private var showQuickCullSetup = false
    @State private var pendingQuickCull: [PhotoItem]?
    @State private var quickCullContext: QuickCullContext?
    @State private var showTripSettings = false
    @AppStorage("gridSort") private var sort: PhotoSort = .date
    @AppStorage("gridSortAscending") private var sortAscending = true
    /// Idée 3 — groupement de rafales : seuil en secondes (0 = désactivé,
    /// réglé dans ⚙️) et toggle rapide dans le menu filtres.
    @AppStorage("burstThreshold") private var burstThreshold = 1.0
    @AppStorage("burstGrouping") private var groupBursts = true

    @State private var isSelecting = false
    @State private var selection = Set<PhotoItem.ID>()

    @State private var saveProgress: (done: Int, total: Int)?
    @State private var saveMessage: String?
    /// Revue UX (UX4) — les **succès** passent par un toast qui s'efface
    /// seul (`successToast(message:)`) ; `saveMessage` ne porte plus que
    /// les erreurs, qui restent en alertes.
    @State private var successToast: String?
    /// Sheet de l'album de destination (idée 8bis). `pendingSave` porte le
    /// lot en attente quand la sheet sert de confirmation au **premier**
    /// enregistrement de la session ; nil quand elle sert de simple réglage.
    @State private var showAlbumSettings = false
    @State private var pendingSave: [PhotoItem]?
    @State private var duelContext: DuelContext?
    @State private var confirmDelete = false
    @State private var confirmDeleteRejected = false
    /// Photo visée par le « Supprimer » du menu contextuel (Revue UX, UX1),
    /// en attente de confirmation. La donnée voyage dans l'état présentant
    /// l'alerte (`presenting:`) — même leçon que `ViewerContext`.
    @State private var contextDeleteItem: PhotoItem?

    /// Idée 23 — ② : ne notifier la fin d'un enregistrement que si l'app
    /// n'est plus à l'écran quand il se termine.
    @Environment(\.scenePhase) private var scenePhase
    @State private var showExport = false
    @Namespace private var zoomNamespace

    /// Bords de défilement de la grille (haut/bas), lus depuis la géométrie de
    /// défilement : pilotent la contraction du bouton Tri rapide (plein
    /// libellé en tête de liste, icône seule au défilement) et le masquage
    /// contextuel des chevrons de saut.
    @State private var scrollEdges = ScrollEdges()

    /// Position de la grille vis-à-vis de ses bords. Défaut au lancement :
    /// tête de liste visible (Tri rapide déplié, seul le chevron ▼ offert) ;
    /// la première passe de géométrie corrige (grille courte ⇒ les deux bords).
    private struct ScrollEdges: Equatable {
        var atTop = true
        var atBottom = false
    }

    /// Ancres invisibles posées en tête et pied de grille, cibles des sauts.
    private enum GridAnchor: Hashable { case top, bottom }

    private let quickCullIcon = "rectangle.portrait.on.rectangle.portrait.angled"

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 3)]

    // MARK: - Dérivés du rendu (une photographie par passe)

    /// Dérivés coûteux du rendu — filtre + tri O(n log n), piles de rafales,
    /// sections par jour, listes des pickers. Recalculés **une fois** par
    /// passe de `body` (`refreshDerived`, appelé en tête) puis relus tels
    /// quels partout : chaque dérivé était une computed property référencée
    /// à plusieurs endroits du rendu, et chaque lecture refaisait tout le
    /// travail — sur 10 000 photos, plusieurs tris complets par rendu.
    ///
    /// Classe volontairement **non observée** : le remplir pendant le rendu
    /// n'invalide rien (muter un `@State` pendant `body` est interdit, muter
    /// le contenu d'une classe stable ne l'est pas). Les closures d'action
    /// (taps, boutons) lisent aussi cette photographie : elle reflète le
    /// dernier rendu, donc exactement ce que l'utilisateur voit à l'écran.
    private final class RenderDerived {
        var filtered: [PhotoItem] = []
        var entries: [GridEntry] = []
        var sections: [DaySection] = []
        var availableFormats: [FormatFilter] = [.all]
        var cameras: [String] = []
        var lenses: [String] = []
        var hasGeolocated = false
    }

    @State private var derived = RenderDerived()

    /// Recalcule la photographie du rendu. Les lectures d'observables
    /// (items, décisions, filtres, tri) se font **pendant** le rendu :
    /// l'invalidation SwiftUI reste entièrement automatique.
    private func refreshDerived() {
        let filtered = filteredItems
        derived.filtered = filtered
        derived.entries = entries(from: filtered)
        derived.sections = groupByDay ? sections(from: derived.entries) : []
        derived.availableFormats = FormatFilter.available(for: session.items)
        derived.cameras = Set(session.items.compactMap { $0.exif?.camera }).sorted()
        derived.lenses = Set(session.items.compactMap { $0.exif?.lens }).sorted()
        derived.hasGeolocated = session.items.contains { $0.exif?.hasCoordinate == true }
    }

    private func matchesFilter(_ item: PhotoItem) -> Bool {
        // Voyage actif : il fait autorité sur les dates, le filtre Du/Au est
        // inerte (affiché verrouillé dans le menu filtres) — `GridFilters`
        // applique cette règle via `tripActive`.
        session.tripMatches(item)
            && filters.matches(
                item,
                isSaved: isSaved(item),
                tripActive: session.trip.isActive
            )
    }

    /// Drapeau « déjà rangée » pour le filtre `SavedFilter`, au sens de la
    /// source de la photo (Batch H5) : pour un asset photothèque, appartenance
    /// **réelle** à l'album de destination (`destinationAlbumIDs`) ; pour un
    /// fichier carte, le marquage « téléchargé » (que la réconciliation garde
    /// honnête). Un asset sans album de destination sondé n'est jamais « rangé ».
    private func isSaved(_ item: PhotoItem) -> Bool {
        if item.isLibraryBacked {
            guard let id = item.asset?.localIdentifier else { return false }
            return destinationAlbumIDs.contains(id)
        }
        return item.savedToLibrary
    }

    /// Titre de l'album de destination à sonder pour le filtre « dans l'album »,
    /// ou nil quand la question ne se pose pas (aucune source photothèque, ou
    /// destination « aucun album »). Sert de clé au `.task(id:)` de rafraîchi.
    private var membershipAlbumTitle: String? {
        guard session.hasLibrarySource else { return nil }
        return session.albumDestination.resolvedTitle
    }

    /// Sonde (ou vide) l'appartenance à l'album de destination. Silencieux sans
    /// accès lecture : le filtre retombe alors sur « hors de l'album ».
    private func refreshDestinationAlbumIDs() async {
        guard let title = membershipAlbumTitle, PhotoLibrarySource.hasReadAccess else {
            destinationAlbumIDs = []
            return
        }
        destinationAlbumIDs = await PhotoLibrarySource.assetIDs(inAlbumTitled: title)
    }

    /// Exécute une passe de fond en appliquant les résultats **par lots**
    /// (~200 photos ou ~1 s) plutôt qu'item par item : chaque écriture sur un
    /// `PhotoItem` observé invalide toute la grille, et une invalidation par
    /// photo saturait l'UI sur une grande photothèque (grille figée, menus
    /// qui se refermaient d'eux-mêmes). Un lot appliqué d'un trait sur le
    /// main actor = une seule invalidation.
    ///
    /// `nonisolated` est **vital** : la boucle doit itérer hors du main
    /// actor. Isolée à la vue, chaque `await` reprendrait sur le main thread —
    /// anodin quand le calcul est lent, mais un cache disque chaud ou un nil
    /// immédiat (photo iCloud non locale, passe sans réseau) en fait une
    /// boucle serrée de 10 000 reprises qui gèle toute l'UI au lancement.
    /// Seule l'application des lots revient sur le main actor.
    /// Générique sur l'élément (pas seulement `PhotoItem`) : la passe des
    /// lieux embarque ses coordonnées, extraites sur le main actor **avant**
    /// la boucle — `compute` tourne hors main actor et ne peut pas lire
    /// l'état mutable des items (seul `apply` y revient).
    nonisolated private func runBatchedPass<Element: Sendable, Value: Sendable>(
        over items: [Element],
        compute: @Sendable (Element) async -> Value?,
        apply: @escaping @MainActor @Sendable (Element, Value) -> Void
    ) async {
        var pending: [(Element, Value)] = []
        var lastFlush = ContinuousClock.now
        func flush() async {
            // UX5 : le `MenuGate` qui suspendait ici les lots pendant qu'un
            // menu était ouvert a disparu avec le menu Filtres — les filtres
            // vivent en sheet (`FilterSheet`), qu'une invalidation de la
            // grille ne referme pas.
            let batch = pending
            pending.removeAll()
            lastFlush = .now
            guard !batch.isEmpty else { return }
            await MainActor.run {
                for (item, value) in batch { apply(item, value) }
            }
        }
        for item in items {
            // Annulation (filtre relâché) : les résultats déjà calculés sont
            // appliqués quand même — jamais de travail jeté.
            guard !Task.isCancelled else { break }
            if let value = await compute(item) {
                pending.append((item, value))
            }
            if pending.count >= 200 || lastFlush.duration(to: .now) >= .seconds(1) {
                await flush()
            }
        }
        await flush()
    }

    /// Base du tri rapide : le périmètre voyage dans l'ordre d'affichage,
    /// **sans** les filtres de la grille (le tri rapide a son propre
    /// sélecteur de périmètre).
    private var quickCullBase: [PhotoItem] {
        session.items
            .filter { session.tripMatches($0) }
            .sorted { sort.areInOrder($0, $1, ascending: sortAscending) }
    }

    /// Périmètre « Aujourd'hui » du tri rapide — partagé entre le sélecteur
    /// et le tap de la notification ③ (passe du soir).
    private var quickCullTodayItems: [PhotoItem] {
        quickCullBase.filter { item in
            item.captureDate.map { Calendar.current.isDateInToday($0) } ?? false
        }
    }

    /// Reste-t-il des photos non triées dans le périmètre voyage ? Le Tri
    /// rapide n'existe que pour les reprendre : tout trié ⇒ bouton masqué.
    /// Évite le tri de `quickCullBase` (inutile pour un simple test).
    private var hasUntriaged: Bool {
        session.items.contains { session.tripMatches($0) && $0.decision == .undecided }
    }

    private var filteredItems: [PhotoItem] {
        session.items
            .filter(matchesFilter)
            .sorted { sort.areInOrder($0, $1, ascending: sortAscending) }
    }

    // MARK: - Piles de rafales (idée 3)

    /// Une case de la grille : photo isolée, ou pile de rafale repliée sur sa
    /// couverture. `members` = la pile entière (le viewer scopé la reçoit
    /// telle quelle), `visible` = les membres passant les filtres (cible de
    /// la sélection).
    private enum GridEntry: Identifiable {
        case photo(PhotoItem)
        case stack(cover: PhotoItem, members: [PhotoItem], visible: [PhotoItem])

        var id: PhotoItem.ID {
            switch self {
            case .photo(let item): item.id
            case .stack(_, let members, _): members[0].id
            }
        }
    }

    /// Construit les cases de la grille depuis la liste filtrée — appelé une
    /// fois par rendu (`refreshDerived`), jamais en lecture directe.
    private func entries(from filtered: [PhotoItem]) -> [GridEntry] {
        guard groupBursts else { return filtered.map { .photo($0) } }
        // Piles détectées sur la session entière : un filtre qui masque des
        // membres ne dissout pas la pile.
        return BurstGrouper.entries(in: filtered, among: session.items, threshold: burstThreshold)
            .map { entry -> GridEntry in
                switch entry {
                case .single(let item):
                    return .photo(item)
                case .stack(let members, let anchor):
                    let visible = members.filter(matchesFilter)
                    // Couverture : la gardée si la pile est déjà départagée,
                    // sinon la première visible dans l'ordre de tri courant.
                    let cover = visible.first { $0.decision == .keep } ?? anchor
                    return .stack(cover: cover, members: members, visible: visible)
                }
            }
    }

    private var isFiltering: Bool {
        filters.isActive(tripActive: session.trip.isActive)
    }

    /// Vrai quand le tri exige les signaux d'analyse de **toute** la session
    /// (l'analyse paresseuse ne couvre que les cellules vues).
    private var needsSessionAnalysis: Bool {
        sort == .aesthetic
    }

    /// Même logique pour l'EXIF (Jalon 8) : tri par prise de vue, sections
    /// par jour ou filtre EXIF actif → il faut l'index de toute la session.
    private var needsSessionExif: Bool {
        groupByDay || sort == .captureDate || filters.isExifFiltering
    }

    // MARK: - Sections par jour (idée 12)

    /// Une section de grille : un jour de prise de vue (nil = date inconnue,
    /// toujours en fin), ses cases, et le lieu dominant si le GPS l'a donné.
    private struct DaySection: Identifiable {
        let day: Date?
        let entries: [GridEntry]
        let place: String?
        var id: TimeInterval { day?.timeIntervalSinceReferenceDate ?? .greatestFiniteMagnitude }
    }

    /// Groupe les cases par jour de prise de vue — appelé une fois par rendu
    /// (`refreshDerived`), seulement quand le regroupement est actif.
    private func sections(from entries: [GridEntry]) -> [DaySection] {
        let calendar = Calendar.current
        var days: [Date?] = []
        var groups: [Date?: [GridEntry]] = [:]
        for entry in entries {
            let day = representative(of: entry).captureDate.map { calendar.startOfDay(for: $0) }
            if groups[day] == nil { days.append(day) }
            groups[day, default: []].append(entry)
        }
        // Jours ordonnés selon le sens du tri quand il est chronologique,
        // sinon du plus récent au plus ancien ; « date inconnue » à la fin.
        let descending = (sort == .captureDate || sort == .date) ? !sortAscending : true
        return days
            .map { day in
                let entries = groups[day] ?? []
                return DaySection(day: day, entries: entries, place: dominantPlace(of: entries))
            }
            .sorted { a, b in
                switch (a.day, b.day) {
                case (nil, _): return false
                case (_, nil): return true
                case let (dayA?, dayB?): return descending ? dayA > dayB : dayA < dayB
                }
            }
    }

    private func representative(of entry: GridEntry) -> PhotoItem {
        switch entry {
        case .photo(let item): return item
        case .stack(let cover, _, _): return cover
        }
    }

    /// Lieu le plus fréquent parmi les photos géocodées de la section
    /// (en-têtes par lieu, bonus GPS) — nil si rien n'est résolu.
    private func dominantPlace(of entries: [GridEntry]) -> String? {
        var counts: [String: Int] = [:]
        for entry in entries {
            if let place = representative(of: entry).place {
                counts[place, default: 0] += 1
            }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    /// Ordre d'affichage réel : celui des sections quand le regroupement par
    /// jour est actif, sinon l'ordre de tri brut. C'est **cet** ordre que le
    /// viewer doit paginer pour que gauche/droite suivent l'écran — la
    /// photographie du dernier rendu est donc exactement la bonne.
    private var displayedItems: [PhotoItem] {
        guard groupByDay else { return derived.filtered }
        return derived.sections.flatMap { section in
            section.entries.flatMap { entry -> [PhotoItem] in
                switch entry {
                case .photo(let item): return [item]
                case .stack(_, _, let visible): return visible
                }
            }
        }
    }

    private var selectedItems: [PhotoItem] {
        derived.filtered.filter { selection.contains($0.id) }
    }

    private var isSaving: Bool { saveProgress != nil }

    /// Vrai quand **toutes** les sources sont adossées à la photothèque (Jalon
    /// 10) : garder = ajouter à l'album (rien à copier ni exporter), supprimer
    /// = supprimer de la photothèque. En combiné (carte + photothèque), c'est
    /// faux et l'UI décide par photo (`item.isLibraryBacked`).
    private var isLibrarySource: Bool { session.isLibraryOnly }

    /// Avertissement de suppression en lot — texte partagé avec le viewer
    /// (`DeleteFlow.confirmationMessage`).
    private var deleteWarning: String {
        DeleteFlow.confirmationMessage(session: session)
    }

    /// `body` en trois tronçons (`gridChrome` → `presentations` → `body`) :
    /// la chaîne complète de modificateurs dépasse ce que le type-checker
    /// accepte en une seule expression.
    private var gridChrome: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if derived.filtered.isEmpty {
                    emptyState
                } else {
                    // Ancres invisibles des sauts haut/bas (chevrons) : posées
                    // hors de la grille paresseuse pour rester des cibles
                    // stables quelle que soit la réalisation des cellules.
                    Color.clear.frame(height: 0).id(GridAnchor.top)
                    LazyVGrid(
                        columns: columns,
                        spacing: 3,
                        pinnedViews: groupByDay ? [.sectionHeaders] : []
                    ) {
                        if groupByDay {
                            ForEach(derived.sections) { section in
                                Section {
                                    ForEach(section.entries) { entry in
                                        cell(for: entry)
                                    }
                                } header: {
                                    sectionHeader(section)
                                }
                            }
                        } else {
                            ForEach(derived.entries) { entry in
                                cell(for: entry)
                            }
                        }
                    }
                    .padding(.horizontal, 3)
                    Color.clear.frame(height: 0).id(GridAnchor.bottom)
                }
            }
            // Suivi des bords de défilement : `atTop` déplie le Tri rapide et
            // masque le chevron ▲ ; `atBottom` masque le chevron ▼. Grille qui
            // tient à l'écran ⇒ les deux vrais, les deux chevrons masqués.
            // On lit `visibleRect` (les bounds déjà rognés des insets) plutôt
            // que l'offset brut : les bords tombent en coordonnées de contenu,
            // 0 en tête et `contentSize.height` en pied, sans arithmétique
            // d'insets (une addition de trop y masquait le chevron ▼ en bas).
            .onScrollGeometryChange(for: ScrollEdges.self) { geo in
                let atTop = geo.visibleRect.minY <= 4
                let atBottom = geo.visibleRect.maxY >= geo.contentSize.height - 4
                return ScrollEdges(atTop: atTop, atBottom: atBottom)
            } action: { _, edges in
                scrollEdges = edges
            }
            // Hors sélection, l'orientation vit dans la pilule flottante (le
            // titre inline est écrasé par les boutons de barre sur iPhone) ; le
            // mode sélection reprend le titre pour son compteur.
            .navigationTitle(isSelecting ? selectionTitle : "")
            // Pilule d'orientation : où l'on trie et combien de photos la grille
            // montre réellement. Flottante sous la barre, la grille défile
            // dessous.
            .overlay(alignment: .top) {
                if !isSelecting {
                    statusPill
                }
            }
            // Idée 14 — le Tri rapide en bas à gauche : action délibérée, hors
            // du pouce qui défile. Masqué en mode sélection (la bottom bar
            // prend la place).
            .overlay(alignment: .bottomLeading) {
                if !isSelecting, !derived.filtered.isEmpty, hasUntriaged {
                    quickCullButton
                }
            }
            // Sauts haut/bas en bas à droite : sous le pouce qui défile déjà.
            .overlay(alignment: .bottomTrailing) {
                if !isSelecting, !derived.filtered.isEmpty {
                    scrollChevrons(proxy)
                }
            }
            // Idée 21 — le tip « Tri rapide » ne vaut qu'avec un vrai lot.
            .onChange(of: derived.filtered.count, initial: true) { _, count in
                QuickCullTip.photoCount = count
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(isSelecting)
            .toolbar { toolbarContent }
            .animation(.snappy(duration: 0.2), value: isSelecting)
            .overlay {
                if let saveProgress {
                    ProgressView(
                        "Enregistrement… \(saveProgress.done) / \(saveProgress.total)"
                    )
                    .padding(24)
                    .background(.regularMaterial, in: .rect(cornerRadius: 16))
                }
            }
        }
    }

    /// Bouton Tri rapide (idée 14), coin bas-gauche et pendant de la pastille
    /// « Trier » du viewer. Plein libellé en tête de liste (découverte), se
    /// contracte en icône seule au défilement pour libérer une rangée de
    /// vignettes. Le tip ② s'y ancre.
    private var quickCullButton: some View {
        Button {
            QuickCullTip().invalidate(reason: .actionPerformed)
            showQuickCullSetup = true
        } label: {
            if scrollEdges.atTop {
                Label("Tri rapide", systemImage: quickCullIcon)
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            } else {
                Image(systemName: quickCullIcon)
                    .font(.headline)
                    .padding(12)
            }
        }
        .buttonStyle(.glass)
        // Idée 21 — tip ② : la passe en lot, dès que la grille contient un
        // vrai travail de tri (règle ≥ 20 photos).
        .popoverTip(QuickCullTip(), arrowEdge: .bottom)
        .padding(.leading, 16)
        .padding(.bottom, 12)
        .animation(.snappy(duration: 0.2), value: scrollEdges.atTop)
    }

    /// Chevrons de saut haut/bas, coin bas-droite. Chacun s'efface quand il
    /// n'a plus d'objet — ▲ masqué en tête, ▼ masqué en pied.
    private func scrollChevrons(_ proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 10) {
            if !scrollEdges.atTop {
                Button {
                    withAnimation(.snappy) { proxy.scrollTo(GridAnchor.top, anchor: .top) }
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.headline)
                        .padding(12)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Aller en haut")
            }
            if !scrollEdges.atBottom {
                Button {
                    withAnimation(.snappy) { proxy.scrollTo(GridAnchor.bottom, anchor: .bottom) }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.headline)
                        .padding(12)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Aller en bas")
            }
        }
        .padding(.trailing, 16)
        .padding(.bottom, 12)
        .animation(.snappy(duration: 0.2), value: scrollEdges)
    }

    /// Deuxième tronçon : viewer, duel, alertes et sheets d'enregistrement.
    private var presentations: some View {
        gridChrome
        .navigationDestination(item: $viewerContext) { context in
            FullScreenViewer(
                session: session,
                items: context.items,
                startIndex: context.items.firstIndex(of: context.start) ?? 0,
                isStack: context.isStack
            )
            .navigationTransition(.zoom(sourceID: context.start.id, in: zoomNamespace))
        }
        .fullScreenCover(item: $duelContext) { context in
            DuelView(session: session, contenders: context.items) { applied in
                duelContext = nil
                if applied { exitSelection() }
            }
        }
        .alert("Peliculle", isPresented: Binding(isPresenting: $saveMessage)) {
            Button("OK", role: .cancel) { saveMessage = nil }
        } message: {
            Text(saveMessage ?? "")
        }
        // Revue UX (UX4) — le récap d'un enregistrement réussi ne mérite pas
        // une alerte : capsule discrète qui descend du haut et s'efface.
        .successToast(message: $successToast)
        // Alertes centrées (façon demande d'autorisation), pas de sheet du bas.
        .alert("Supprimer \(selection.count) photo(s) ?", isPresented: $confirmDelete) {
            Button("Annuler", role: .cancel) {}
            Button("Supprimer", role: .destructive) {
                Task { await deleteSelection() }
            }
        } message: {
            Text(deleteWarning)
        }
        .alert("Supprimer les \(session.rejected.count) rejetées ?", isPresented: $confirmDeleteRejected) {
            Button("Annuler", role: .cancel) {}
            Button("Supprimer", role: .destructive) {
                Task { await deleteRejected() }
            }
        } message: {
            Text(deleteWarning)
        }
        // Suppression à l'unité depuis le menu contextuel (Revue UX, UX1) —
        // même formulation que le viewer, le nom du fichier dans le message.
        .alert(
            "Supprimer cette photo ?",
            isPresented: Binding(
                get: { contextDeleteItem != nil },
                set: { if !$0 { contextDeleteItem = nil } }
            ),
            presenting: contextDeleteItem
        ) { item in
            Button("Annuler", role: .cancel) {}
            Button("Supprimer", role: .destructive) {
                Task { await deleteItems([item]) }
            }
        } message: { item in
            // Texte partagé avec le viewer, décidé **par photo** (correct en
            // session combinée).
            Text(DeleteFlow.confirmationMessage(for: item))
        }
        .sheet(isPresented: $showExport) {
            DocumentExporter(urls: selectedItems.compactMap(\.url)) { showExport = false }
        }
        .sheet(isPresented: $showAlbumSettings, onDismiss: { pendingSave = nil }) {
            AlbumSettingsView(
                session: session,
                confirmLabel: pendingSave.map { items -> String in
                    if isLibrarySource {
                        return String(localized: "Ajouter \(items.count) photo(s) à l'album")
                    }
                    // Idée 20 — le poids du lot est annoncé avant de lancer.
                    if let size = SavePreflight.formattedTotal(of: items) {
                        return String(localized: "Enregistrer \(items.count) photo(s) · \(size)")
                    }
                    return String(localized: "Enregistrer \(items.count) photo(s)")
                } ?? String(localized: "OK")
            ) {
                let items = pendingSave
                pendingSave = nil
                showAlbumSettings = false
                if let items {
                    Task { await performSave(items) }
                }
            }
        }
    }

    var body: some View {
        // Une photographie des dérivés par rendu — tout ce qui suit
        // (grille, toolbar, menus) lit `derived` sans jamais recalculer.
        let _ = refreshDerived()
        presentations
        // Jalon 7 : filtrer ou trier par signal exige les résultats de toute
        // la session → passe de fond séquentielle en priorité basse, annulée
        // dès que la demande retombe (le `.task(id:)` redémarre à chaque
        // changement de clé). La grille se remplit/réordonne au fil de l'eau,
        // par lots (`runBatchedPass`). Passe **sans réseau** : une photo
        // iCloud absente en local est sautée (analysée plus tard, à
        // l'affichage), jamais téléchargée — 10 000 photos ne doivent jamais
        // devenir 10 000 téléchargements.
        .task(id: needsSessionAnalysis) {
            guard needsSessionAnalysis else { return }
            // Idée 18 — pas de signaux Vision sur une vidéo.
            await runBatchedPass(
                over: session.items.filter { $0.analysis == nil && !$0.isVideo },
                compute: { await VisionAnalyzer.shared.analysis(for: $0.backing, allowNetwork: false) },
                apply: { $0.analysis = $1 }
            )
        }
        // Jalon 8 : même passe de fond pour l'index EXIF (tri par prise de
        // vue, sections par jour, filtres EXIF) — sans objet sur la
        // photothèque, dont les items naissent l'EXIF rempli. Les lieux sont
        // résolus après l'index (en-têtes par lieu) — une requête par case
        // d'1 km, en cache.
        .task(id: needsSessionExif) {
            guard needsSessionExif else { return }
            // Idée 18 — un clip n'a pas d'EXIF image : sa date de tri est la
            // date de fichier (`captureDate` s'y replie déjà).
            await runBatchedPass(
                over: session.items.filter { $0.exif == nil && !$0.isVideo },
                compute: { await ExifIndexer.shared.exif(for: $0.backing) },
                apply: { $0.exif = $1 }
            )
            guard groupByDay else { return }
            // Coordonnées extraites ici (main actor) : la boucle de fond ne
            // reçoit que des valeurs, jamais l'état mutable des items.
            let located = session.items
                .filter { $0.place == nil }
                .compactMap { item -> (item: PhotoItem, latitude: Double, longitude: Double)? in
                    guard let latitude = item.exif?.latitude,
                          let longitude = item.exif?.longitude else { return nil }
                    return (item, latitude, longitude)
                }
            await runBatchedPass(
                over: located,
                compute: {
                    await PlaceResolver.shared.place(
                        latitude: $0.latitude,
                        longitude: $0.longitude
                    )
                },
                apply: { $0.item.place = $1 }
            )
        }
        // Batch H5 — appartenance à l'album de destination (filtre « dans
        // l'album »). Clé = titre d'album : re-sonde à l'ouverture et à chaque
        // changement de destination. Après un enregistrement, `performSave`
        // rafraîchit en plus (les ajouts viennent d'y entrer).
        .task(id: membershipAlbumTitle) {
            await refreshDestinationAlbumIDs()
        }
        // Revue UX (UX5) — les filtres (dont la carte des photos) vivent
        // dans une bottom sheet ; le CTA « Voir n photos » lit `matchCount`
        // en direct. La grille reste visible derrière la détente medium.
        .sheet(isPresented: $showFilters) {
            FilterSheet(
                session: session,
                sort: $sort,
                sortAscending: $sortAscending,
                groupBursts: $groupBursts,
                groupByDay: $groupByDay,
                filters: $filters,
                availableFormats: derived.availableFormats,
                cameras: derived.cameras,
                lenses: derived.lenses,
                hasGeolocated: derived.hasGeolocated,
                matchCount: derived.filtered.count,
                isFiltering: isFiltering,
                onReset: resetFilters
            )
        }
        // Revue UX (UX5) — le menu ⚙️ devient une sheet Réglages.
        .sheet(isPresented: $showSettings) {
            SettingsSheet(session: session)
        }
        // Jalon 9 — sélecteur de périmètre puis écran de tri rapide. Le cover
        // part de `onDismiss` pour ne jamais empiler deux présentations.
        .sheet(isPresented: $showQuickCullSetup, onDismiss: {
            if let items = pendingQuickCull {
                pendingQuickCull = nil
                quickCullContext = QuickCullContext(items: items)
            }
        }) {
            QuickCullSetupView(
                untriaged: quickCullBase.filter { $0.decision == .undecided },
                today: quickCullTodayItems
            ) { items in
                pendingQuickCull = items
                showQuickCullSetup = false
            }
        }
        .fullScreenCover(item: $quickCullContext) { context in
            QuickCullView(session: session, sourceItems: context.items)
        }
        // Idée 15 — réglage du Mode Voyage (menu ⚙️).
        .sheet(isPresented: $showTripSettings, onDismiss: {
            // Archivage implicite : tout voyage actif validé rejoint
            // l'historique global (proposé ensuite par la sheet de période) —
            // en configurer un nouveau n'écrase plus le précédent.
            var trips = SavedTrip.load()
            SavedTrip.record(session.trip, in: &trips)
        }) {
            TripSettingsView(session: session)
        }
        // Idée 23 — ③ : le voyage change (activation, édition, fin) → le
        // rappel quotidien suit, permission demandée en contexte au besoin.
        .onChange(of: session.trip) { _, trip in
            Task { await CullNotifications.tripChanged(trip) }
        }
        // Idée 23 — ③ : tap sur « La passe du soir » → Tri rapide sur les
        // photos du jour. `initial: true` : au lancement à froid, la route
        // est posée avant que la grille n'existe. Journée sans photo → le
        // sélecteur de périmètre s'ouvre à la place (comptes en direct).
        .onChange(of: NotificationRouter.shared.pendingRoute, initial: true) { _, route in
            guard route == .quickCullToday else { return }
            NotificationRouter.shared.pendingRoute = nil
            let today = quickCullTodayItems
            if today.isEmpty {
                showQuickCullSetup = true
            } else {
                quickCullContext = QuickCullContext(items: today)
            }
        }
    }

    // MARK: - Cellules

    @ViewBuilder
    private func cell(for entry: GridEntry) -> some View {
        switch entry {
        case .photo(let item):
            let cell = Button {
                if isSelecting {
                    toggleSelection(item)
                } else {
                    viewerContext = ViewerContext(start: item, items: displayedItems)
                }
            } label: {
                ThumbnailCell(
                    item: item,
                    isSelecting: isSelecting,
                    isSelected: selection.contains(item.id)
                )
            }
            .buttonStyle(.plain)
            .matchedTransitionSource(id: item.id, in: zoomNamespace)

            // Revue UX (UX1) — appui long = « clic droit mobile » : les
            // micro-actions de tri sans ouvrir le viewer ni le mode
            // sélection. Hors mode sélection uniquement (l'appui long y
            // parasiterait le toggle des coches).
            if isSelecting {
                cell
            } else {
                cell.contextMenu {
                    photoContextMenu(for: item)
                } preview: {
                    PhotoContextPreview(item: item)
                }
            }

        case .stack(let cover, let members, let visible):
            // Une pile se manipule d'un bloc : tap = viewer scopé à la pile
            // entière ; en sélection, toggle de tous les membres visibles.
            let cell = Button {
                if isSelecting {
                    toggleStackSelection(visible)
                } else {
                    BurstPileTip().invalidate(reason: .actionPerformed)
                    viewerContext = ViewerContext(start: cover, items: members, isStack: true)
                }
            } label: {
                ThumbnailCell(
                    item: cover,
                    isSelecting: isSelecting,
                    isSelected: !visible.isEmpty && visible.allSatisfy { selection.contains($0.id) }
                )
                .overlay(alignment: .bottomTrailing) {
                    if !isSelecting {
                        stackBadge(count: members.count)
                    }
                }
            }
            .buttonStyle(.plain)
            .matchedTransitionSource(id: cover.id, in: zoomNamespace)
            // Idée 21 — tip ④ : ancré sur la **première** pile affichée
            // (une seule ancre : plusieurs feraient fleurir le popover).
            .modifier(BurstTipAnchor(isFirstStack: cover.id == firstStackCoverID))

            if isSelecting {
                cell
            } else {
                cell.contextMenu {
                    stackContextMenu(cover: cover, members: members)
                } preview: {
                    PhotoContextPreview(item: cover)
                }
            }
        }
    }

    // MARK: - Menus contextuels (Revue UX, UX1)

    /// Actions d'appui long d'une photo : décision, note, enregistrement,
    /// suppression — les mêmes verbes que le viewer et la sélection, jamais
    /// de nouvelle capacité.
    @ViewBuilder
    private func photoContextMenu(for item: PhotoItem) -> some View {
        Section {
            Button {
                session.setDecision(.keep, for: [item])
            } label: {
                Label("Garder", systemImage: "checkmark.circle")
            }
            Button {
                session.setDecision(.reject, for: [item])
            } label: {
                Label("Rejeter", systemImage: "xmark.circle")
            }
            if item.decision != .undecided {
                Button {
                    session.setDecision(.undecided, for: [item])
                } label: {
                    Label("Remettre à non triée", systemImage: "minus.circle")
                }
            }
        }
        Section("Note") {
            // Palette pré-sélectionnée sur la note courante (contrairement à
            // la palette-action de la sélection multiple, une seule photo a
            // une note bien définie).
            Picker(
                "Noter la photo",
                selection: Binding(
                    get: { item.rating },
                    set: { session.setRating($0, for: [item]) }
                )
            ) {
                Image(systemName: "star.slash").tag(0)
                ForEach(1...5, id: \.self) { rating in
                    Image(systemName: "\(rating).circle").tag(rating)
                }
            }
            .pickerStyle(.palette)
        }
        Section {
            Button {
                Task { await save([item]) }
            } label: {
                // Par photo : un asset s'ajoute à l'album, un fichier se copie
                // dans la pellicule (correct même en session combinée).
                Label(
                    item.isLibraryBacked ? "Ajouter à l'album" : "Enregistrer dans la pellicule",
                    systemImage: item.isLibraryBacked
                        ? "rectangle.stack.badge.plus"
                        : "square.and.arrow.down"
                )
            }
            Button(role: .destructive) {
                contextDeleteItem = item
            } label: {
                Label("Supprimer", systemImage: "trash")
            }
        }
    }

    /// Appui long sur une pile : les actions de pile (idées 3/4) accessibles
    /// sans ouvrir le viewer scopé, plus la décision en bloc.
    @ViewBuilder
    private func stackContextMenu(cover: PhotoItem, members: [PhotoItem]) -> some View {
        Section {
            Button {
                viewerContext = ViewerContext(start: cover, items: members, isStack: true)
            } label: {
                Label("Ouvrir la pile", systemImage: "square.stack")
            }
            Button {
                session.elect(cover, among: members)
            } label: {
                Label("Élire la couverture", systemImage: "crown")
            }
            Button {
                duelContext = DuelContext(items: members)
            } label: {
                Label("Duel", systemImage: "rectangle.split.2x1")
            }
        }
        Section {
            Button {
                session.setDecision(.keep, for: members)
            } label: {
                Label("Tout garder", systemImage: "checkmark.circle")
            }
            Button {
                session.setDecision(.reject, for: members)
            } label: {
                Label("Tout rejeter", systemImage: "xmark.circle")
            }
        }
    }

    /// Idée 21 — ancre du tip de rafale : la première pile de la grille.
    private var firstStackCoverID: PhotoItem.ID? {
        for entry in derived.entries {
            if case .stack(let cover, _, _) = entry { return cover.id }
        }
        return nil
    }

    /// En-tête de section épinglé : jour (« 8 juillet 2026 »), lieu dominant
    /// si le GPS l'a donné, compteur de photos à droite.
    private func sectionHeader(_ section: DaySection) -> some View {
        HStack(spacing: 6) {
            Text(section.day.map { $0.formatted(date: .long, time: .omitted) }
                ?? String(localized: "Date inconnue"))
                .font(.subheadline.weight(.semibold))
            if let place = section.place {
                Text("· \(place)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(photoCount(of: section.entries))")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func photoCount(of entries: [GridEntry]) -> Int {
        entries.reduce(0) { total, entry in
            switch entry {
            case .photo: return total + 1
            case .stack(_, _, let visible): return total + visible.count
            }
        }
    }

    private func stackBadge(count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "square.stack")
            Text("\(count)")
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: .capsule)
        .padding(5)
    }

    private func toggleSelection(_ item: PhotoItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    private func toggleStackSelection(_ members: [PhotoItem]) {
        let ids = members.map(\.id)
        if ids.allSatisfy(selection.contains) {
            for id in ids { selection.remove(id) }
        } else {
            selection.formUnion(ids)
        }
    }

    // MARK: - Barres

    /// Pilule d'orientation flottante, centrée sous la barre du haut : nom
    /// de la **source** (toujours lui — le voyage a son bouton ✈️ en barre)
    /// et nombre de photos **réellement affichées** (filtres et voyage
    /// compris). Remplace le titre/sous-titre de la barre, écrasés par les
    /// boutons sur iPhone.
    ///
    /// Revue UX (UX4, point 7) — la progression du tri (« n restantes »,
    /// pilule tappable) a été **essayée puis retirée** : le chiffre se lit
    /// rarement depuis la grille (le tri actif vit dans le viewer et le Tri
    /// rapide) et il alourdissait une pilule appréciée pour sa sobriété.
    private var statusPill: some View {
        // Tappable : ouvre le récap des sources (voir / retirer / ajouter) —
        // le chevron le signale en combiné, où la gestion a le plus de sens.
        Button {
            onChangeSource(.manage)
        } label: {
            HStack(spacing: 6) {
                Text(sourceLabel)
                    .fontWeight(.semibold)
                Text(photoCountLabel)
                    .foregroundStyle(.secondary)
                // Chevron permanent : la pilule est le repère **et** l'entrée
                // du hub « Sources » (la toolbar n'a plus de menu de sources).
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassEffect()
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.top, 6)
    }

    private var photoCountLabel: String { photoCountText(derived.filtered.count) }

    /// Nom(s) de la source pour la pilule. Une source : son nom. Deux : les
    /// deux noms (« Carte SD + Pellicule »). Au-delà, les noms ne tiennent plus
    /// et n'apprennent rien — un décompte (« 3 sources ») ; le détail vit dans
    /// le hub d'un tap.
    private var sourceLabel: String {
        let names = session.sources.map(\.displayName)
        switch names.count {
        case 1: return names[0]
        case 2: return names.joined(separator: " + ")
        default: return String(localized: "\(names.count) sources")
        }
    }

    private var selectionTitle: String {
        selection.isEmpty
            ? String(localized: "Sélectionner")
            : String(localized: "\(selection.count) sélectionnée(s)")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(selection.count == derived.filtered.count ? "Aucune" : "Toutes") {
                    if selection.count == derived.filtered.count {
                        selection.removeAll()
                    } else {
                        selection = Set(derived.filtered.map(\.id))
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("OK") { exitSelection() }
                    .fontWeight(.semibold)
            }

            // Bottom bar native façon Photos.app : partage à gauche, actions à
            // droite, le reste dans ⋯ — Liquid Glass, espacements et insets
            // gérés par le système, aucun débordement possible. Le partage
            // d'originaux ne vaut que pour les fichiers (les photos de la
            // photothèque se partagent depuis Photos) : proposé dès qu'une
            // source dossier est présente, il porte sur les fichiers choisis.
            if session.hasFileSource {
                ToolbarItem(placement: .bottomBar) {
                    ShareLink(items: selectedItems.compactMap(\.url)) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(selectedItems.allSatisfy { $0.url == nil })
                }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                // Toute la sélection, y compris les photos déjà enregistrées :
                // re-télécharger volontairement doit rester possible (le badge
                // bleu signale l'état, il ne bloque pas l'action). Sur la
                // photothèque, l'action devient « ajouter à l'album ».
                Button {
                    Task {
                        let items = selectedItems
                        exitSelection()
                        await save(items)
                    }
                } label: {
                    Image(systemName: isLibrarySource
                        ? "rectangle.stack.badge.plus"
                        : "square.and.arrow.down")
                }
                .accessibilityLabel(isLibrarySource
                    ? "Ajouter la sélection à l'album"
                    : "Enregistrer la sélection dans la pellicule")
                .disabled(selection.isEmpty || isSaving)
            }
            ToolbarItem(placement: .bottomBar) {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Supprimer la sélection")
                .disabled(selection.isEmpty)
            }
            ToolbarItem(placement: .bottomBar) {
                selectionMoreMenu
            }
        } else {
            // Batch H5 — plus de menu de sources ici : une simple icône qui
            // ouvre le hub « Sources » (voir / changer / ajouter / retirer).
            // Icône « pile de sources » (générique, pas celle d'un support) ;
            // la pilule fait le même geste.
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    onChangeSource(.manage)
                } label: {
                    Label("Sources", systemImage: "square.stack.3d.up")
                }
            }
            // Revue UX (UX5) — filtres et réglages en sheets : l'icône
            // pleine signale un filtre actif (comme l'ancien menu).
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showFilters = true
                } label: {
                    Label(
                        "Filtrer",
                        systemImage: isFiltering
                            ? "line.3.horizontal.decrease.circle.fill"
                            : "line.3.horizontal.decrease.circle"
                    )
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showSettings = true
                } label: {
                    Label("Réglages", systemImage: "gearshape")
                }
            }
            // Statut Mode Voyage : n'apparaît que quand un voyage borne
            // l'affichage ; le toucher ouvre le drawer Voyage.
            if session.trip.isActive {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Mode Voyage", systemImage: "airplane.circle.fill") {
                        showTripSettings = true
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Annuler la dernière action", systemImage: "arrow.uturn.backward") {
                    session.undo()
                }
                .disabled(!session.canUndo)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Sélectionner", systemImage: "checkmark.circle") {
                    isSelecting = true
                }
                .disabled(derived.filtered.isEmpty)
            }
        }
    }

    /// Menu ⋯ de la bottom bar de sélection : tri et note en masse, export,
    /// et purge des rejetées (action globale, indépendante de la sélection).
    private var selectionMoreMenu: some View {
        Menu {
            Section {
                // Idée 4 — 2 photos = duel simple, 3+ = tournoi.
                Button {
                    let contenders = selectedItems.sorted {
                        ($0.fileDate ?? .distantPast) < ($1.fileDate ?? .distantPast)
                    }
                    duelContext = DuelContext(items: contenders)
                } label: {
                    Label(
                        selectedItems.count > 2
                            ? "Tournoi (\(selectedItems.count))"
                            : "Duel",
                        systemImage: "rectangle.split.2x1"
                    )
                }
                .disabled(selectedItems.count < 2)
            }
            Section("Tri") {
                Button {
                    applyDecision(.keep)
                } label: {
                    Label("Garder", systemImage: "checkmark.circle")
                }
                Button {
                    applyDecision(.reject)
                } label: {
                    Label("Rejeter", systemImage: "xmark.circle")
                }
                Button {
                    applyDecision(.undecided)
                } label: {
                    Label("Remettre à non triée", systemImage: "minus.circle")
                }
            }
            .disabled(selection.isEmpty)
            Section("Note") {
                // Palette-action : rien n'est jamais « sélectionné », chaque
                // tap applique la note à toute la sélection.
                Picker(
                    "Noter la sélection",
                    selection: Binding(get: { -1 }, set: { applyRating($0) })
                ) {
                    Image(systemName: "star.slash").tag(0)
                    ForEach(1...5, id: \.self) { rating in
                        Image(systemName: "\(rating).circle").tag(rating)
                    }
                }
                .pickerStyle(.palette)
            }
            // Export d'originaux : réservé aux fichiers (les photos de la
            // photothèque sont déjà sur l'appareil). Disponible dès qu'une
            // source dossier est présente ; l'export ne prend que les fichiers.
            if session.hasFileSource {
                Section {
                    Button {
                        showExport = true
                    } label: {
                        Label("Exporter vers Fichiers", systemImage: "folder")
                    }
                }
                .disabled(selectedItems.allSatisfy { $0.url == nil })
            }
            Section {
                Button(role: .destructive) {
                    confirmDeleteRejected = true
                } label: {
                    Label(
                        "Supprimer toutes les rejetées (\(session.rejected.count))",
                        systemImage: "trash"
                    )
                }
                .disabled(session.rejected.isEmpty)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Autres actions")
    }

    private func applyDecision(_ decision: CullDecision) {
        session.setDecision(decision, for: selectedItems)
    }

    private func applyRating(_ rating: Int) {
        session.setRating(rating, for: selectedItems)
    }

    /// Suppression en masse, après confirmation. Seules les photos réellement
    /// supprimées de la carte quittent la session.
    private func deleteSelection() async {
        let items = selectedItems
        exitSelection()
        await deleteItems(items)
    }

    /// Cœur de la suppression confirmée (`DeleteFlow`) — partagé entre la
    /// sélection, le menu contextuel (Revue UX, UX1) et le viewer.
    private func deleteItems(_ items: [PhotoItem]) async {
        let outcome = await DeleteFlow.run(items, session: session)
        if let message = outcome.errorMessage { saveMessage = message }
    }

    /// Purge de fin de tri : supprime de la carte toutes les rejetées.
    private func deleteRejected() async {
        let outcome = await DeleteFlow.run(session.rejected, session: session)
        // Dialogue système refusé et rien de supprimé : pas de récap à zéro.
        if outcome.cancelled, outcome.deleted.isEmpty { return }
        // Revue UX (UX4) — même partage que l'enregistrement : succès en
        // toast, échec en alerte.
        if let message = outcome.errorMessage {
            saveMessage = message
        } else if session.hasFileSource && session.hasLibrarySource {
            successToast = String(localized: "\(outcome.deleted.count) rejetée(s) supprimée(s)")
        } else {
            successToast = isLibrarySource
                ? String(localized: "\(outcome.deleted.count) rejetée(s) supprimée(s) de la photothèque")
                : String(localized: "\(outcome.deleted.count) rejetée(s) supprimée(s) de la carte")
        }
    }

    private func exitSelection() {
        isSelecting = false
        selection.removeAll()
    }

    // MARK: - Cycle de vie du voyage (archivage implicite)

    /// Terminer = archiver puis désactiver : le voyage rejoint l'historique,
    /// prêt à être repris — désactiver ne perd plus jamais un voyage.
    private func endCurrentTrip() {
        var trips = SavedTrip.load()
        SavedTrip.record(session.trip, in: &trips)
        session.trip.isActive = false
    }

    // MARK: - Filtres

    /// Remet tous les filtres à zéro (le tri, lui, est un réglage persistant).
    /// Partagé entre la sheet Filtres et l'état « rien pour ce filtre ».
    private func resetFilters() {
        filters = GridFilters()
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            ContentUnavailableView(
                session.items.isEmpty ? "Aucune photo" : "Rien pour ce filtre",
                systemImage: session.items.isEmpty
                    ? "photo.on.rectangle.angled"
                    : "line.3.horizontal.decrease.circle",
                description: Text(
                    session.items.isEmpty
                        ? (isLibrarySource
                            ? "Cette source ne contient aucune photo."
                            : "Ce dossier ne contient pas d'image lisible.")
                        : "Aucune photo ne correspond aux filtres sélectionnés."
                )
            )
            if isFiltering {
                Button("Réinitialiser les filtres") {
                    resetFilters()
                }
                .buttonStyle(.glass)
            }
            // Un voyage actif peut à lui seul vider la grille : offrir la
            // sortie ici, `resetFilters` ne touche pas au voyage. Terminer,
            // pas désactiver : le voyage rejoint l'historique.
            if session.trip.isActive {
                Button("Terminer le voyage") {
                    endCurrentTrip()
                }
                .buttonStyle(.glass)
            }
        }
        .padding(.top, 80)
    }

    // MARK: - Enregistrement

    /// Premier enregistrement de la session : on confirme d'abord l'album de
    /// destination (sheet, CTA « Enregistrer n photo(s) »). Ensuite le choix
    /// est mémorisé et les lots partent sans interruption.
    private func save(_ items: [PhotoItem]) async {
        guard !items.isEmpty else { return }
        guard session.albumConfirmed else {
            pendingSave = items
            showAlbumSettings = true
            return
        }
        await performSave(items)
    }

    /// Flux partagé (`SaveFlow`) : garde-fous, tâche d'arrière-plan,
    /// enregistrement, persistance, messages et notification hors écran. La
    /// grille garde sa présentation : overlay de progression, re-sondage de
    /// l'album, toast/alerte.
    private func performSave(_ items: [PhotoItem]) async {
        guard !items.isEmpty else { return }
        saveProgress = (0, items.count)
        let outcome = await SaveFlow.run(
            items,
            session: session,
            isAppActive: scenePhase == .active
        ) { done in
            saveProgress = (done, items.count)
        }
        saveProgress = nil
        // Batch H5 — l'album de destination a pu grossir : re-sonder pour
        // que le filtre « dans l'album » dise vrai tout de suite.
        await refreshDestinationAlbumIDs()
        successToast = outcome.successToast
        saveMessage = outcome.errorMessage
    }
}

/// Aperçu agrandi du menu contextuel (Revue UX, UX1) : la photo au format,
/// servie par le même cache d'aperçus que la grille et le Tri rapide.
/// 800 px suffisent pour juger une vignette floutée derrière un menu — la
/// vraie inspection reste l'affaire du viewer.
private struct PhotoContextPreview: View {
    let item: PhotoItem

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                // 3:4 en attendant l'aperçu (déjà en cache la plupart du
                // temps — la vignette 400 px de la cellule sert de filet).
                Rectangle()
                    .fill(.quaternary)
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .overlay { ProgressView() }
            }
        }
        .task {
            image = await ThumbnailLoader.load(item: item, maxPixel: 800)
        }
    }
}
