import Foundation

/// Libellé « N photo » / « N photos » — accord singulier/pluriel partagé (0
/// reste singulier). Un seul point de vérité pour la grille (pilule) et le hub
/// Sources, au lieu de dupliquer la règle dans chaque vue.
func photoCountText(_ count: Int) -> String {
    count > 1
        ? String(localized: "\(count) photos")
        : String(localized: "\(count) photo")
}

/// Jalon 10 (idée 17) — la provenance des photos d'une session. **Une source
/// à la fois, jamais de fusion** : changer de source clôt la session courante
/// (flush de la persistance) et en ouvre une neuve. Le workflow entier
/// (grille, viewer, tri rapide, Mode Voyage, badges) s'applique quelle que
/// soit la source.
enum PhotoSource: Hashable {
    /// Dossier choisi via le sélecteur de fichiers (comportement historique,
    /// F1). Le `kind` affine l'icône et le libellé selon le support détecté.
    case folder(URL, kind: FolderKind)
    /// Album de la photothèque iOS (`PHAssetCollection.localIdentifier`).
    case album(id: String, title: String)
    /// La photothèque, bornée par une période choisie **au fetch**
    /// (`LibraryScope`) — jamais un filtre mémoire.
    case library(LibraryScope)

    /// Nom affiché en titre de la grille (orientation : savoir où on est).
    var displayName: String {
        switch self {
        case .folder(let url, _): return url.lastPathComponent
        case .album(_, let title): return title
        case .library(let scope): return scope.displayName
        }
    }

    /// Icône de type, portée par le bouton Source et le sous-titre.
    var icon: String {
        switch self {
        case .folder(_, let kind): return kind.icon
        case .album: return "photo.stack"
        case .library: return "photo.on.rectangle.angled"
        }
    }

    /// Vrai pour les sources adossées à la photothèque : les photos y sont
    /// **déjà** → « enregistrer » devient « ajouter à l'album » (non
    /// destructif), pas d'export de fichier, pas de carte à surveiller,
    /// suppression = suppression de la photothèque (PhotoKit, confirmée par
    /// le système en plus de notre alerte).
    var isLibrary: Bool {
        if case .folder = self { return false }
        return true
    }

    // MARK: - Persistance de la dernière source (restauration au lancement)

    /// Représentation stockable dans `UserDefaults`. Le dossier n'encode pas
    /// son URL : sa restauration passe par le bookmark security-scoped
    /// (`FolderAccess`), seule voie valable après relancement.
    var storageValue: String {
        switch self {
        case .folder: return "folder"
        case .album(let id, let title): return "album|\(id)|\(title)"
        case .library(let scope): return scope.storageValue
        }
    }

    /// Relit une source depuis `storageValue`. `folder` est signalé par nil
    /// accompagné de `wantsFolder` = true côté appelant (l'URL vit dans le
    /// bookmark) — ici on ne reconstruit que les sources photothèque.
    static func fromStorage(_ value: String) -> PhotoSource? {
        if let scope = LibraryScope.fromStorage(value) { return .library(scope) }
        guard value.hasPrefix("album|") else { return nil }
        let parts = value.dropFirst("album|".count)
        guard let separator = parts.firstIndex(of: "|") else { return nil }
        let id = String(parts[..<separator])
        let title = String(parts[parts.index(after: separator)...])
        guard !id.isEmpty else { return nil }
        return .album(id: id, title: title)
    }
}

/// Période bornant une source photothèque **au moment du fetch** (prédicat
/// `creationDate` PhotoKit) — jamais un filtre mémoire : sur une photothèque
/// de 10 000 photos, les items hors période ne sont jamais créés, et tout
/// l'aval (grille, passes d'analyse, tri) travaille sur la seule période.
enum LibraryScope: Hashable {
    /// Toute la photothèque (grand ménage assumé) — comportement historique.
    case all
    /// Les n derniers jours, glissants (recalculés à chaque ouverture).
    case lastDays(Int)
    /// Plage de jours, bornes incluses ; fin nil = en cours (voyage).
    case range(start: Date, end: Date?)

    /// Bornes concrètes pour le prédicat de fetch (fin **exclusive** :
    /// lendemain du dernier jour). nil = pas de borne.
    var fetchBounds: (start: Date?, end: Date?) {
        let calendar = Calendar.current
        switch self {
        case .all:
            return (nil, nil)
        case .lastDays(let days):
            let start = calendar.date(
                byAdding: .day, value: -(days - 1),
                to: calendar.startOfDay(for: .now)
            )
            return (start, nil)
        case .range(let start, let end):
            let lower = calendar.startOfDay(for: start)
            let upper = end.flatMap {
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0))
            }
            return (lower, upper)
        }
    }

    /// Titre de la grille (orientation) : la période dit ce qu'on regarde.
    var displayName: String {
        switch self {
        case .all:
            return String(localized: "Toutes les photos")
        case .lastDays(let days):
            return String(localized: "\(days) derniers jours")
        case .range(let start, let end):
            let from = start.formatted(date: .abbreviated, time: .omitted)
            guard let end else {
                return String(localized: "Depuis le \(from)")
            }
            return "\(from) – \(end.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    // MARK: - Persistance (restauration au lancement)

    var storageValue: String {
        switch self {
        case .all:
            return "library"
        case .lastDays(let days):
            return "library|days|\(days)"
        case .range(let start, let end):
            let lower = start.timeIntervalSinceReferenceDate
            let upper = end.map { String($0.timeIntervalSinceReferenceDate) } ?? "-"
            return "library|range|\(lower)|\(upper)"
        }
    }

    static func fromStorage(_ value: String) -> LibraryScope? {
        if value == "library" { return .all }
        let parts = value.split(separator: "|").map(String.init)
        guard parts.count >= 3, parts[0] == "library" else { return nil }
        switch parts[1] {
        case "days" where parts.count == 3:
            guard let days = Int(parts[2]), days > 0 else { return nil }
            return .lastDays(days)
        case "range" where parts.count == 4:
            guard let lower = TimeInterval(parts[2]) else { return nil }
            let start = Date(timeIntervalSinceReferenceDate: lower)
            // « - » (fin ouverte) ne parse pas en TimeInterval → nil, voulu.
            let end = TimeInterval(parts[3]).map(Date.init(timeIntervalSinceReferenceDate:))
            return .range(start: start, end: end)
        default:
            return nil
        }
    }
}

/// Support physique derrière une source dossier, détecté au moment du choix
/// (et de la restauration) depuis les propriétés du volume. iOS ne distingue
/// pas nativement une carte SD d'un disque externe : les deux sont des
/// volumes amovibles. On tranche par la structure `DCIM/` (norme DCF,
/// systématique sur les cartes d'appareil photo) — une carte sans DCIM sera
/// donc classée « disque externe », sans conséquence fonctionnelle.
enum FolderKind: String, Hashable, Codable {
    /// Volume externe avec dossier DCIM : carte d'appareil photo.
    case cameraCard
    /// Volume externe sans DCIM : disque dur, SSD, clé USB…
    case externalDrive
    /// Dossier iCloud Drive.
    case icloud
    /// Dossier du stockage interne (« Sur mon iPhone », autre app…).
    case local

    var icon: String {
        switch self {
        case .cameraCard: return "sdcard"
        case .externalDrive: return "externaldrive"
        case .icloud: return "icloud"
        case .local: return "folder"
        }
    }

    /// Libellé de support pour la provenance par photo (viewer, Batch H5 ⑥).
    var label: String {
        switch self {
        case .cameraCard: return String(localized: "Carte SD")
        case .externalDrive: return String(localized: "Disque")
        case .icloud: return "iCloud"
        case .local: return String(localized: "Dossier")
        }
    }

    /// Détermine le support d'un dossier fraîchement sélectionné. Doit être
    /// appelé **pendant que le scope de sécurité est ouvert** ; lit le volume
    /// hors du main thread (une carte lente peut bloquer plusieurs secondes).
    /// En cas de doute (propriétés illisibles), retombe sur `.local` — le
    /// libellé historique « Dossier ».
    static func detect(for url: URL) async -> FolderKind {
        await Task.detached(priority: .userInitiated) {
            let keys: Set<URLResourceKey> = [
                .isUbiquitousItemKey,
                .volumeIsInternalKey,
                .volumeIsRemovableKey,
                .volumeIsEjectableKey,
                .volumeURLKey,
            ]
            guard let values = try? url.resourceValues(forKeys: keys) else {
                return .local
            }
            if values.isUbiquitousItem == true { return .icloud }

            let isExternal = values.volumeIsInternal == false
                || values.volumeIsRemovable == true
                || values.volumeIsEjectable == true
            guard isExternal else { return .local }

            return hasDCIM(pickedFolder: url, volumeRoot: values.volume)
                ? .cameraCard
                : .externalDrive
        }.value
    }

    /// Cherche la structure DCF : le dossier choisi est `DCIM` (ou dedans),
    /// ou bien `DCIM/` existe à la racine du volume ou du dossier choisi
    /// (cas où l'utilisateur sélectionne la carte entière).
    private static func hasDCIM(pickedFolder url: URL, volumeRoot: URL?) -> Bool {
        if url.pathComponents.contains("DCIM") { return true }
        for parent in [volumeRoot, url].compactMap({ $0 }) {
            var isDirectory: ObjCBool = false
            let dcim = parent.appendingPathComponent("DCIM", isDirectory: true)
            if FileManager.default.fileExists(atPath: dcim.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return true
            }
        }
        return false
    }
}

/// Demande de changement de source émise par l'UI (bouton Source de la
/// grille, accueil) et résolue par `ContentView` — qui seul ouvre le
/// `fileImporter`, la sheet d'albums ou la session directement.
enum SourceRequest {
    /// Ouvrir le sélecteur de dossier système.
    case folder
    /// Ouvrir la sheet de choix d'album.
    case albumPicker
    /// Ouvrir la photothèque — passe par le choix de période (`LibraryScope`).
    case library
    /// Rouvrir un album précis (entrée « récents »).
    case album(id: String, title: String)
    /// Rouvrir un dossier récent via son bookmark (entrée « récents »).
    case recentFolder(RecentFolder)
    /// Clore la session et revenir à l'écran d'accueil (sélecteur de source
    /// plein écran) — la dernière source reste mémorisée pour le relancement.
    case welcome
    /// Ouvrir le récap des **sources actives** (les voir, en retirer, en
    /// ajouter) — Batch H5, session combinée.
    case manage
    /// Retirer une source précise de la session combinée (depuis le récap).
    /// Sans effet si c'est la dernière source (passer par `.welcome`).
    case remove(PhotoSource)
    /// **Ajouter** la source décrite à la session en cours au lieu de la
    /// remplacer (Batch H5, composition combinée : carte SD + photothèque dans
    /// une même grille). La demande interne (`.folder`, `.library`,
    /// `.albumPicker`, `.album`, `.recentFolder`) suit son flux habituel de
    /// choix, mais résout en ajout et non en changement de source.
    indirect case add(SourceRequest)
}

/// Albums récemment triés (Jalon 10) — proposés dans le menu Source pour y
/// revenir d'un tap. Persistés en JSON dans `UserDefaults`, les plus récents
/// d'abord, bornés à 5.
struct RecentAlbum: Codable, Identifiable, Equatable {
    let id: String
    let title: String

    private static let storageKey = "peliculle.recentAlbums"

    static func load() -> [RecentAlbum] {
        RecentList.load(key: storageKey)
    }

    static func record(id: String, title: String, in list: inout [RecentAlbum]) {
        RecentList.record(RecentAlbum(id: id, title: title), in: &list, key: storageKey, limit: 5)
    }

    static func remove(id: String, in list: inout [RecentAlbum]) {
        RecentList.remove(id: id, from: &list, key: storageKey)
    }
}

/// Dossiers récemment triés — même rôle que `RecentAlbum`, avec en plus le
/// **bookmark security-scoped** qui permet de rouvrir le volume d'un tap.
/// Résolution au tap seulement : sonder la disponibilité d'un volume à
/// l'ouverture du menu peut bloquer plusieurs secondes (voir `FolderAccess`) ;
/// un volume absent (carte débranchée) donne le message de re-sélection.
struct RecentFolder: Codable, Identifiable, Equatable {
    /// Chemin du dossier : identité de dédoublonnage entre sélections.
    let path: String
    /// Nom affiché dans le menu (dernier composant du chemin).
    let name: String
    /// Support détecté au moment du choix — porte l'icône du menu.
    let kind: FolderKind
    let bookmark: Data

    var id: String { path }

    private static let storageKey = "peliculle.recentFolders"

    static func load() -> [RecentFolder] {
        RecentList.load(key: storageKey)
    }

    static func record(url: URL, kind: FolderKind, bookmark: Data, in list: inout [RecentFolder]) {
        let entry = RecentFolder(
            path: url.path,
            name: url.lastPathComponent,
            kind: kind,
            bookmark: bookmark
        )
        RecentList.record(entry, in: &list, key: storageKey, limit: 5)
    }

    static func remove(id: String, in list: inout [RecentFolder]) {
        RecentList.remove(id: id, from: &list, key: storageKey)
    }
}
