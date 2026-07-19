import AVFoundation
import Foundation

/// Idée 18 (batch G3) — métadonnées légères d'un clip vidéo, chargées
/// paresseusement (à l'apparition de la cellule), jamais au scan.
enum VideoInfo {

    /// Durée du clip, `nil` si le conteneur est illisible.
    static func duration(of url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    /// Ratio largeur/hauteur de la piste vidéo, **orientation appliquée**
    /// (`preferredTransform` : un clip filmé en portrait a une piste paysage
    /// tournée de 90°, il doit lire portrait). `nil` si le conteneur est
    /// illisible ou sans piste vidéo.
    static func aspectRatio(of url: URL) async -> CGFloat? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (naturalSize, transform) = try? await track.load(.naturalSize, .preferredTransform)
        else { return nil }
        let size = naturalSize.applying(transform)
        let width = abs(size.width)
        let height = abs(size.height)
        guard width > 0, height > 0 else { return nil }
        return width / height
    }

    /// « 0:12 », « 1:05:42 » — le format positionnel de Photos.app.
    static func formattedDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        formatter.unitsStyle = .positional
        return formatter.string(from: seconds) ?? ""
    }
}
