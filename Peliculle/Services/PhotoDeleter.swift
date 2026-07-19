import Foundation
import Photos

/// Suppression **définitive**, toujours déclenchée derrière une confirmation
/// explicite, adaptée au backing (Jalon 10) :
/// - **fichiers de la carte SD** : la seule opération d'écriture de l'app sur
///   la carte (exception assumée au principe « carte intacte ») ;
/// - **assets photothèque** : `PHAssetChangeRequest.deleteAssets`, que le
///   système fait **lui-même confirmer** une seconde fois (dialogue PhotoKit)
///   — et les photos supprimées restent 30 jours dans « Supprimés récemment ».
enum PhotoDeleter {

    struct Summary {
        var deleted: [PhotoItem] = []
        var failed = 0
        /// Vrai si l'utilisateur a **refusé** le dialogue de confirmation
        /// PhotoKit : un choix, pas un échec — rien n'est supprimé et l'UI
        /// n'a rien à signaler. (Ne concerne que les assets ; la suppression
        /// fichier n'a pas de second dialogue.)
        var cancelled = false
    }

    static func delete(_ items: [PhotoItem]) async -> Summary {
        let files = items.filter { $0.asset == nil }
        let assets = items.filter { $0.asset != nil }

        var summary = await deleteFiles(files)
        let assetSummary = await deleteAssets(assets)
        summary.deleted.append(contentsOf: assetSummary.deleted)
        summary.failed += assetSummary.failed
        summary.cancelled = assetSummary.cancelled
        return summary
    }

    /// Supprime fichier par fichier, hors main thread, pour isoler les échecs
    /// (carte débranchée, fichier verrouillé…).
    private static func deleteFiles(_ items: [PhotoItem]) async -> Summary {
        guard !items.isEmpty else { return Summary() }
        return await Task.detached(priority: .userInitiated) {
            var summary = Summary()
            for item in items {
                guard let url = item.url else { continue }
                do {
                    try FileManager.default.removeItem(at: url)
                    summary.deleted.append(item)
                } catch {
                    summary.failed += 1
                }
            }
            return summary
        }.value
    }

    /// Supprime les assets en **un seul** lot : un seul dialogue de
    /// confirmation système pour toute la sélection. L'utilisateur peut y
    /// annuler → `performChanges` échoue, rien n'est supprimé — remonté en
    /// `cancelled`, jamais en échec.
    private static func deleteAssets(_ items: [PhotoItem]) async -> Summary {
        guard !items.isEmpty else { return Summary() }
        let assets = items.compactMap(\.asset)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
            return Summary(deleted: items, failed: 0)
        } catch {
            let cancelled = (error as? PHPhotosError)?.code == .userCancelled
            return Summary(deleted: [], failed: cancelled ? 0 : items.count, cancelled: cancelled)
        }
    }
}
