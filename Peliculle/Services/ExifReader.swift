import ImageIO
import Foundation
import Photos

/// Métadonnées de prise de vue affichées en plein écran (F9).
struct PhotoMetadata {
    var camera: String?
    var lens: String?
    var dateText: String?
    var aperture: String?
    var shutter: String?
    var iso: String?
    var focalLength: String?
    /// Infos fichier (toujours disponibles, même sans EXIF).
    var dimensions: String?
    var fileSize: String?
    /// Orientation d'affichage (portrait / paysage), dès que les dimensions
    /// sont connues — montrée à côté de la résolution.
    var orientation: PhotoOrientation?

    /// Vrai si aucune donnée de prise de vue n'a été lue (les infos fichier
    /// ne comptent pas).
    var isEmpty: Bool {
        camera == nil && lens == nil && dateText == nil && aperture == nil
            && shutter == nil && iso == nil && focalLength == nil
    }
}

/// F9 — lit les champs EXIF/TIFF utiles, hors thread principal.
/// - **Fichier** : propriétés ImageIO, sans jamais décoder les pixels.
/// - **Asset photothèque** (Jalon 10) : les données de l'image sont demandées
///   à `PHImageManager` (iCloud autorisé) puis les propriétés lues dessus.
///   Plus coûteux qu'un fichier local (téléchargement possible de
///   l'original), mais c'est une lecture **à la demande** pour une seule
///   photo (fiche ouverte), jamais une indexation.
///
/// La fiche est **progressive** : `preliminary(from:)` fournit immédiatement
/// (zéro I/O) ce que l'index connaît déjà, la lecture complète enrichit
/// ensuite. Les lectures sont en `.userInitiated` — c'est l'utilisateur qui
/// attend, la fiche ne fait pas la queue derrière les passes d'indexation
/// (`.utility`) — mises en **cache** et dédupliquées : paginer puis revenir
/// ne relit plus rien.
enum ExifReader {

    static func read(_ backing: PhotoBacking) async -> PhotoMetadata {
        await Cache.shared.metadata(for: backing, key: backing.cacheKey)
    }

    /// Fiche partielle **immédiate** depuis l'EXIF indexé (`PhotoExif`) et
    /// les métadonnées de scan — aucun I/O. Vitesse d'obturation et
    /// dimensions manquent (elles arrivent avec la lecture complète) ; nil
    /// si la photo n'est pas encore indexée (la fiche garde son spinner).
    // `@MainActor` : lit l'EXIF indexé de l'item (état isolé main actor) —
    // appelé par la fiche à l'ouverture, sur le main thread.
    @MainActor
    static func preliminary(from item: PhotoItem) -> PhotoMetadata? {
        guard let exif = item.exif else { return nil }
        var meta = PhotoMetadata()
        meta.camera = exif.camera
        meta.lens = exif.lens
        if let date = exif.captureDate { meta.dateText = text(for: date) }
        if let f = exif.aperture { meta.aperture = String(format: "f/%.1f", f) }
        if let iso = exif.iso { meta.iso = "ISO \(iso)" }
        if let focal = exif.focalLength { meta.focalLength = String(format: "%.0f mm", focal) }
        // L'index porte désormais les dimensions : la fiche montre résolution
        // et orientation **immédiatement**, sans attendre la lecture complète.
        if let width = exif.pixelWidth, let height = exif.pixelHeight {
            meta.dimensions = dimensionsText(width: width, height: height)
        }
        meta.orientation = exif.orientation
        if let bytes = item.fileSize {
            meta.fileSize = ByteCountFormatter.string(
                fromByteCount: Int64(bytes),
                countStyle: .file
            )
        }
        return meta
    }

    // MARK: - Cache (fiches lues)

    /// Une fiche par photo et par session, dédupliquée en vol — les
    /// `PhotoMetadata` sont de petites structs, pas de borne nécessaire.
    private actor Cache {
        static let shared = Cache()

        private var stored: [String: PhotoMetadata] = [:]
        private var inFlight: [String: Task<PhotoMetadata, Never>] = [:]

        func metadata(for backing: PhotoBacking, key: String) async -> PhotoMetadata {
            if let cached = stored[key] { return cached }
            if let pending = inFlight[key] { return await pending.value }

            let task = Task.detached(priority: .userInitiated) {
                await ExifReader.readFresh(backing)
            }
            inFlight[key] = task
            let result = await task.value
            inFlight[key] = nil
            stored[key] = result
            return result
        }
    }

    /// Lecture réelle — exécutée hors acteur par le cache, en `.userInitiated`.
    private static func readFresh(_ backing: PhotoBacking) async -> PhotoMetadata {
        switch backing {
        case .file(let url):
            return read(url: url)
        case .asset(let asset):
            return await read(asset: asset)
        }
    }

    private static func read(url: URL) -> PhotoMetadata {
        var meta = PhotoMetadata()

        if let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            meta.fileSize = ByteCountFormatter.string(
                fromByteCount: Int64(bytes),
                countStyle: .file
            )
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return meta
        }
        apply(source: source, to: &meta)
        return meta
    }

    // MARK: - Asset photothèque

    private static func read(asset: PHAsset) async -> PhotoMetadata {
        var meta = PhotoMetadata()
        // Dimensions et date portées par l'asset : disponibles même si les
        // données ne sont pas récupérables (iCloud hors ligne).
        meta.dimensions = dimensionsText(width: asset.pixelWidth, height: asset.pixelHeight)
        if asset.pixelWidth > 0, asset.pixelHeight > 0 {
            meta.orientation = asset.pixelWidth >= asset.pixelHeight ? .landscape : .portrait
        }
        if let date = asset.creationDate {
            meta.dateText = text(for: date)
        }

        guard let data = await imageData(of: asset) else { return meta }
        meta.fileSize = ByteCountFormatter.string(
            fromByteCount: Int64(data.count),
            countStyle: .file
        )
        if let source = CGImageSourceCreateWithData(data as CFData, nil) {
            apply(source: source, to: &meta)
        }
        return meta
    }

    private static func imageData(of asset: PHAsset) async -> Data? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(
                for: asset, options: options
            ) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }

    // MARK: - Propriétés ImageIO (communes aux deux chemins)

    private static func apply(source: CGImageSource, to meta: inout PhotoMetadata) {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return
        }

        if let dims = ExifFormat.displayDimensions(from: props) {
            if meta.dimensions == nil {
                meta.dimensions = dimensionsText(width: dims.width, height: dims.height)
            }
            if meta.orientation == nil {
                meta.orientation = dims.width >= dims.height ? .landscape : .portrait
            }
        }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        meta.camera = ExifFormat.cameraName(make: tiff?[kCGImagePropertyTIFFMake] as? String,
                                            model: tiff?[kCGImagePropertyTIFFModel] as? String)
        meta.lens = exif?[kCGImagePropertyExifLensModel] as? String

        if let raw = exif?[kCGImagePropertyExifDateTimeOriginal] as? String {
            meta.dateText = formatDate(raw)
        }
        if let f = exif?[kCGImagePropertyExifFNumber] as? Double {
            meta.aperture = String(format: "f/%.1f", f)
        }
        if let exposure = exif?[kCGImagePropertyExifExposureTime] as? Double {
            meta.shutter = formatShutter(exposure)
        }
        if let iso = (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Any])?.first as? Int {
            meta.iso = "ISO \(iso)"
        }
        if let focal = exif?[kCGImagePropertyExifFocalLength] as? Double {
            meta.focalLength = String(format: "%.0f mm", focal)
        }
    }

    private static func dimensionsText(width: Int, height: Int) -> String? {
        guard width > 0, height > 0 else { return nil }
        let megapixels = Double(width * height) / 1_000_000
        return String(format: "%d × %d — %.1f Mpx", width, height, megapixels)
    }

    private static func formatShutter(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 1 { return String(format: "%.0f s", seconds) }
        return "1/\(Int((1 / seconds).rounded())) s"
    }

    // MARK: - Dates

    /// Formatter d'affichage partagé (thread-safe en lecture) — recréé à
    /// chaque fiche, il pesait pour rien. Le parser EXIF vit dans
    /// `ExifFormat` (commun avec `ExifIndexer`).
    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func text(for date: Date) -> String {
        displayDateFormatter.string(from: date)
    }

    private static func formatDate(_ raw: String) -> String {
        guard let date = ExifFormat.dateParser.date(from: raw) else { return raw }
        return text(for: date)
    }
}
