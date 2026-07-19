import Foundation

/// Une **source active** de la session et sa persistance dédiée (Batch H5).
/// En session simple il n'y en a qu'une ; en session combinée (carte SD +
/// photothèque, etc.) il y en a plusieurs, chacune gardant son propre fichier
/// de session — y revenir seule la reprend à l'identique.
struct SourceSlot: Identifiable {
    let source: PhotoSource
    let store: SessionStore
    var id: PhotoSource { source }
}

/// Une session de tri : une ou plusieurs **sources** (dossier de carte SD,
/// album Photos, photothèque — Jalon 10 ; combinables — Batch H5) et les
/// photos qu'elles contiennent, entrelacées par date de prise de vue. `items`
/// ne diminue que par suppression **effective** (fichiers sur la carte ou
/// assets de la photothèque, voir `PhotoDeleter`) ou par retrait d'une source
/// (carte débranchée).
///
/// Toute mutation de tri (décision, note) passe par la session, jamais par
/// `PhotoItem` en direct : chaque appel alimente le **journal d'annulation**
/// (une entrée par geste, même en masse) et déclenche la **persistance**
/// débouncée — chaque photo est écrite dans le `SessionStore` de **sa** source
/// (routage par `origin`), c'est ce qui rend le tri reprennable par source
/// après un redémarrage de l'app.
@MainActor
@Observable
final class CullSession {
    /// Identité **stable de la session**, posée une fois à l'init et jamais
    /// modifiée (Batch H5). C'est elle qui doit keyer la grille
    /// (`.id(session.id)`) : keyer sur la source *primaire* était fragile — en
    /// combiné, retirer le slot primaire (carte débranchée) change
    /// `source`, ce qui recréait `GridView` en pleine présentation et laissait
    /// un viewer/sheet orphelin (barre grisée, taps morts). Ne change que
    /// lorsqu'une **nouvelle** session est ouverte (vrai changement de source).
    let id = UUID()

    /// Les sources actives, dans l'ordre d'ajout. Jamais vide : la première
    /// est la source **primaire** (celle qui a ouvert la session) et porte
    /// l'orientation par défaut, la restauration au lancement et le diagnostic.
    private(set) var slots: [SourceSlot]
    private(set) var items: [PhotoItem]

    /// Source primaire : compat des appelants mono-source (icône de barre,
    /// restauration). En combiné, préférer `sources`. Pour l'identité de vue,
    /// utiliser `id` (stable), pas cette valeur (qui peut muter).
    var source: PhotoSource { slots[0].source }
    var sources: [PhotoSource] { slots.map(\.source) }
    var isCombined: Bool { slots.count > 1 }

    /// Store primaire — porte l'album de destination, l'état « confirmé » et le
    /// voyage initiaux ; à la sauvegarde, ces réglages **de session** sont
    /// recopiés dans tous les stores (une source rouverte seule les retrouve).
    private var primaryStore: SessionStore { slots[0].store }

    /// Vrai si **toutes** les sources sont adossées à la photothèque : garder =
    /// ajouter à l'album, pas d'export/partage d'original, suppression
    /// photothèque. En combiné (au moins une carte), c'est faux — l'UI décide
    /// alors **par photo** (`PhotoItem.isLibraryBacked`).
    var isLibraryOnly: Bool { slots.allSatisfy { $0.source.isLibrary } }
    /// Vrai si au moins une source est un dossier (carte SD, disque, local) :
    /// gouverne l'export fichiers, le partage d'originaux et la surveillance
    /// de déconnexion.
    var hasFileSource: Bool {
        slots.contains { if case .folder = $0.source { true } else { false } }
    }
    /// Vrai si au moins une source est adossée à la photothèque.
    var hasLibrarySource: Bool { slots.contains { $0.source.isLibrary } }

    /// Une entrée d'annulation : l'état (décision + note) des photos touchées
    /// **avant** le geste. Annuler = restaurer ces valeurs.
    private struct UndoEntry {
        struct Change {
            let item: PhotoItem
            let decision: CullDecision
            let rating: Int
        }
        var changes: [Change]
    }

    private var undoStack: [UndoEntry] = []
    var canUndo: Bool { !undoStack.isEmpty }

    /// Album de destination des enregistrements (idée 8bis). Mutable en
    /// direct par l'UI (bindings du réglage) ; chaque changement repart vers
    /// la persistance débouncée. Réglage **de session**, partagé par toutes
    /// les sources.
    var albumDestination: AlbumDestination {
        didSet { persistSoon() }
    }

    /// Vrai dès que l'utilisateur a validé le choix d'album une fois (premier
    /// enregistrement ou passage par le réglage) : on ne redemande plus.
    private(set) var albumConfirmed: Bool

    /// Mode Voyage (idée 15) : mutable en direct par l'UI (bindings du
    /// réglage), chaque changement repart vers la persistance débouncée. Un
    /// voyage vaut pour **toutes** les sources de la session.
    var trip: TripMode {
        didSet { persistSoon() }
    }

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Init désigné (Batch H5) : compose la session à partir d'une ou plusieurs
    /// sources déjà chargées. Les réglages de session (album, voyage) sont lus
    /// sur le store primaire.
    init(slots: [SourceSlot], items: [PhotoItem]) {
        precondition(!slots.isEmpty, "une session a toujours au moins une source")
        self.slots = slots
        let primaryStore = slots[0].store
        self.albumDestination = primaryStore.album
        self.albumConfirmed = primaryStore.albumConfirmed
        self.trip = primaryStore.trip
        // Rattache chaque photo à sa source (provenance + routage), puis
        // entrelace et déduplique (carte déjà copiée dans la pellicule).
        for slot in slots {
            for item in items where item.origin == nil && Self.owns(slot.source, item) {
                item.origin = slot.source
            }
        }
        self.items = Self.merged(items)
    }

    /// Init de compat mono-source (appelé par `ContentView.startSession`).
    convenience init(source: PhotoSource, items: [PhotoItem], store: SessionStore) {
        for item in items { item.origin = source }
        self.init(slots: [SourceSlot(source: source, store: store)], items: items)
    }

    // MARK: - Composition des sources (Batch H5)

    /// Ajoute une source à la session **vivante** : rattache ses photos, les
    /// entrelace avec l'existant (par date de prise de vue) et déduplique les
    /// doublons carte↔pellicule. La session courante n'est pas close — c'est
    /// tout l'intérêt du combiné.
    func addSource(_ source: PhotoSource, items newItems: [PhotoItem], store: SessionStore) {
        // Une même source ne s'ajoute pas deux fois (re-tap du menu) : on
        // remplace sa version en place — sans passer par le garde-fou « ne
        // jamais vider la session » de `removeSources`, puisqu'on ré-ajoute
        // aussitôt (cas de la source unique rechargée).
        if let existing = slots.firstIndex(where: { $0.source == source }) {
            let staleIDs = Set(items.filter { $0.origin == source }.map(\.id))
            items.removeAll { staleIDs.contains($0.id) }
            slots.remove(at: existing)
        }
        for item in newItems { item.origin = source }
        slots.append(SourceSlot(source: source, store: store))
        items = Self.merged(items + newItems)
        persistSoon()
    }

    /// Retire les sources correspondant au prédicat (carte débranchée en
    /// session combinée, ④). Leur état est flushé avant de lâcher le store,
    /// puis leurs photos quittent la session et le journal d'annulation. Ne
    /// fait rien si cela viderait la session (dernier slot) : l'appelant clôt
    /// alors la session entière comme avant.
    @discardableResult
    func removeSources(where predicate: (PhotoSource) -> Bool) -> Bool {
        let doomed = slots.filter { predicate($0.source) }
        guard !doomed.isEmpty, doomed.count < slots.count else { return false }
        let doomedSources = Set(doomed.map(\.source))
        for slot in doomed {
            let owned = items.filter { $0.origin == slot.source }
            slot.store.save(owned, album: albumDestination, albumConfirmed: albumConfirmed, trip: trip)
        }
        slots.removeAll { doomedSources.contains($0.source) }
        let doomedIDs = Set(
            items.filter { $0.origin.map(doomedSources.contains) ?? false }.map(\.id)
        )
        items.removeAll { doomedIDs.contains($0.id) }
        undoStack = undoStack.compactMap { entry in
            let kept = entry.changes.filter { !doomedIDs.contains($0.item.id) }
            return kept.isEmpty ? nil : UndoEntry(changes: kept)
        }
        persistSoon()
        return true
    }

    /// Vrai si la source « possède » l'item d'après son backing : un asset
    /// appartient à une source photothèque, un fichier à une source dossier
    /// (le chemin du fichier est sous le dossier). Sert au rattachement des
    /// items déjà fusionnés fournis à l'init désigné.
    private static func owns(_ source: PhotoSource, _ item: PhotoItem) -> Bool {
        switch (source, item.backing) {
        case (.folder(let url, _), .file(let fileURL)):
            // Par composants, pas par préfixe de chaîne : `/DCIM/100`
            // matcherait aussi `/DCIM/100_backup` (revue qualité).
            let folder = url.standardizedFileURL.pathComponents
            let file = fileURL.standardizedFileURL.pathComponents
            return file.count > folder.count && Array(file.prefix(folder.count)) == folder
        case (.album, .asset), (.library, .asset):
            return true
        default:
            return false
        }
    }

    /// Entrelace et déduplique la liste fusionnée : masque tout asset
    /// photothèque **créé par Peliculle** depuis un fichier de la carte encore
    /// présent dans la session (même photo, deux fois — Batch H5 ①), puis trie
    /// par date de prise de vue (repli sur la date fichier). Le tri d'affichage
    /// de la grille reste maître ensuite.
    private static func merged(_ all: [PhotoItem]) -> [PhotoItem] {
        let createdIDs = Set(all.compactMap { $0.isLibraryBacked ? nil : $0.savedAssetID })
        let deduplicated = createdIDs.isEmpty ? all : all.filter { item in
            guard case .asset(let asset) = item.backing else { return true }
            return !createdIDs.contains(asset.localIdentifier)
        }
        return deduplicated.sorted {
            ($0.captureDate ?? .distantPast) < ($1.captureDate ?? .distantPast)
        }
    }

    /// Vrai si la photo est visible dans le périmètre du voyage (tout passe
    /// quand le mode est inactif).
    func tripMatches(_ item: PhotoItem) -> Bool {
        trip.matches(item.captureDate)
    }

    func confirmAlbum() {
        albumConfirmed = true
        persistSoon()
    }

    /// Rapport de diagnostic de la persistance (voir `SessionStore`). En
    /// combiné, concatène le rapport de chaque source active.
    func diagnosticsReport() -> String {
        slots
            .map { slot in "▸ \(slot.source.displayName)\n\(slot.store.diagnosticsReport())" }
            .joined(separator: "\n\n")
    }

    // MARK: - Mutations de tri (annulables)

    /// Applique une décision à une ou plusieurs photos. Les photos déjà dans
    /// cet état sont ignorées : pas d'entrée d'annulation fantôme.
    func setDecision(_ decision: CullDecision, for targets: [PhotoItem]) {
        mutate(targets.filter { $0.decision != decision }) { $0.decision = decision }
    }

    /// Applique une note 0–5 à une ou plusieurs photos.
    func setRating(_ rating: Int, for targets: [PhotoItem]) {
        mutate(targets.filter { $0.rating != rating }) { $0.rating = rating }
    }

    /// Idées 3/4 — élit la meilleure photo d'une pile ou d'un duel : garde la
    /// gagnante, rejette toutes les autres du groupe. **Une seule** entrée
    /// d'annulation : un ↩︎ restaure tout le groupe.
    func elect(_ winner: PhotoItem, among group: [PhotoItem]) {
        let changed = group.filter { item in
            item.id == winner.id ? item.decision != .keep : item.decision != .reject
        }
        guard !changed.isEmpty else { return }
        pushUndo(for: changed)
        for item in changed {
            item.decision = item.id == winner.id ? .keep : .reject
        }
        persistSoon()
    }

    private func mutate(_ changed: [PhotoItem], _ apply: (PhotoItem) -> Void) {
        guard !changed.isEmpty else { return }
        pushUndo(for: changed)
        for item in changed { apply(item) }
        persistSoon()
    }

    private func pushUndo(for changed: [PhotoItem]) {
        undoStack.append(UndoEntry(changes: changed.map {
            UndoEntry.Change(item: $0, decision: $0.decision, rating: $0.rating)
        }))
        // Borne large : au-delà, les entrées les plus anciennes n'ont plus de
        // sens pour l'utilisateur et ne valent pas leur mémoire.
        if undoStack.count > 500 { undoStack.removeFirst() }
    }

    /// Annule le dernier geste de tri (décision ou note, unitaire ou en masse).
    func undo() {
        guard let entry = undoStack.popLast() else { return }
        for change in entry.changes {
            change.item.decision = change.decision
            change.item.rating = change.rating
        }
        persistSoon()
    }

    // MARK: - Suppression

    /// Retire de la session des photos supprimées de leur source. Irréversible
    /// par nature : les entrées d'annulation qui les référencent sont purgées
    /// pour qu'un ↩︎ ne semble jamais « ne rien faire ».
    func remove(_ removed: [PhotoItem]) {
        let ids = Set(removed.map(\.id))
        items.removeAll { ids.contains($0.id) }
        undoStack = undoStack.compactMap { entry in
            let kept = entry.changes.filter { !ids.contains($0.item.id) }
            return kept.isEmpty ? nil : UndoEntry(changes: kept)
        }
        persistSoon()
    }

    // MARK: - Persistance

    /// Sauvegarde débouncée : le tri rapide enchaîne les gestes, inutile
    /// d'écrire le fichier à chacun.
    func persistSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    /// Sauvegarde immédiate (passage en arrière-plan, déconnexion de carte).
    /// Chaque source écrit **ses** photos (routage par `origin`) dans son
    /// propre fichier ; les réglages de session (album, voyage) sont recopiés
    /// dans chacun.
    func persistNow() {
        saveTask?.cancel()
        for slot in slots {
            let owned = items.filter { $0.origin == slot.source }
            slot.store.save(owned, album: albumDestination, albumConfirmed: albumConfirmed, trip: trip)
        }
    }

    // MARK: - Lectures

    var keepers: [PhotoItem] { items.filter { $0.decision == .keep } }
    var keeperCount: Int { keepers.count }

    var rejected: [PhotoItem] { items.filter { $0.decision == .reject } }
}
