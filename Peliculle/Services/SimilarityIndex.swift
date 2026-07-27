import Vision

/// `VNFeaturePrintObservation` est **immuable** après création (résultat d'un
/// fetch Vision), sûr à faire circuler entre acteurs — Vision ne déclare pas la
/// conformance, on l'officialise ici (même contrat que `PHAsset`).
extension VNFeaturePrintObservation: @retroactive @unchecked Sendable {}

/// Détection des photos similaires (idée culling assisté) : calcule une
/// **empreinte visuelle** Vision par photo, puis regroupe (temps + distance)
/// via `SimilarityGrouper`. Acteur dédié — les empreintes ne quittent jamais
/// son isolation, seuls des identifiants en sortent.
///
/// Empreintes en **cache mémoire de session** (keyé `backing.cacheKey`,
/// valable le temps du montage courant) : recalculées au prochain lancement,
/// mais chaque calcul est rapide (Vision sur l'aperçu 400 px déjà décodé et
/// caché par `ThumbnailLoader`). Passe **sans réseau** (`allowNetwork: false`)
/// et **sur le seul périmètre demandé** par l'appelant (photos affichées / du
/// tri rapide) : jamais un balayage de toute la photothèque, jamais de
/// téléchargement iCloud.
actor SimilarityIndex {
    static let shared = SimilarityIndex()

    /// Photo à analyser, réduite à des **valeurs Sendable** : l'acteur n'a
    /// jamais besoin de l'état main-actor du `PhotoItem`, juste de quoi charger
    /// l'aperçu (`backing`), dater (`date`) et remonter le résultat (`id`).
    struct Descriptor: Sendable, Identifiable {
        let id: UUID
        let backing: PhotoBacking
        /// Date de prise de vue (repli date fichier) — pour la fenêtre
        /// temporelle. Lue sur le main actor par l'appelant.
        let date: Date
    }

    private var cache: [String: VNFeaturePrintObservation] = [:]

    /// Nombre d'empreintes calculées avant de **republier** un instantané des
    /// groupes stabilisés (`onPartial`), pour un rendu progressif des badges
    /// sans re-grouper à chaque photo.
    private static let partialEvery = 12

    /// Groupes de photos similaires (≥ 2), rendus comme **listes d'identifiants**
    /// dans l'ordre de prise de vue. `onProgress(fait, total)` alimente une
    /// jauge « Analyse… n/N » ; `onPartial(groupes)` publie des **snapshots
    /// intermédiaires** au fil des empreintes, pour que les badges apparaissent
    /// progressivement plutôt que d'un bloc. Les deux sont rapportés sur le main
    /// actor. Annulable (le `.task` appelant redémarre à chaque changement de
    /// périmètre).
    ///
    /// Empreintes calculées **en séquence** : chacune fait déjà son décodage +
    /// inférence dans une tâche détachée (`featurePrint`), donc hors de l'acteur
    /// et du main thread. Une version à `TaskGroup` sur l'acteur (tâches filles
    /// rappelant `self`) bloquait la passe — la réentrance ne valait pas le gain.
    func clusters(
        for descriptors: [Descriptor],
        maxInterval: TimeInterval = similarityInterval,
        maxDistance: Float,
        onProgress: (@Sendable @MainActor (Int, Int) -> Void)? = nil,
        onPartial: (@Sendable @MainActor ([[UUID]]) -> Void)? = nil
    ) async -> [[UUID]] {
        guard descriptors.count > 1 else { return [] }

        // Le groupeur suppose l'ordre croissant : on trie une fois ici.
        let ordered = descriptors.sorted { $0.date < $1.date }
        let total = ordered.count
        var prints = [VNFeaturePrintObservation?](repeating: nil, count: total)

        // Regroupe sur les empreintes **disponibles** : une case encore nil rend
        // la distance incalculable (jamais liée), si bien qu'on peut grouper à
        // tout moment — les groupes se remplissent au fil des empreintes.
        func regroup() -> [[Int]] {
            SimilarityGrouper.groups(
                count: total,
                date: { ordered[$0].date },
                distance: { a, b in
                    guard let pa = prints[a], let pb = prints[b] else { return nil }
                    var value: Float = 0
                    do {
                        try pa.computeDistance(&value, to: pb)
                    } catch {
                        return nil
                    }
                    return value
                },
                maxInterval: maxInterval,
                maxDistance: maxDistance
            )
        }
        func asIDs(_ groups: [[Int]]) -> [[UUID]] { groups.map { $0.map { ordered[$0].id } } }

        // Republie au plus ~8 fois sur la passe (le regroupement est O(n²)) :
        // assez pour un rendu progressif, sans le refaire à chaque poignée.
        let partialStride = Swift.max(Self.partialEvery, total / 8)

        for offset in 0..<total {
            if Task.isCancelled { return [] }
            prints[offset] = await featurePrint(for: ordered[offset].backing)
            let done = offset + 1
            if let onProgress { await onProgress(done, total) }
            if let onPartial, done % partialStride == 0, done < total {
                await onPartial(asIDs(regroup()))
            }
        }
        if Task.isCancelled { return [] }
        return asIDs(regroup())
    }

    /// Empreinte Vision d'une photo (cache mémoire). Chargement de l'aperçu
    /// **et** inférence Vision dans une **tâche détachée** : le décodage et le
    /// perform (CPU synchrone) ne bloquent ni le main thread ni l'acteur ; seul
    /// le résultat (immuable, Sendable) revient et se met en cache.
    private func featurePrint(for backing: PhotoBacking) async -> VNFeaturePrintObservation? {
        let key = backing.cacheKey
        if let cached = cache[key] { return cached }
        let observation = await Task.detached(priority: .utility) { () -> VNFeaturePrintObservation? in
            guard let image = await ThumbnailLoader.load(backing, maxPixel: 400, allowNetwork: false),
                  let cgImage = image.cgImage else {
                return nil
            }
            let request = VNGenerateImageFeaturePrintRequest()
            try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            return request.results?.first as? VNFeaturePrintObservation
        }.value
        if let observation { cache[key] = observation }
        return observation
    }
}
