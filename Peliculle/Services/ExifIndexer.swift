import Foundation
import ImageIO
import Photos

/// Jalon 8 — lit les champs EXIF **bruts** (`PhotoExif`) sans jamais décoder
/// les pixels. Même architecture que `VisionAnalyzer` : actor mutualisé,
/// cache par photo, déduplication des lectures en vol, travail hors acteur en
/// priorité basse. Lecture **paresseuse** (cellule affichée, fiche du viewer)
/// ou passe de fond de session quand un tri/filtre/regroupement l'exige
/// (voir `GridView`).
///
/// Deux chemins selon le backing (Jalon 10) :
/// - **Fichier** : propriétés ImageIO (EXIF/TIFF/GPS complets).
/// - **Asset** : chemin **léger**, sans aucune I/O — `PHAsset` porte déjà la
///   date de prise de vue et le GPS, les seuls champs dont dépendent le tri,
///   le Mode Voyage, le regroupement par jour et la carte. Boîtier/objectif/
///   ISO exigeraient de télécharger les données de l'image : réservé à la
///   fiche EXIF à la demande (`ExifReader`), jamais à l'indexation.
actor ExifIndexer {
    static let shared = ExifIndexer()

    private var cache: [String: PhotoExif] = [:]
    private var inFlight: [String: Task<PhotoExif?, Never>] = [:]

    /// Lit (ou ressort du cache) l'EXIF brut d'une photo. Ne renvoie nil que
    /// si le fichier est illisible ; un fichier sans EXIF donne un
    /// `PhotoExif` aux champs nil.
    func exif(for backing: PhotoBacking) async -> PhotoExif? {
        switch backing {
        case .asset(let asset):
            // Aucune I/O : réponse immédiate, sans sous-tâche ni vol dédupliqué.
            let key = backing.cacheKey
            if let cached = cache[key] { return cached }
            let exif = Self.read(asset: asset)
            cache[key] = exif
            return exif

        case .file(let url):
            let key = backing.cacheKey
            if let cached = cache[key] { return cached }
            if let pending = inFlight[key] { return await pending.value }

            let task = Task.detached(priority: .utility) {
                Self.read(url: url)
            }
            inFlight[key] = task
            let result = await task.value
            inFlight[key] = nil
            if let result { cache[key] = result }
            return result
        }
    }

    // MARK: - Asset (métadonnées portées par PHAsset, aucune I/O)

    /// Chemin léger exposé à `PhotoLibrarySource` : les items d'une source
    /// photothèque naissent avec leur EXIF déjà rempli, ce qui évite toute
    /// passe d'indexation (et ses milliers d'invalidations de vue) sur une
    /// grande photothèque.
    static func lightweightExif(for asset: PHAsset) -> PhotoExif {
        read(asset: asset)
    }

    private static func read(asset: PHAsset) -> PhotoExif {
        var exif = PhotoExif()
        exif.captureDate = asset.creationDate
        // Dimensions portées par l'asset (déjà orientées à l'affichage) : zéro
        // I/O → l'orientation est connue dès la naissance de l'item.
        if asset.pixelWidth > 0, asset.pixelHeight > 0 {
            exif.pixelWidth = asset.pixelWidth
            exif.pixelHeight = asset.pixelHeight
        }
        if let coordinate = asset.location?.coordinate {
            exif.latitude = coordinate.latitude
            exif.longitude = coordinate.longitude
        }
        return exif
    }

    // MARK: - Lecture fichier (hors acteur)

    private static func read(url: URL) -> PhotoExif? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exifDict = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        var exif = PhotoExif()
        if let raw = exifDict?[kCGImagePropertyExifDateTimeOriginal] as? String {
            exif.captureDate = ExifFormat.dateParser.date(from: raw)
        }
        exif.focalLength = exifDict?[kCGImagePropertyExifFocalLength] as? Double
        exif.iso = (exifDict?[kCGImagePropertyExifISOSpeedRatings] as? [Any])?.first as? Int
        exif.aperture = exifDict?[kCGImagePropertyExifFNumber] as? Double
        exif.camera = ExifFormat.cameraName(
            make: tiff?[kCGImagePropertyTIFFMake] as? String,
            model: tiff?[kCGImagePropertyTIFFModel] as? String
        )
        exif.lens = exifDict?[kCGImagePropertyExifLensModel] as? String

        // Dimensions d'affichage (orientation EXIF appliquée) : sans décoder
        // les pixels — alimentent l'orientation portrait/paysage.
        if let dims = ExifFormat.displayDimensions(from: props) {
            exif.pixelWidth = dims.width
            exif.pixelHeight = dims.height
        }

        // Coordonnées signées : les refs S/W portent le signe dans l'EXIF.
        if let gps,
           let latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
           let longitude = gps[kCGImagePropertyGPSLongitude] as? Double {
            let southern = gps[kCGImagePropertyGPSLatitudeRef] as? String == "S"
            let western = gps[kCGImagePropertyGPSLongitudeRef] as? String == "W"
            exif.latitude = southern ? -latitude : latitude
            exif.longitude = western ? -longitude : longitude
        }
        return exif
    }
}
