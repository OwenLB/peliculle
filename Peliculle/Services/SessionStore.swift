import CryptoKit
import Foundation
import Photos

/// Persistance du tri **par source** (Jalon 10) : décisions, notes et état
/// « déjà enregistré » survivent au redémarrage de l'app et au changement de
/// source — chaque source garde sa propre session, y revenir la reprend. Un
/// fichier JSON par source triée, nommé d'après une empreinte de son identité,
/// dans Application Support (jamais sur la carte SD — lecture seule stricte).
///
/// Identité des photos, **adaptée au backing** :
/// - fichier : **nom + taille**, stable d'un montage de carte à l'autre
///   (l'URL absolue peut changer), la taille protège d'un fichier remplacé
///   sous le même nom ;
/// - asset photothèque : **`localIdentifier`**, stable par construction.
///
/// Isolé au **main actor** (objet d'état de la session, comme `CullSession`) :
/// `apply` et `save` lisent/écrivent l'état de tri des `PhotoItem`, isolé main
/// actor lui aussi. Seuls le chargement initial et les écritures disque vivent
/// hors main thread — init `nonisolated` en tâche détachée, `writeQueue`.
@MainActor
final class SessionStore {

    private nonisolated struct Record: Codable {
        var decision: CullDecision
        var rating: Int
        var savedToLibrary: Bool
        /// `localIdentifier` de l'asset créé par une copie fichier → pellicule
        /// (Batch H5, ① déduplication). Optionnel pour rester décodable depuis
        /// les fichiers d'avant ce batch et pour les assets (rien créé).
        var savedAssetID: String?
    }

    private nonisolated struct Payload: Codable {
        var version: Int
        /// Description lisible de la source (chemin de dossier, album…) —
        /// nom de champ historique conservé pour décoder les fichiers
        /// antérieurs au Jalon 10.
        var folderPath: String
        var savedAt: Date
        /// Optionnels pour rester décodable depuis les fichiers v1 (batch A).
        var album: AlbumDestination?
        var albumConfirmed: Bool?
        /// Mode Voyage (Jalon 9) — optionnel pour les fichiers antérieurs.
        var trip: TripMode?
        /// Identité stable calculée au moment de l'écriture (diagnostic).
        var identity: String?
        var records: [String: Record]
    }

    private let sourceDescription: String
    private let fileURL: URL
    private var records: [String: Record]
    /// Vrai pour une source dossier : seules les sessions de dossier peuvent
    /// se récupérer par contenu (les clés d'asset sont stables d'office).
    private let isFolderSource: Bool

    /// Traces pour le diagnostic de session (menu ⚙️ de la grille).
    let identity: String
    private(set) var loadedFromDisk = false
    private(set) var recoveredFrom: String?

    /// Album de destination choisi pour cette session (idée 8bis) et
    /// « l'utilisateur a validé ce choix au moins une fois » (le premier
    /// enregistrement ne redemande alors plus).
    private(set) var album: AlbumDestination
    private(set) var albumConfirmed: Bool
    /// Mode Voyage de la session (Jalon 9, idée 15).
    private(set) var trip: TripMode

    /// File série dédiée aux écritures : garantit l'ordre des sauvegardes
    /// successives sans bloquer le main thread.
    private let writeQueue = DispatchQueue(label: "peliculle.sessionStore", qos: .utility)

    /// Dernier échec d'écriture (revue qualité) : les erreurs étaient avalées
    /// en silence alors qu'elles signifient « décisions de tri perdues au
    /// prochain redémarrage ». Muté sur `writeQueue`, lu via `writeQueue.sync`
    /// par le rapport de diagnostic (menu ⚙️) — appel rare, coût nul.
    /// `nonisolated(unsafe)` : la synchronisation est assurée à la main par
    /// `writeQueue` (file série), pas par l'isolation d'acteur.
    private nonisolated(unsafe) var lastWriteFailure: String?

    // MARK: - Chargement

    /// Charge (hors main thread) l'état de tri sauvegardé pour cette source,
    /// s'il existe. Pour un **dossier**, si l'empreinte ne retrouve rien
    /// (point de montage inédit, identité de volume indisponible sur ce
    /// lecteur…), tente une **récupération par contenu** parmi les sessions
    /// existantes : les clés d'enregistrement (nom + taille) identifient la
    /// carte mieux que n'importe quel chemin absolu.
    static func load(for source: PhotoSource, items: [PhotoItem]) async -> SessionStore {
        // Les clés de récupération se calculent ici (lecture de propriétés
        // immuables, coût nul) : la tâche détachée ne reçoit que des valeurs.
        let recoveryKeys = Set(items.map { Self.key(for: $0) })
        return await Task.detached(priority: .userInitiated) {
            SessionStore(source: source, recoveryKeys: recoveryKeys)
        }.value
    }

    /// Relit (hors main thread) le Mode Voyage persisté de la session
    /// photothèque **sans ouvrir de session** : la sheet de période propose
    /// de filtrer sur le voyage en cours avant tout chargement. nil si aucun
    /// voyage actif n'est enregistré.
    static func peekLibraryTrip() async -> TripMode? {
        await Task.detached(priority: .userInitiated) {
            let fileURL = sessionsDirectory
                .appendingPathComponent(fingerprint(of: "library"))
                .appendingPathExtension("json")
            guard let data = try? Data(contentsOf: fileURL),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data),
                  let trip = payload.trip, trip.isActive else {
                return nil
            }
            return trip
        }.value
    }

    /// Relit (hors main thread) les Modes Voyage **actifs** persistés par
    /// toutes les sessions — dossiers, albums, photothèque : un voyage
    /// configuré sur une carte SD est un voyage comme un autre. Du plus
    /// ancien au plus récent enregistrement, pour que l'adoption dans
    /// l'historique global (`SavedTrip`) laisse le plus récent en tête —
    /// c'est aussi la migration des voyages d'avant le registre.
    static func peekActiveTrips() async -> [TripMode] {
        await Task.detached(priority: .userInitiated) {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: sessionsDirectory, includingPropertiesForKeys: nil
            )) ?? []
            return files
                .compactMap { url -> Payload? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? JSONDecoder().decode(Payload.self, from: data)
                }
                .filter { $0.trip?.isActive == true }
                .sorted { $0.savedAt < $1.savedAt }
                .compactMap(\.trip)
        }.value
    }

    /// Désactive, dans **toutes** les sessions persistées, les voyages
    /// supprimés de l'historique global (`SavedTrip`) : un fichier de session
    /// (carte SD, album, photothèque) portant encore le voyage actif le
    /// ferait ressusciter au prochain passage (`peekLibraryTrip`, adoption
    /// des voyages actifs). Les décisions de tri du fichier sont intactes —
    /// seul le drapeau tombe. La session **ouverte** ne peut pas être
    /// concernée : son voyage actif n'est jamais proposé à la suppression.
    static func deactivateTrips(withIDs ids: Set<String>) async {
        await Task.detached(priority: .utility) {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: sessionsDirectory, includingPropertiesForKeys: nil
            )) ?? []
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      var payload = try? JSONDecoder().decode(Payload.self, from: data),
                      let trip = payload.trip, trip.isActive,
                      ids.contains(SavedTrip(trip).id) else { continue }
                payload.trip?.isActive = false
                guard let updated = try? JSONEncoder().encode(payload) else { continue }
                try? updated.write(to: file, options: .atomic)
            }
        }.value
    }

    /// `nonisolated` pour s'exécuter dans la tâche détachée de `load` (I/O
    /// disque) : tout se calcule en variables locales, `self` n'est assigné
    /// qu'à la fin — l'objet ne devient partageable qu'entièrement construit.
    private nonisolated init(source: PhotoSource, recoveryKeys: Set<String>) {
        let sourceDescription: String
        let identity: String
        let isFolderSource: Bool
        switch source {
        case .folder(let url, _):
            let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
            sourceDescription = standardized.path
            identity = Self.stableIdentity(for: url)
            isFolderSource = true
        case .album(let id, let title):
            sourceDescription = "Album « \(title) »"
            identity = "album|\(id)"
            isFolderSource = false
        case .library:
            sourceDescription = "Photothèque complète"
            identity = "library"
            isFolderSource = false
        }
        let fileURL = Self.sessionsDirectory
            .appendingPathComponent(Self.fingerprint(of: identity))
            .appendingPathExtension("json")

        var records: [String: Record] = [:]
        var album = AlbumDestination()
        var albumConfirmed = false
        var trip = TripMode()
        var loadedFromDisk = false
        var recoveredFrom: String?

        if let data = try? Data(contentsOf: fileURL),
           let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            records = Self.normalized(payload.records)
            album = payload.album ?? AlbumDestination()
            albumConfirmed = payload.albumConfirmed ?? false
            trip = payload.trip ?? TripMode()
            loadedFromDisk = true
        }

        if isFolderSource, records.isEmpty,
           let recovered = Self.recoverFromContent(
               keys: recoveryKeys,
               currentFileURL: fileURL,
               sourceDescription: sourceDescription,
               identity: identity
           ) {
            records = recovered.records
            album = recovered.album
            albumConfirmed = recovered.albumConfirmed
            trip = recovered.trip
            recoveredFrom = recovered.file
        }

        self.sourceDescription = sourceDescription
        self.identity = identity
        self.isFolderSource = isFolderSource
        self.fileURL = fileURL
        self.records = records
        self.album = album
        self.albumConfirmed = albumConfirmed
        self.trip = trip
        self.loadedFromDisk = loadedFromDisk
        self.recoveredFrom = recoveredFrom
    }

    // MARK: - Récupération par contenu (sources dossier uniquement)

    /// État adopté depuis une session existante — porté par des valeurs pour
    /// traverser la frontière de l'init `nonisolated`.
    private nonisolated struct RecoveredState {
        var records: [String: Record]
        var album: AlbumDestination
        var albumConfirmed: Bool
        var trip: TripMode
        var file: String
    }

    /// Filet de sécurité de la reprise de session : aucune donnée pour notre
    /// empreinte → cherche le fichier de session dont les enregistrements
    /// recoupent le mieux les photos scannées (`keys`), adopte son contenu
    /// (état de tri **et** réglage d'album) et le migre sous la nouvelle
    /// empreinte. Seuil : au moins 3 clés communes (ou toutes si la session en
    /// a moins), une clé combinant nom et taille de fichier — collision entre
    /// deux cartes différentes hautement improbable.
    private nonisolated static func recoverFromContent(
        keys: Set<String>,
        currentFileURL: URL,
        sourceDescription: String,
        identity: String
    ) -> RecoveredState? {
        guard !keys.isEmpty else { return nil }
        let fileManager = FileManager.default
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: sessionsDirectory, includingPropertiesForKeys: nil
        ) else { return nil }

        var best: (file: URL, payload: Payload, overlap: Int)?
        for file in candidates
        where file.pathExtension == "json" && file.lastPathComponent != currentFileURL.lastPathComponent {
            guard let data = try? Data(contentsOf: file),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
                continue
            }
            let candidateRecords = normalized(payload.records)
            let overlap = candidateRecords.keys.filter(keys.contains).count
            guard overlap >= min(3, candidateRecords.count),
                  overlap > (best?.overlap ?? 0) else {
                continue
            }
            best = (file, payload, overlap)
        }
        guard let best else { return nil }

        let recovered = RecoveredState(
            records: normalized(best.payload.records),
            album: best.payload.album ?? AlbumDestination(),
            albumConfirmed: best.payload.albumConfirmed ?? false,
            trip: best.payload.trip ?? TripMode(),
            file: best.file.lastPathComponent
        )

        // Migration : réécrit sous la nouvelle empreinte et supprime l'ancien
        // fichier, pour ne pas laisser deux comptabilités de la même carte.
        let migrated = Payload(
            version: 3,
            folderPath: sourceDescription,
            savedAt: .now,
            album: recovered.album,
            albumConfirmed: recovered.albumConfirmed,
            trip: recovered.trip,
            identity: identity,
            records: recovered.records
        )
        if let data = try? JSONEncoder().encode(migrated) {
            try? data.write(to: currentFileURL, options: .atomic)
            try? fileManager.removeItem(at: best.file)
        }
        return recovered
    }

    // MARK: - Application au scan

    /// Réapplique l'état sauvegardé aux photos fraîchement énumérées.
    /// Renvoie le nombre de photos restaurées avec une décision ou une note.
    @discardableResult
    func apply(to items: [PhotoItem]) -> Int {
        var restored = 0
        for item in items {
            guard let record = records[Self.key(for: item)] else { continue }
            item.decision = record.decision
            item.rating = record.rating
            item.savedToLibrary = record.savedToLibrary
            item.savedAssetID = record.savedAssetID
            if record.decision != .undecided || record.rating > 0 { restored += 1 }
        }
        return restored
    }

    // MARK: - Sauvegarde

    /// Photographie l'état courant (sur le thread appelant, coût négligeable)
    /// puis écrit sur disque via la file série. On ne stocke que les photos
    /// sorties de l'état par défaut, pour garder le fichier minimal ; si tout
    /// est redevenu vierge (réglage d'album compris), le fichier est supprimé.
    func save(_ items: [PhotoItem], album: AlbumDestination, albumConfirmed: Bool, trip: TripMode) {
        var snapshot: [String: Record] = [:]
        for item in items {
            guard item.decision != .undecided || item.rating > 0 || item.savedToLibrary else {
                continue
            }
            snapshot[Self.key(for: item)] = Record(
                decision: item.decision,
                rating: item.rating,
                savedToLibrary: item.savedToLibrary,
                savedAssetID: item.savedAssetID
            )
        }
        records = snapshot
        self.album = album
        self.albumConfirmed = albumConfirmed
        self.trip = trip

        let payload = Payload(
            version: 3,
            folderPath: sourceDescription,
            savedAt: .now,
            album: album,
            albumConfirmed: albumConfirmed,
            trip: trip,
            identity: identity,
            records: snapshot
        )
        let isPristine = snapshot.isEmpty && album == AlbumDestination()
            && !albumConfirmed && trip == TripMode()
        let fileURL = self.fileURL
        writeQueue.async { [weak self] in
            if isPristine {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            do {
                let data = try JSONEncoder().encode(payload)
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: .atomic)
                self?.lastWriteFailure = nil
            } catch {
                // Trace pour le diagnostic : perdre une écriture = perdre du
                // tri au prochain lancement, ça ne doit plus être invisible.
                self?.lastWriteFailure =
                    "\(Date.now.formatted(date: .abbreviated, time: .standard)) — \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Clés

    /// Préfixe des clés d'asset : les distingue des clés fichier (qui ne
    /// contiennent jamais ce motif en tête) et les protège de la
    /// normalisation des anciens formats.
    private nonisolated static let assetKeyPrefix = "asset|"

    /// Clé d'une photo, intrinsèque à son backing :
    /// - fichier : **nom + taille**, aucun chemin — les chemins (absolus
    ///   comme relatifs) se sont révélés instables d'un montage à l'autre
    ///   (File Provider, point de montage variable). Collision possible si
    ///   deux fichiers homonymes de même taille coexistent dans des
    ///   sous-dossiers différents — improbable sur une structure DCIM, et
    ///   l'effet se limiterait à partager leur état de tri ;
    /// - asset : `localIdentifier`, stable entre lancements par PhotoKit.
    private nonisolated static func key(for item: PhotoItem) -> String {
        switch item.backing {
        case .file(let url):
            return "\(url.lastPathComponent)#\(item.fileSize ?? 0)"
        case .asset(let asset):
            return assetKeyPrefix + asset.localIdentifier
        }
    }

    /// Convertit les clés des fichiers de session antérieurs (chemin relatif
    /// ou absolu + taille) vers le format nom + taille. Les clés d'asset
    /// passent inchangées.
    private nonisolated static func normalized(_ records: [String: Record]) -> [String: Record] {
        Dictionary(
            records.map { key, value in (normalizedKey(key), value) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Interne (pas `private`) pour être couverte par les tests unitaires —
    /// la migration des anciens formats de clés ne se rejoue pas sur device.
    nonisolated static func normalizedKey(_ key: String) -> String {
        guard !key.hasPrefix(assetKeyPrefix) else { return key }
        guard let hash = key.lastIndex(of: "#") else {
            return (key as NSString).lastPathComponent
        }
        let path = String(key[..<hash])
        let size = String(key[key.index(after: hash)...])
        return "\((path as NSString).lastPathComponent)#\(size)"
    }

    /// Identité **stable** du dossier trié, indépendante du point de montage :
    /// iOS peut remonter la même carte SD sous un chemin différent à chaque
    /// branchement, donc hacher le chemin absolu perdrait la session à la
    /// reconnexion. On préfère UUID du volume (ou son nom à défaut) + chemin
    /// relatif dans le volume ; repli sur le chemin absolu pour un dossier
    /// local sans identité de volume.
    private nonisolated static func stableIdentity(for folderURL: URL) -> String {
        let url = folderURL.standardizedFileURL.resolvingSymlinksInPath()
        let values = try? url.resourceValues(
            forKeys: [.volumeUUIDStringKey, .volumeNameKey, .volumeURLKey]
        )
        guard let volumeID = values?.volumeUUIDString ?? values?.volumeName else {
            return url.path
        }
        var relative = url.path
        if let volumeRoot = values?.volume?.standardizedFileURL.resolvingSymlinksInPath().path,
           relative.hasPrefix(volumeRoot) {
            relative = String(relative.dropFirst(volumeRoot.count))
        }
        return "\(volumeID)|\(relative)"
    }

    // MARK: - Diagnostic

    /// Rapport lisible pour comprendre sur device pourquoi une session se
    /// restaure (ou pas) : identité calculée, fichier attendu, provenance des
    /// données, et inventaire des sessions sur disque. Affiché par le menu ⚙️
    /// de la grille, partageable pour débogage.
    func diagnosticsReport() -> String {
        var lines: [String] = []
        lines.append("Peliculle \(AppVersion.display)")
        lines.append("Identité : \(identity)")
        lines.append("Empreinte : \(fileURL.lastPathComponent)")
        lines.append("Source : \(sourceDescription)")
        lines.append("Trouvée au chargement : \(loadedFromDisk ? "oui" : "non")")
        if let recoveredFrom {
            lines.append("Récupérée par contenu depuis : \(recoveredFrom)")
        }
        lines.append("Enregistrements en mémoire : \(records.count)")
        if let failure = writeQueue.sync(execute: { lastWriteFailure }) {
            lines.append("⚠️ Dernière écriture en échec : \(failure)")
        }
        lines.append("")
        lines.append("— Sessions sur disque —")

        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.sessionsDirectory, includingPropertiesForKeys: nil
        )) ?? []
        if files.isEmpty {
            lines.append("(aucune)")
        }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
                lines.append("\(file.lastPathComponent) : illisible")
                continue
            }
            let marker = file.lastPathComponent == fileURL.lastPathComponent ? " ← courante" : ""
            lines.append(
                "\(String(file.lastPathComponent.prefix(10)))… : "
                + "\(payload.records.count) enr., "
                + "\(payload.savedAt.formatted(date: .abbreviated, time: .shortened))\(marker)"
            )
            lines.append("  identité : \(payload.identity ?? "(absente — ancien format)")")
            lines.append("  source : \(payload.folderPath)")
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static func fingerprint(of identity: String) -> String {
        SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private nonisolated static var sessionsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sessions", isDirectory: true)
    }
}
