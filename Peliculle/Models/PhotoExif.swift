import Foundation

/// Champs EXIF **bruts** d'une photo (Jalon 8), lus paresseusement par
/// `ExifIndexer` — jamais au scan du dossier, trop coûteux. Ils alimentent le
/// tri, les filtres, le regroupement par jour et la localisation ; l'affichage
/// **formaté** de la fiche du viewer reste `PhotoMetadata` (`ExifReader`).
struct PhotoExif: Equatable {
    /// Date de prise de vue (`DateTimeOriginal`) — ≠ date fichier, qui peut
    /// bouger à la copie. Absente de certains fichiers → repli `fileDate`
    /// (voir `PhotoItem.captureDate`).
    var captureDate: Date?
    /// Focale **réelle** en mm (pas l'équivalent 24×36 — souvent absent).
    var focalLength: Double?
    var iso: Int?
    var aperture: Double?
    var camera: String?
    var lens: String?
    /// Position GPS si le boîtier l'écrit (rare sur reflex) — degrés signés.
    var latitude: Double?
    var longitude: Double?
    /// Dimensions **d'affichage** en pixels (orientation EXIF déjà appliquée,
    /// voir `ExifFormat.displayDimensions`). Portées gratuitement par un asset
    /// (`PHAsset.pixelWidth/Height`), lues sans décoder les pixels pour un
    /// fichier. Alimentent l'orientation (portrait/paysage), affichée dans la
    /// fiche et filtrable.
    var pixelWidth: Int?
    var pixelHeight: Int?

    var hasCoordinate: Bool { latitude != nil && longitude != nil }

    /// Orientation d'affichage, dès que les dimensions sont connues.
    var orientation: PhotoOrientation? {
        guard let width = pixelWidth, let height = pixelHeight, width > 0, height > 0 else {
            return nil
        }
        return width >= height ? .landscape : .portrait
    }
}
