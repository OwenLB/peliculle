import UIKit
import CoreImage
import ImageIO
import Photos

/// F4 — décodage **pleine résolution à la demande**, uniquement quand on zoome
/// pour vérifier le piqué. Fichiers : les RAW passent par `CIRAWFilter` (Core
/// Image), les formats standard par un décodage ImageIO complet. Assets
/// photothèque : `PHImageManager` en taille maximale (Jalon 10). Coûteux : on
/// ne l'appelle jamais au défilement, et le résultat est mis en cache — un
/// cache **dédié** : un RAW 45 Mpx décodé pèse ~180 Mo de pixels, dans le
/// cache partagé une seule entrée évinçait tous les aperçus de la grille.
enum FullResLoader {

    /// Deux entrées suffisent : la photo inspectée et la précédente (retour
    /// en arrière d'une page). Au-delà, on redécode — inspection ponctuelle.
    private static let cache = FullResCache()

    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// - Parameter isRAW: type connu du fichier (via `PhotoItem.isRAW`). Route
    ///   le décodage sans tenter-puis-échouer : `CIRAWFilter` sur un JPEG/HEIC
    ///   construit et jette un pipeline Core Image pour rien. Défaut `false`
    ///   (chemin standard) — le repli RAW→standard reste le filet si le type
    ///   dit RAW mais que le décodage complet échoue.
    static func load(_ backing: PhotoBacking, isRAW: Bool = false) async -> UIImage? {
        let cacheKey = backing.cacheKey
        if let cached = await cache.image(for: cacheKey) {
            return cached
        }

        let image: UIImage?
        switch backing {
        case .file(let url):
            image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                if isRAW { return decodeRAW(url) ?? decodeStandard(url) }
                return decodeStandard(url)
            }.value
        case .asset(let asset):
            image = await loadAsset(asset)
        }

        if let image {
            await cache.insert(image, for: cacheKey)
        }
        return image
    }

    static func load(item: PhotoItem) async -> UIImage? {
        await load(item.backing, isRAW: item.isRAW)
    }

    // MARK: - Fichier

    private static func decodeRAW(_ url: URL) -> UIImage? {
        guard let filter = CIRAWFilter(imageURL: url),
              let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func decodeStandard(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(
                source, 0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              ) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Asset photothèque

    /// `PHImageManagerMaximumSize` = la résolution native de l'asset (RAW
    /// compris, le décodage est géré par PhotoKit). Un seul appel du handler
    /// grâce à `.highQualityFormat`.
    private static func loadAsset(_ asset: PHAsset) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

/// Mini-cache LRU de la pleine résolution, borné en **nombre d'entrées**
/// (2) plutôt qu'en octets : c'est la nature de l'usage (inspection de la
/// photo courante) qui borne la mémoire, pas un budget partagé.
private actor FullResCache {
    private var entries: [(key: String, image: UIImage)] = []

    func image(for key: String) -> UIImage? {
        entries.first { $0.key == key }?.image
    }

    func insert(_ image: UIImage, for key: String) {
        entries.removeAll { $0.key == key }
        entries.append((key, image))
        if entries.count > 2 { entries.removeFirst() }
    }
}
