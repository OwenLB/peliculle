import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Contenu de la sheet de période (photothèque), figé au moment de la
/// demande : voyage en cours + historique. Voyage **dans** l'item de
/// présentation (`sheet(item:)`) — même leçon que `ViewerContext`.
struct LibraryScopeContext: Identifiable {
    let id = UUID()
    let currentTrip: TripMode?
    let pastTrips: [SavedTrip]
}

/// Racine de l'app : accueil → grille, avec restauration automatique de la
/// dernière **source** (Jalon 10 : dossier de carte SD, album Photos ou
/// photothèque entière) et surveillance de la déconnexion de la carte pour
/// les sources dossier (robustesse Jalon 2). Changer de source = clore la
/// session courante (flush de la persistance) et en ouvrir une neuve — une
/// source à la fois, jamais de fusion. Toute la navigation s'appuie sur
/// `NavigationStack`.
struct ContentView: View {
    @State private var folderAccess = FolderAccess()
    @State private var session: CullSession?
    @State private var isImporting = false
    @State private var showAlbumPicker = false
    /// Sheet de période (photothèque). Présentation par `sheet(item:)` :
    /// comme `ViewerContext`, les données voyagent **dans** l'item — une
    /// sheet `isPresented:` posée « en même temps » que des `@State` peut
    /// évaluer sa closure avec l'état périmé (sections voyage absentes).
    @State private var libraryScopeContext: LibraryScopeContext?
    @State private var isLoading = false
    @State private var notice: String?
    @State private var recentAlbums = RecentAlbum.load()
    @State private var recentFolders = RecentFolder.load()
    /// Vraie pendant une restauration de source : un tap de notification
    /// arrivé pendant la restauration automatique du lancement ne doit pas
    /// en déclencher une seconde en parallèle.
    @State private var isRestoringSource = false
    /// Batch H5 — vraie tant qu'une demande « ajouter une source » est en
    /// cours (entre le tap du menu et le choix effectif dossier/album/période).
    /// Chaque complétion la **capture synchroniquement** puis la remet à faux,
    /// pour ne jamais confondre un ajout avec un changement de source.
    @State private var isAddingSource = false
    /// Batch H5 — récap des sources actives (voir / retirer / ajouter).
    @State private var showSources = false
    /// Accès photothèque refusé (`.denied` / `.restricted`) : iOS ne re-présente
    /// plus le dialogue système → on propose d'ouvrir Réglages pour ré-autoriser.
    @State private var photoAccessDenied = false

    @Environment(\.openURL) private var openURL

    /// Dernière source ouverte, pour la restauration au lancement. Le dossier
    /// ne stocke que le marqueur « folder » : son URL vit dans le bookmark
    /// security-scoped de `FolderAccess`.
    @AppStorage("peliculle.lastSource") private var lastSource = ""

    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Lecture des photos…")
                        .controlSize(.large)
                } else if let session {
                    GridView(
                        session: session,
                        recentAlbums: recentAlbums,
                        recentFolders: recentFolders,
                        onChangeSource: handle(_:)
                    )
                    // Changer de source = repartir d'une grille vierge
                    // (filtres, sélection, viewer) : l'état de vue d'une
                    // source n'a pas de sens sur une autre. On keye sur
                    // l'identité **stable** de la session (jamais sur la source
                    // primaire, qui peut muter en combiné et recréerait la
                    // grille en pleine présentation → viewer/sheet orphelin).
                    .id(session.id)
                } else {
                    WelcomeView(
                        notice: notice,
                        recentFolders: recentFolders,
                        recentAlbums: recentAlbums,
                        onPick: { handle(.folder) },
                        onPickAlbum: { handle(.albumPicker) },
                        onPickLibrary: { handle(.library) },
                        onOpenRecent: handle(_:),
                        onDeleteRecentFolder: deleteRecentFolder,
                        onDeleteRecentAlbum: deleteRecentAlbum
                    )
                }
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.folder]) { result in
            guard case .success(let url) = result else {
                isAddingSource = false
                return
            }
            let adding = isAddingSource
            isAddingSource = false
            notice = nil
            Task {
                if adding { await addFolder(url) }
                else { await openFolder(url, fresh: true) }
            }
        }
        .sheet(isPresented: $showAlbumPicker, onDismiss: { isAddingSource = false }) {
            AlbumPickerView { album in
                let adding = isAddingSource
                isAddingSource = false
                showAlbumPicker = false
                notice = nil
                Task {
                    if adding { await addLibrarySource(.album(id: album.id, title: album.title)) }
                    else { await openLibrarySource(.album(id: album.id, title: album.title)) }
                }
            }
        }
        // Le choix de période **précède** l'ouverture de la photothèque : la
        // borne descend dans le prédicat du fetch, les photos hors période ne
        // sont jamais chargées. Un voyage choisi ici active le Mode Voyage ;
        // tout autre choix le désactive (le périmètre choisi fait foi).
        .sheet(item: $libraryScopeContext, onDismiss: { isAddingSource = false }) { context in
            LibraryScopeView(
                currentTrip: context.currentTrip,
                pastTrips: context.pastTrips
            ) { scope, trip in
                let adding = isAddingSource
                isAddingSource = false
                libraryScopeContext = nil
                notice = nil
                // Archivage implicite : le voyage choisi (re)prend la tête de
                // l'historique global.
                if let trip {
                    var trips = SavedTrip.load()
                    SavedTrip.record(trip, in: &trips)
                }
                Task {
                    // En ajout, la période borne bien le fetch, mais le voyage
                    // de la session combinée reste maître (on ne l'écrase pas).
                    if adding { await addLibrarySource(.library(scope)) }
                    else { await openLibrarySource(.library(scope), trip: trip, keepTrip: false) }
                }
            }
        }
        // Batch H5 — récap des sources actives : voir, retirer, ajouter. Les
        // ajouts referment le récap puis rejoignent le flux `.add(...)` normal.
        .sheet(isPresented: $showSources) {
            if let session {
                SourcesView(
                    session: session,
                    recentFolders: recentFolders,
                    recentAlbums: recentAlbums,
                    onRequest: handle(_:),
                    onDeleteRecentFolder: deleteRecentFolder,
                    onDeleteRecentAlbum: deleteRecentAlbum
                )
            }
        }
        // Accès photothèque refusé : proposer d'ouvrir Réglages (iOS ne
        // re-présente plus le dialogue système une fois `.denied`). Une source
        // `.notDetermined`, elle, déclenche encore le dialogue au moment du
        // `requestReadAccess` — l'alerte ne sort que pour un vrai refus.
        .alert("Accès aux photos requis", isPresented: $photoAccessDenied) {
            Button("Ouvrir Réglages") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Pour trier un album ou toute la photothèque, autorisez l'accès aux photos dans Réglages.")
        }
        .task {
            // Watchdog : si le lancement précédent s'est figé au démarrage, on
            // saute la restauration et l'accueil reprend la main.
            if enterSafeModeIfPreviousLaunchHung() { return }
            await restoreLastSource()
        }
        // Clé sur **l'ensemble** des sources (pas la seule primaire) : ajouter
        // une carte à une session photothèque doit (re)lancer la surveillance.
        .task(id: session?.sources) {
            await monitorCardConnection()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Idée 23 — l'utilisateur est là : le rappel de tri n'a plus
                // d'objet, et revenir sur une session entamée est LE contexte
                // pour demander la permission de notifier (jamais à froid).
                CullNotifications.cancelUnfinished()
                if let session {
                    CullNotifications.syncTripReminder(trip: session.trip)
                    Task { await CullNotifications.requestPermissionInContext(session: session) }
                }
                // La sonde de retour au premier plan ne concerne que la carte
                // (une source dossier, éventuellement au sein d'un combiné).
                guard session?.hasFileSource == true else { return }
                Task { await checkFolderReachability() }
                // Batch H5 — une copie carte a pu être supprimée de l'app Photos
                // pendant l'absence : rafraîchir le marquage « téléchargé ».
                if let items = session?.items {
                    Task { await reconcileSavedMarks(items) }
                }
            case .background:
                // Atteindre l'arrière-plan prouve que le lancement était sain :
                // on lève le drapeau du watchdog (couvre un usage < 4 s).
                UserDefaults.standard.set(false, forKey: Self.launchWatchdogKey)
                // L'app peut être tuée en arrière-plan : on force l'écriture
                // de l'état de tri sans attendre le debounce.
                session?.persistNow()
                // Idée 23 — ① rappel de tri inachevé, programmé à la sortie.
                if let session {
                    CullNotifications.scheduleUnfinishedOnExit(session: session)
                }
            default:
                break
            }
        }
        // Idée 23 — tap sur une notification : ① reprendre la dernière
        // source si aucune session n'est ouverte (sinon revenir au premier
        // plan suffit) ; ③ restaurer de même, puis laisser la route au Tri
        // rapide de la grille. `initial: true` : la route d'un lancement à
        // froid est posée avant que la vue n'existe.
        .onChange(of: NotificationRouter.shared.pendingRoute, initial: true) { _, route in
            guard let route else { return }
            if route == .resume { NotificationRouter.shared.pendingRoute = nil }
            // Session ouverte, ou restauration déjà en cours (lancement à
            // froid) : revenir au premier plan suffit — une route ③
            // restante sera consommée par la grille.
            guard session == nil, !isLoading, !isRestoringSource else { return }
            Task { await restoreLastSource() }
        }
    }

    // MARK: - Demandes de changement de source

    /// Point d'entrée unique des demandes de l'accueil et du bouton Source de
    /// la grille. Les sources photothèque obtiennent d'abord l'autorisation
    /// de lecture (jamais demandée tant qu'on reste sur la carte).
    private func handle(_ request: SourceRequest) {
        switch request {
        case .add(let inner):
            // Batch H5 — même flux de choix (dossier/album/période), mais on
            // arme le mode ajout : la complétion appellera `addSource` et non
            // un changement de source. Sans session ouverte, un ajout n'a pas
            // de sens → ouverture normale.
            guard session != nil else { handle(inner); return }
            // Différé d'un tick : l'ajout part du hub Sources (une sheet), qui
            // se referme d'abord ; présenter le picker au tick suivant lui
            // laisse le temps de disparaître, sans empiler deux présentations
            // (ni perdre le picker comme quand l'ajout vivait dans un menu).
            Task { @MainActor in
                isAddingSource = true
                handle(inner)
            }
        case .folder:
            isImporting = true
        case .albumPicker:
            Task {
                guard await ensurePhotoAccess() else { isAddingSource = false; return }
                showAlbumPicker = true
            }
        case .library:
            Task {
                guard await ensurePhotoAccess() else { isAddingSource = false; return }
                // Voyage en cours : celui de la session **ouverte** s'il est
                // actif — y compris une session carte SD, un voyage vaut pour
                // toutes les sources et vit peut-être encore en mémoire
                // (persistance débouncée) — sinon celui persisté par la
                // session photothèque.
                let currentTrip: TripMode? = if let trip = session?.trip, trip.isActive {
                    trip
                } else {
                    await SessionStore.peekLibraryTrip()
                }

                // Migration **unique** vers l'historique global des voyages
                // actifs des sessions persistées d'avant le registre.
                // Re-scanner à chaque ouverture ressuscitait les voyages
                // supprimés de l'historique (les sessions gardaient leur
                // voyage actif) ; depuis, toute activation passe par le
                // registre (drawer Voyage, sheet de période) et la
                // suppression désactive aussi le voyage dans les sessions
                // (`SessionStore.deactivateTrips`).
                var trips = SavedTrip.load()
                let migrationKey = "peliculle.tripsMigrated"
                if !UserDefaults.standard.bool(forKey: migrationKey) {
                    for trip in await SessionStore.peekActiveTrips() {
                        SavedTrip.record(trip, in: &trips)
                    }
                    UserDefaults.standard.set(true, forKey: migrationKey)
                }
                if let currentTrip {
                    SavedTrip.record(currentTrip, in: &trips)
                    let currentID = SavedTrip(currentTrip).id
                    trips.removeAll { $0.id == currentID }
                }
                libraryScopeContext = LibraryScopeContext(
                    currentTrip: currentTrip,
                    pastTrips: trips
                )
            }
        case .album(let id, let title):
            let adding = isAddingSource
            isAddingSource = false
            notice = nil
            Task {
                if adding { await addLibrarySource(.album(id: id, title: title)) }
                else { await openLibrarySource(.album(id: id, title: title)) }
            }
        case .recentFolder(let recent):
            let adding = isAddingSource
            isAddingSource = false
            notice = nil
            Task {
                if adding { await addRecentFolder(recent) }
                else { await openRecentFolder(recent) }
            }
        case .welcome:
            // Retour à l'accueil : clore proprement (persistance flushée,
            // scope de la carte relâché). La dernière source reste mémorisée
            // pour la restauration au prochain lancement.
            notice = nil
            closeCurrentSession()
            folderAccess.stopAll()
        case .manage:
            showSources = true
        case .remove(let source):
            removeSource(source)
        }
    }

    /// Retire une source précise de la session combinée (récap). Son état est
    /// flushé avant qu'elle ne quitte la session (via `removeSources`) ; sans
    /// effet si c'est la dernière source (garde-fou « ne jamais vider »). Si la
    /// source retirée est un dossier, on relâche **son** scope (les autres
    /// dossiers restent accessibles).
    private func removeSource(_ source: PhotoSource) {
        guard let session else { return }
        let removed = session.removeSources { $0 == source }
        guard removed else { return }
        if case .folder(let url, _) = source { folderAccess.stopAccess(url) }
    }

    /// Demande l'accès photothèque ; sur refus, arme l'alerte « Ouvrir
    /// Réglages » et renvoie faux. Point **unique** du flux de refus, partagé
    /// par toutes les ouvertures/ajouts de source photothèque (album, période).
    private func ensurePhotoAccess() async -> Bool {
        if await PhotoLibrarySource.requestReadAccess() { return true }
        photoAccessDenied = true
        return false
    }

    // MARK: - Ouverture des sources

    private func openFolder(_ url: URL, fresh: Bool) async {
        isLoading = true
        defer { isLoading = false }

        closeCurrentSession()
        var bookmark: Data?
        if fresh {
            // Changement de source : `open` relâche les scopes précédents.
            bookmark = await folderAccess.open(url)
        }
        let items = await folderAccess.loadItems(from: url)
        // Détection du support (carte SD, disque externe, iCloud, local)
        // pendant que le scope de sécurité est ouvert — refaite à chaque
        // restauration, le même bookmark pouvant pointer un autre volume.
        let kind = await FolderKind.detect(for: url)
        if let bookmark {
            RecentFolder.record(url: url, kind: kind, bookmark: bookmark, in: &recentFolders)
        }
        await startSession(.folder(url, kind: kind), items: items)
    }

    /// Rouvre un dossier récent depuis son bookmark. Volume absent (carte
    /// débranchée, dossier supprimé) → même message gracieux que la
    /// restauration au lancement, sans toucher à la session courante.
    private func openRecentFolder(_ recent: RecentFolder) async {
        guard let url = await resolveFolderBookmark(recent) else {
            notice = String(localized: "Carte non retrouvée — resélectionnez le dossier.")
            return
        }
        // fresh : rouvre le scope, re-persiste le bookmark (rafraîchi s'il
        // était périmé) et remonte l'entrée en tête des récents.
        await openFolder(url, fresh: true)
    }

    private func resolveFolderBookmark(_ recent: RecentFolder) async -> URL? {
        await Task.detached(priority: .userInitiated) { () -> URL? in
            var isStale = false
            return try? URL(
                resolvingBookmarkData: recent.bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        }.value
    }

    // MARK: - Ajout de sources (Batch H5 — sessions combinées)

    /// Ajoute un dossier (carte SD, disque…) à la session en cours sans la
    /// clore. Le scope de sécurité du dossier ajouté est ouvert et sa
    /// persistance reprise ; ses photos rejoignent la grille, entrelacées.
    private func addFolder(_ url: URL) async {
        guard let session else { return }
        isLoading = true
        defer { isLoading = false }
        // Ajout : `addScope` garde les scopes des autres dossiers ouverts.
        let bookmark = await folderAccess.addScope(url)
        let items = await folderAccess.loadItems(from: url)
        let kind = await FolderKind.detect(for: url)
        if let bookmark {
            RecentFolder.record(url: url, kind: kind, bookmark: bookmark, in: &recentFolders)
        }
        let source = PhotoSource.folder(url, kind: kind)
        let store = await SessionStore.load(for: source, items: items)
        store.apply(to: items)
        session.addSource(source, items: items, store: store)
        await reconcileSavedMarks(items)
    }

    /// Retrait manuel d'une entrée « récents » (accueil « Reprendre », hub
    /// Sources) : on mute l'état source de vérité — la persistance suit et les
    /// deux vues qui l'affichent se rafraîchissent.
    private func deleteRecentFolder(_ folder: RecentFolder) {
        withAnimation { RecentFolder.remove(id: folder.id, in: &recentFolders) }
    }

    private func deleteRecentAlbum(_ album: RecentAlbum) {
        withAnimation { RecentAlbum.remove(id: album.id, in: &recentAlbums) }
    }

    private func addRecentFolder(_ recent: RecentFolder) async {
        guard let url = await resolveFolderBookmark(recent) else {
            notice = String(localized: "Carte non retrouvée — resélectionnez le dossier.")
            return
        }
        await addFolder(url)
    }

    /// Ajoute une source photothèque (album ou période) à la session en cours.
    /// La photothèque n'a pas de scope à ouvrir ; le voyage de la session
    /// combinée reste maître. Déduplication carte↔pellicule assurée par
    /// `CullSession.addSource`.
    private func addLibrarySource(_ source: PhotoSource) async {
        guard let session else { return }
        guard await ensurePhotoAccess() else { return }
        isLoading = true
        defer { isLoading = false }
        let albumID: String? = if case .album(let id, _) = source { id } else { nil }
        let scope: LibraryScope = if case .library(let scope) = source { scope } else { .all }
        let items = await PhotoLibrarySource.loadItems(albumID: albumID, scope: scope)
        let store = await SessionStore.load(for: source, items: items)
        store.apply(to: items)
        session.addSource(source, items: items, store: store)
        if case .album(let id, let title) = source {
            RecentAlbum.record(id: id, title: title, in: &recentAlbums)
        }
    }

    /// - Parameters:
    ///   - trip: Mode Voyage à appliquer à la session — renseigné par le
    ///     choix « Voyage » de la sheet de période, ignoré si `keepTrip`.
    ///   - keepTrip: `true` (défaut) = ne pas toucher au voyage persisté de
    ///     la session (albums, restauration au lancement). La sheet de
    ///     période passe `false` : son choix fait foi — activer le voyage
    ///     choisi, ou désactiver un voyage persisté d'une session passée qui
    ///     viderait la grille d'une autre période.
    private func openLibrarySource(
        _ source: PhotoSource,
        trip: TripMode? = nil,
        keepTrip: Bool = true
    ) async {
        guard await ensurePhotoAccess() else { return }
        isLoading = true
        defer { isLoading = false }

        closeCurrentSession()
        // La carte n'est plus la source : on relâche tous les scopes dossier.
        folderAccess.stopAll()

        let albumID: String? = if case .album(let id, _) = source { id } else { nil }
        let scope: LibraryScope = if case .library(let scope) = source { scope } else { .all }
        let items = await PhotoLibrarySource.loadItems(albumID: albumID, scope: scope)
        await startSession(source, items: items)

        if !keepTrip {
            if let trip {
                session?.trip = trip
            } else if session?.trip.isActive == true {
                session?.trip.isActive = false
            }
        }

        if case .album(let id, let title) = source {
            RecentAlbum.record(id: id, title: title, in: &recentAlbums)
        }
    }

    /// Reprise de session : réapplique décisions, notes et état
    /// « enregistré » sauvegardés pour cette source (pour un dossier, les
    /// items scannés servent aussi de filet de récupération par contenu).
    private func startSession(_ source: PhotoSource, items: [PhotoItem]) async {
        let store = await SessionStore.load(for: source, items: items)
        store.apply(to: items)
        session = CullSession(source: source, items: items, store: store)
        lastSource = source.storageValue
        // Après l'assignation : la correction éventuelle vise le bon store.
        await reconcileSavedMarks(items)
    }

    /// Batch H5 — corrige le marquage « téléchargé » d'une copie carte dont
    /// l'asset a depuis été supprimé de l'app Photos : sans ça le badge (et le
    /// filtre Téléchargement) mentent. N'agit qu'avec l'accès **complet** en
    /// lecture (`hasFullReadAccess`) ; sinon on laisse le marquage tel quel
    /// plutôt que de risquer un faux démarquage (accès limité) ou une alerte à
    /// froid. Ne concerne que les copies fichier → pellicule (`savedAssetID`
    /// renseigné) ; les items photothèque n'en ont pas. Persiste la correction.
    private func reconcileSavedMarks(_ items: [PhotoItem]) async {
        let tracked = items.filter { $0.savedAssetID != nil }
        guard !tracked.isEmpty, PhotoLibrarySource.hasFullReadAccess else { return }
        let alive = await PhotoLibrarySource.existingAssetIDs(tracked.compactMap(\.savedAssetID))
        var changed = false
        for item in tracked where !alive.contains(item.savedAssetID ?? "") {
            item.savedToLibrary = false
            item.savedAssetID = nil
            changed = true
        }
        if changed { session?.persistSoon() }
    }

    /// Changer de source = clore proprement la session courante : flush de la
    /// persistance sans attendre le debounce (comme au débranchement).
    private func closeCurrentSession() {
        session?.persistNow()
        session = nil
    }

    // MARK: - Restauration au lancement

    /// Clé du watchdog de lancement (voir `enterSafeModeIfPreviousLaunchHung`).
    private static let launchWatchdogKey = "peliculle.launchIncomplete"

    /// Watchdog de lancement : détecte un lancement précédent qui **n'a jamais
    /// atteint un état vivant** (main thread figé au démarrage — le symptôme
    /// « photos visibles, taps morts » que le force-quit seul ne levait pas).
    /// On pose un drapeau au début du lancement et on le lève dès que l'UI est
    /// prouvée réactive (tick main thread à 4 s, ou passage en arrière-plan).
    /// Si au lancement suivant le drapeau est **encore posé**, le lancement
    /// d'avant s'est figé → mode sûr : on saute la restauration et l'accueil
    /// reprend la main (la source se rouvre d'un tap).
    ///
    /// Contrairement à une simple heuristique « relance rapprochée », un
    /// lancement sain — même rouvert aussitôt (retour d'arrière-plan, kill
    /// mémoire OS) — ne le déclenche jamais : le drapeau a été levé.
    private func enterSafeModeIfPreviousLaunchHung() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.launchWatchdogKey) {
            defaults.set(false, forKey: Self.launchWatchdogKey)
            notice = String(localized: "Ouverture précédente interrompue — resélectionnez la source.")
            return true
        }
        defaults.set(true, forKey: Self.launchWatchdogKey)
        // Preuve de vie : si le main thread n'est pas figé, ce tick s'exécute
        // et lève le drapeau ; s'il gèle au démarrage, il ne part jamais et le
        // prochain lancement passe en mode sûr.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            defaults.set(false, forKey: Self.launchWatchdogKey)
        }
        return false
    }

    private func restoreLastSource() async {
        guard !isRestoringSource else { return }
        isRestoringSource = true
        defer {
            isRestoringSource = false
            // Restauration impossible (carte absente, accès retiré…) : une
            // route de notification en attente (③) ne doit pas rester en
            // embuscade pour une prochaine grille.
            if session == nil { NotificationRouter.shared.pendingRoute = nil }
        }
        switch lastSource {
        case "folder", "":
            // "" : rien de mémorisé — le bookmark historique fait foi.
            if let url = await folderAccess.restore() {
                await openFolder(url, fresh: false)
            } else if folderAccess.needsReselection {
                notice = String(localized: "Carte non retrouvée — resélectionnez le dossier.")
            }
        default:
            guard let source = PhotoSource.fromStorage(lastSource),
                  PhotoLibrarySource.hasReadAccess else {
                // Autorisation retirée entre-temps : accueil, sans alerte.
                return
            }
            await openLibrarySource(source)
        }
    }

    // MARK: - Robustesse carte (sources dossier uniquement)

    /// Sonde périodiquement l'accès aux cartes tant qu'une session dossier est
    /// active — la photothèque n'a pas de câble à débrancher. Relancée à chaque
    /// changement de l'ensemble des sources (`.task(id: session?.sources)`).
    private func monitorCardConnection() async {
        guard session?.hasFileSource == true else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3))
            guard session?.hasFileSource == true else { return }
            await checkFolderReachability()
        }
    }

    /// Sonde **chaque** dossier de la session et ne retire que ceux réellement
    /// injoignables — en combiné multi-cartes, débrancher une carte ne doit pas
    /// emporter les autres (chacune a son propre scope, voir `FolderAccess`).
    private func checkFolderReachability() async {
        guard let session else { return }
        let folderURLs: [URL] = session.sources.compactMap { source in
            if case .folder(let url, _) = source { return url }
            return nil
        }
        var unreachable: Set<URL> = []
        for url in folderURLs where !(await folderAccess.isReachable(url)) {
            unreachable.insert(url)
        }
        guard !unreachable.isEmpty else { return }
        handleDisconnect(unreachable: unreachable)
    }

    /// Carte(s) débranchée(s). On retire les seules sources dossier
    /// injoignables et on relâche leurs scopes. Si le tri se poursuit sur
    /// d'autres sources (combiné), on l'annonce ; si c'était la dernière source,
    /// la session est close proprement.
    private func handleDisconnect(unreachable: Set<URL>) {
        guard let session else { return }
        let removed = session.removeSources { source in
            if case .folder(let url, _) = source { return unreachable.contains(url) }
            return false
        }
        for url in unreachable { folderAccess.stopAccess(url) }
        if removed {
            notice = String(localized: "Carte déconnectée — tri poursuivi sur les autres sources.")
            return
        }
        // `removeSources` a refusé (viderait la session) : dernière source
        // dossier débranchée → clore proprement.
        session.persistNow()
        folderAccess.stopAll()
        self.session = nil
        notice = String(localized: "Carte déconnectée. Reconnectez-la puis resélectionnez le dossier.")
    }
}

#Preview {
    ContentView()
}
