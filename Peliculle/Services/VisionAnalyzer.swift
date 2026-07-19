import CoreGraphics
import Photos
import Vision

/// Jalon 7 — signal de pré-tri calculé **on-device** : score esthétique
/// (Vision, iOS 18+). Travaille sur l'aperçu ~400 px déjà décodé pour la grille
/// (`ThumbnailLoader`, cache partagé) — jamais la pleine résolution.
///
/// `actor` mutualisé : résultats en cache par photo (`PhotoItem.cacheKey`,
/// indifférent au backing fichier/asset — Jalon 10), une seule analyse en vol
/// par photo (les demandes concurrentes attendent la même tâche), calcul en
/// priorité basse et hors de tout acteur (`Task.detached`). L'analyse est
/// **paresseuse** (déclenchée à l'apparition d'une cellule ou par un
/// filtre/tri qui en a besoin), jamais un balayage complet au scan.
///
/// Les résultats sont **persistés** (JSON dans Caches, purgeable par iOS) :
/// sur une photothèque de milliers de photos, la passe de session ne doit
/// tourner qu'une fois dans la vie de la photothèque, pas à chaque ouverture.
/// Le fichier est keyé **nom + taille** (comme `SessionStore`) : l'URL
/// absolue d'une carte SD change d'un montage à l'autre — keyé par URL, le
/// cache repartait de zéro à chaque rebranchement et grossissait sans borne.
actor VisionAnalyzer {
    static let shared = VisionAnalyzer()

    /// Cache mémoire de la session, keyé par le backing courant (URL du
    /// montage en cours / identifiant d'asset) : aucun I/O à la lecture.
    private var cache: [String: PhotoAnalysis] = [:]
    private var inFlight: [String: Task<PhotoAnalysis?, Never>] = [:]

    /// Cache persisté, keyé **stable** (nom + taille pour un fichier,
    /// identifiant pour un asset), daté pour la purge.
    private var diskCache: [String: Stored] = [:]
    private var diskLoaded = false
    private var saveTask: Task<Void, Never>?

    private struct Stored: Codable {
        var analysis: PhotoAnalysis
        var savedAt: Date
    }

    /// Analyse (ou ressort du cache) les signaux d'une photo. Renvoie nil si
    /// l'aperçu est illisible — ou, avec `allowNetwork` à false, si la photo
    /// n'est pas disponible en local (jamais mis en cache : une demande
    /// ultérieure avec réseau pourra aboutir).
    ///
    /// - Parameter allowNetwork: `true` pour ce que l'utilisateur regarde
    ///   (cellule, viewer) ; **`false` pour la passe de session** — analyser
    ///   une photothèque ne doit jamais déclencher de téléchargements iCloud
    ///   en masse. Une demande qui rejoint une analyse déjà en vol hérite du
    ///   réglage de celle-ci (cas rare, retenté à l'apparition suivante).
    func analysis(for backing: PhotoBacking, allowNetwork: Bool = true) async -> PhotoAnalysis? {
        loadDiskCacheIfNeeded()
        let key = backing.cacheKey
        if let cached = cache[key] { return cached }
        if let pending = inFlight[key] { return await pending.value }

        // Clé stable = un stat par photo froide (hors acteur : une carte
        // lente ne doit pas bloquer les autres demandes) — jamais sur le
        // chemin chaud du cache mémoire ci-dessus.
        let stableKey = await Task.detached(priority: .utility) {
            Self.stableKey(for: backing)
        }.value
        // Re-vérifications après suspension : une demande concurrente a pu
        // aboutir pendant le stat.
        if let cached = cache[key] { return cached }
        if let pending = inFlight[key] { return await pending.value }
        if let stored = diskCache[stableKey] {
            cache[key] = stored.analysis
            return stored.analysis
        }

        let task = Task.detached(priority: .utility) {
            await Self.compute(backing, allowNetwork: allowNetwork)
        }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        if let result {
            cache[key] = result
            diskCache[stableKey] = Stored(analysis: result, savedAt: .now)
            scheduleSave()
        }
        return result
    }

    // MARK: - Clés

    /// Même convention que `SessionStore` : nom + taille identifient le
    /// fichier mieux que n'importe quel chemin absolu (point de montage
    /// variable). Collision entre homonymes de même taille : improbable sur
    /// une structure DCIM, et l'effet se limite à partager des signaux.
    private static func stableKey(for backing: PhotoBacking) -> String {
        switch backing {
        case .asset(let asset):
            return asset.localIdentifier
        case .file(let url):
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return "\(url.lastPathComponent)#\(size)"
        }
    }

    // MARK: - Cache disque

    /// Recomputable → dossier Caches, qu'iOS peut purger sous pression sans
    /// autre conséquence qu'une réanalyse.
    private static var cacheFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vision-analysis-v2.json")
    }

    /// Ancien cache keyé par URL absolue — instable d'un montage à l'autre,
    /// donc majoritairement inerte : supprimé, pas migré (les clés nom+taille
    /// ne peuvent pas se reconstruire depuis une URL d'un volume absent).
    private static var legacyCacheFileURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("vision-analysis.json")
    }

    /// Au-delà, les entrées les plus anciennes sont purgées à l'écriture :
    /// cache recomputable, perdre une entrée coûte une réanalyse, pas une
    /// donnée. ~20 000 entrées ≈ quelques Mo de JSON.
    private static let diskCacheLimit = 20_000

    private func loadDiskCacheIfNeeded() {
        guard !diskLoaded else { return }
        diskLoaded = true
        try? FileManager.default.removeItem(at: Self.legacyCacheFileURL)
        guard let data = try? Data(contentsOf: Self.cacheFileURL),
              let stored = try? JSONDecoder().decode([String: Stored].self, from: data) else {
            return
        }
        // Les résultats de la session en cours priment sur le disque.
        diskCache.merge(stored) { current, _ in current }
    }

    /// Écriture débouncée : la passe de session insère des résultats en
    /// rafale, un seul fichier réécrit ~2 s après l'accalmie (purgé au
    /// besoin, voir `diskCacheLimit`).
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            if diskCache.count > Self.diskCacheLimit {
                let excess = diskCache.count - Self.diskCacheLimit
                let oldest = diskCache
                    .sorted { $0.value.savedAt < $1.value.savedAt }
                    .prefix(excess)
                for (key, _) in oldest { diskCache[key] = nil }
            }
            let snapshot = diskCache
            await Task.detached(priority: .utility) {
                guard let data = try? JSONEncoder().encode(snapshot) else { return }
                try? data.write(to: Self.cacheFileURL, options: .atomic)
            }.value
        }
    }

    // MARK: - Calculs (hors acteur, priorité basse)

    private static func compute(_ backing: PhotoBacking, allowNetwork: Bool) async -> PhotoAnalysis? {
        guard let thumbnail = await ThumbnailLoader.load(backing, maxPixel: 400, allowNetwork: allowNetwork),
              let cgImage = thumbnail.cgImage else {
            return nil
        }
        var analysis = PhotoAnalysis()
        analysis.aestheticScore = await aestheticScore(of: cgImage)
        return analysis
    }

    /// Score esthétique (idée 6) : Vision iOS 18+, aucun seuil maison.
    /// `overallScore` est rendu dans −1…1 → ramené à 0…1 pour l'affichage et
    /// le tri (`PhotoSort.aesthetic`).
    private static func aestheticScore(of image: CGImage) async -> Double? {
        let request = CalculateImageAestheticsScoresRequest()
        guard let observation = try? await request.perform(on: image) else {
            return nil
        }
        return (Double(observation.overallScore) + 1) / 2
    }
}
