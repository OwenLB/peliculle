import Foundation
import ImageIO

/// Conventions EXIF partagées entre l'index (`ExifIndexer`) et la fiche
/// (`ExifReader`) — un seul exemplaire de chaque.
enum ExifFormat {

    /// Dimensions **d'affichage** (largeur, hauteur) d'après les propriétés
    /// ImageIO : lit les dimensions pixel et applique l'orientation EXIF
    /// (valeurs 5–8 = rotation de 90°, on permute) pour que portrait/paysage
    /// **et** la taille reflètent l'image telle qu'affichée, pas le capteur
    /// brut. nil si les dimensions manquent.
    static func displayDimensions(from props: [CFString: Any]) -> (width: Int, height: Int)? {
        guard let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return nil
        }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = (5...8).contains(orientation)
        return rotated ? (width: height, height: width) : (width: width, height: height)
    }

    /// Format de date EXIF standard. `DateFormatter` est thread-safe en
    /// lecture, l'instance partagée est volontaire.
    static let dateParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// « Canon EOS R5 » plutôt que « Canon Canon EOS R5 » quand le modèle
    /// contient déjà la marque.
    static func cameraName(make: String?, model: String?) -> String? {
        guard let model else { return make }
        guard let make, !model.localizedCaseInsensitiveContains(make) else { return model }
        return "\(make) \(model)"
    }
}
