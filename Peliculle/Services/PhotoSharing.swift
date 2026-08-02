import AVFoundation
import Photos
import UIKit

/// Prépare les items à partager pour une photo **photothèque** — une source
/// externe a déjà son URL de fichier (partage synchrone, `ShareLink(item:)`
/// direct dans les vues) ; un asset n'en a pas, seul ce cas passe par ici.
/// Partagé entre le viewer et le menu contextuel de la grille (même geste,
/// deux points d'entrée).
enum PhotoSharing {
    /// Présente la feuille système directement sur le contrôleur au sommet de
    /// la fenêtre, **sans** passer par un `.sheet` SwiftUI. Un `.sheet` autour
    /// d'un simple hôte `UIViewController` qui se présente lui-même empilait
    /// deux modales (la carte SwiftUI, vide, puis `UIActivityViewController`
    /// par-dessus) : d'où la feuille vide et « en double » observée sur la
    /// photothèque. Présenter directement, une seule fois, élimine les deux.
    @MainActor
    static func present(_ items: [Any]) {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController
        else { return }
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        top.present(UIActivityViewController(activityItems: items, applicationActivities: nil), animated: true)
    }

    /// Photo en pleine résolution (réutilise `FullResLoader`, même cache que
    /// le zoom) ou URL locale d'un clip (`requestAVAsset`, sans ré-export
    /// coûteux). Vide si l'item n'est pas adossé à un asset ou illisible.
    static func libraryItems(for item: PhotoItem) async -> [Any] {
        guard let asset = item.asset else { return [] }
        if item.isVideo {
            return await videoItems(for: asset)
        }
        guard let image = await FullResLoader.load(item: item) else { return [] }
        return [image]
    }

    private static func videoItems(for asset: PHAsset) async -> [Any] {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                guard let urlAsset = avAsset as? AVURLAsset else {
                    continuation.resume(returning: [])
                    return
                }
                continuation.resume(returning: [urlAsset.url])
            }
        }
    }
}
