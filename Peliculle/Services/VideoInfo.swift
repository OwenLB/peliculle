import AVFoundation
import Foundation
import Photos

/// Idée 18 (batch G3) — tout ce dont l'app a besoin d'un clip : ses
/// métadonnées légères (durée, format) et son lecteur. Chargé
/// **paresseusement** — à l'apparition de la cellule pour la durée, à
/// l'ouverture de la page pour le lecteur — jamais au scan.
///
/// Chaque entrée prend un `PhotoBacking`, pas une URL : un clip vient de la
/// carte (fichier, lu par AVFoundation) **ou** de la photothèque (asset, servi
/// par PhotoKit), et aucun appelant ne devrait avoir à connaître la
/// différence. Côté asset, durée et format sont portés par `PHAsset`
/// lui-même : les obtenir ne coûte **aucune** ouverture de conteneur, là où un
/// fichier doit être lu.
enum VideoInfo {

    /// Durée du clip, `nil` si elle est illisible ou nulle.
    static func duration(of backing: PhotoBacking) async -> TimeInterval? {
        switch backing {
        case .file(let url):
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration) else { return nil }
            return positive(duration.seconds)
        case .asset(let asset):
            // Portée par PhotoKit : rien à ouvrir, rien à décoder.
            return positive(asset.duration)
        }
    }

    /// Ratio largeur/hauteur du clip, **orientation appliquée** (un clip filmé
    /// en portrait a une piste paysage tournée de 90°, il doit lire portrait).
    /// `nil` si le clip est illisible ou sans piste vidéo.
    static func aspectRatio(of backing: PhotoBacking) async -> CGFloat? {
        switch backing {
        case .file(let url):
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (naturalSize, transform) = try? await track.load(.naturalSize, .preferredTransform)
            else { return nil }
            let size = naturalSize.applying(transform)
            return ratio(width: abs(size.width), height: abs(size.height))
        case .asset(let asset):
            // `pixelWidth`/`pixelHeight` d'un `PHAsset` sont déjà les
            // dimensions **d'affichage**, rotation comprise.
            return ratio(width: CGFloat(asset.pixelWidth), height: CGFloat(asset.pixelHeight))
        }
    }

    /// Lecteur prêt à jouer. `@MainActor` de bout en bout : `AVPlayer` n'est
    /// pas `Sendable`, on le construit donc là où il sera consommé plutôt que
    /// de le faire traverser un domaine d'isolation.
    @MainActor
    static func player(for backing: PhotoBacking) async -> AVPlayer? {
        switch backing {
        case .file(let url):
            return AVPlayer(url: url)
        case .asset(let asset):
            let options = PHVideoRequestOptions()
            options.deliveryMode = .automatic
            // Un clip encore dans iCloud doit pouvoir se télécharger : c'est
            // l'utilisateur qui vient de l'ouvrir, pas une passe de fond (les
            // passes, elles, refusent le réseau — voir `ThumbnailLoader`).
            options.isNetworkAccessAllowed = true
            let box: PlayerItemBox = await withCheckedContinuation { continuation in
                PHImageManager.default().requestPlayerItem(
                    forVideo: asset,
                    options: options
                ) { item, _ in
                    continuation.resume(returning: PlayerItemBox(item: item))
                }
            }
            guard let item = box.item else { return nil }
            return AVPlayer(playerItem: item)
        }
    }

    /// « 0:12 », « 1:05:42 » — le format positionnel de Photos.app.
    static func formattedDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        formatter.unitsStyle = .positional
        return formatter.string(from: seconds) ?? ""
    }

    // MARK: - Outillage

    private static func positive(_ seconds: TimeInterval) -> TimeInterval? {
        seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private static func ratio(width: CGFloat, height: CGFloat) -> CGFloat? {
        guard width > 0, height > 0 else { return nil }
        return width / height
    }

    /// `AVPlayerItem` n'est pas `Sendable`, mais PhotoKit nous le rend sur sa
    /// propre file : on le convoie explicitement jusqu'au main actor, où il
    /// est aussitôt confié à l'`AVPlayer` et plus jamais partagé. Contrat tenu
    /// à la main, comme pour `PHAsset` (voir `PhotoItem`).
    private struct PlayerItemBox: @unchecked Sendable {
        let item: AVPlayerItem?
    }
}
