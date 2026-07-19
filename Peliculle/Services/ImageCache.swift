import UIKit

/// Cache mémoire des aperçus (PRD §7). Borné par **coût en octets** (et non
/// en nombre d'items) pour éviter les pics mémoire sur les grosses images
/// RAW ; `NSCache` évince tout seul sous pression mémoire. Keyé par
/// `PhotoItem.cacheKey` (URL de fichier ou identifiant d'asset) : le cache
/// ignore la source (Jalon 10).
///
/// Simple classe, plus un `actor` (revue qualité) : `NSCache` est déjà
/// thread-safe, l'isolation d'acteur n'ajoutait qu'un saut de contexte par
/// vignette sans rien protéger de plus. `@unchecked Sendable` : la sûreté
/// est déléguée à `NSCache` (verrouillage interne), pas au compilateur.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()

    init() {
        // Borne dimensionnée sur la RAM physique plutôt que fixe : ~1/8 de la
        // mémoire, **plafonné** à l'ancienne valeur (300 Mo). L'effet utile est
        // à la baisse — sur un device peu doté (ou un futur modèle d'entrée de
        // gamme), 300 Mo fixes poussaient vers le jetsam ; ici le budget suit la
        // machine sans jamais dépasser ce qui suffisait déjà sur un device
        // confortable. `NSCache` évince en plus tout seul sous pression mémoire.
        let physical = ProcessInfo.processInfo.physicalMemory
        cache.totalCostLimit = min(Int(physical / 8), 300 * 1024 * 1024)
    }

    private func key(_ cacheKey: String, _ maxPixel: Int) -> NSString {
        "\(cacheKey)|\(maxPixel)" as NSString
    }

    func image(for cacheKey: String, maxPixel: Int) -> UIImage? {
        cache.object(forKey: key(cacheKey, maxPixel))
    }

    func insert(_ image: UIImage, for cacheKey: String, maxPixel: Int) {
        let pixels = image.size.width * image.size.height * image.scale * image.scale
        let cost = Int(pixels) * 4 // 4 octets / pixel (RGBA)
        cache.setObject(image, forKey: key(cacheKey, maxPixel), cost: cost)
    }
}
