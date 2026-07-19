import AVFoundation
import UIKit
import ImageIO
import Photos
import UniformTypeIdentifiers

/// Génère les aperçus (F2/F3), quel que soit le backing (Jalon 10) :
/// - **Fichier** : ImageIO en **downsampling** — jamais de chargement pleine
///   résolution, `kCGImageSourceThumbnailMaxPixelSize` borne la taille. Pour
///   les RAW, ImageIO renvoie le **preview embarqué**, quasi instantané.
/// - **Vidéo** (idée 18) : une image extraite par `AVAssetImageGenerator`,
///   bornée à la même taille cible, même cache.
/// - **Asset photothèque** : `PHImageManager`, qui gère downsampling, cache
///   système et téléchargement iCloud.
enum ThumbnailLoader {

    /// - Parameters:
    ///   - maxPixel: plus grand côté cible en pixels (grille ≈ 400, plein
    ///     écran ≈ 2048). Le décodage se fait hors du thread principal et
    ///     respecte l'annulation (`.task` SwiftUI annule les chargements hors écran).
    ///   - allowNetwork: autorise le téléchargement iCloud d'un asset absent
    ///     en local. `true` pour tout ce que l'utilisateur regarde ; **`false`
    ///     pour les passes de fond** — analyser 10 000 photos ne doit jamais
    ///     déclencher 10 000 téléchargements.
    static func load(_ backing: PhotoBacking, maxPixel: Int, allowNetwork: Bool = true) async -> UIImage? {
        let cacheKey = backing.cacheKey
        if let cached = ImageCache.shared.image(for: cacheKey, maxPixel: maxPixel) {
            return cached
        }

        let image: UIImage?
        switch backing {
        case .file(let url):
            let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            if type?.conforms(to: .movie) == true {
                image = await loadVideoFile(url: url, maxPixel: maxPixel)
            } else {
                image = await loadFile(url: url, maxPixel: maxPixel)
            }
        case .asset(let asset):
            image = await loadAsset(asset, maxPixel: maxPixel, allowNetwork: allowNetwork)
        }

        if let image {
            ImageCache.shared.insert(image, for: cacheKey, maxPixel: maxPixel)
        }
        return image
    }

    /// Confort pour les call sites qui tiennent un `PhotoItem`.
    static func load(item: PhotoItem, maxPixel: Int) async -> UIImage? {
        await load(item.backing, maxPixel: maxPixel)
    }

    // MARK: - Fichier (ImageIO)

    private static func loadFile(url: URL, maxPixel: Int) async -> UIImage? {
        // Décodage **coopératif** : `ThumbnailLoader` est un enum non isolé,
        // donc ce code tourne déjà hors du main thread (pool concurrent), et il
        // hérite de l'annulation du `.task` appelant. On abandonnait cette
        // annulation avec `Task.detached` — un scroll rapide laissait des
        // centaines de décodages tourner jusqu'au bout hors écran, volant CPU
        // et batterie aux cellules visibles. On sort tôt si la cellule a déjà
        // quitté l'écran (deux points de contrôle autour du seul travail lourd).
        if Task.isCancelled { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        if Task.isCancelled { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Vidéo (AVAssetImageGenerator, idée 18)

    /// Une image vers ~0,5 s (la première est souvent noire), redressée
    /// (`appliesPreferredTrackTransform`) et bornée à la taille cible. En
    /// échec (durée plus courte, piste illisible), repli sur l'instant zéro.
    private static func loadVideoFile(url: URL, maxPixel: Int) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)

        for seconds in [0.5, 0.0] {
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let cgImage = try? await generator.image(at: time).image {
                return UIImage(cgImage: cgImage)
            }
        }
        return nil
    }

    // MARK: - Asset photothèque (PHImageManager)

    /// `deliveryMode = .highQualityFormat` garantit **un seul** appel du
    /// handler (le mode opportuniste en fait plusieurs — incompatible avec une
    /// continuation). Sans réseau, une photo iCloud non locale donne nil —
    /// « Optimiser le stockage » garde des dérivés basse résolution sur
    /// l'appareil, souvent suffisants pour un aperçu 400 px.
    private static func loadAsset(_ asset: PHAsset, maxPixel: Int, allowNetwork: Bool) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = allowNetwork

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: maxPixel, height: maxPixel),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}
