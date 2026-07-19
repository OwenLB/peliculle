import Foundation
import Photos
import UniformTypeIdentifiers

/// Décision de tri pour une photo (F5). Volontairement binaire en v1.
/// `String` + `Codable` pour la persistance de session (voir `SessionStore`).
enum CullDecision: String, Codable {
    case undecided
    case keep
    case reject
}

/// `PHAsset` est un objet de fetch **immuable**, sûr à faire circuler entre
/// les acteurs (loaders, index) — PhotoKit ne déclare pas la conformance, on
/// officialise ici ce contrat pour le vérificateur de concurrence.
extension PHAsset: @retroactive @unchecked Sendable {}

/// Ce à quoi une photo est adossée (Jalon 10, idée 17) : un **fichier** de la
/// carte SD, ou un **asset** de la photothèque iOS. Toute la différence de
/// source se joue ici — le reste de l'app manipule `PhotoItem` sans savoir.
enum PhotoBacking: Hashable, Sendable {
    case file(URL)
    case asset(PHAsset)

    /// Clé stable pour les caches et index (aperçus, pleine résolution,
    /// analyse, EXIF) : intrinsèque au backing, jamais recalculée. **Valable
    /// pour la session en cours seulement** — l'URL absolue d'une carte SD
    /// change d'un montage à l'autre (la persistance utilise nom + taille,
    /// voir `SessionStore` / `VisionAnalyzer.stableKey`).
    var cacheKey: String {
        switch self {
        case .file(let url): return url.absoluteString
        case .asset(let asset): return asset.localIdentifier
        }
    }
}

/// Une photo de la session de tri, adossée à un fichier (carte SD) ou à un
/// asset de la photothèque. On ne stocke que la référence et des métadonnées
/// légères : jamais les pixels (voir `ThumbnailLoader` / cache).
///
/// Objet d'état UI, isolé au **main actor** : ses propriétés mutables
/// (décision, note, signaux…) pilotent SwiftUI et ne se touchent que sur le
/// main thread — c'est aussi ce qui le rend `Sendable`. Les tâches
/// d'arrière-plan ne lisent que l'immuable (`backing`, `cacheKey`…), exposé
/// `nonisolated`.
@MainActor
@Observable
final class PhotoItem: Identifiable {
    let id = UUID()
    let backing: PhotoBacking
    /// Type uniforme dérivé du système (filtrage F7/F8). Inconnu pour un
    /// asset : `PHAsset` n'expose pas son format sans requête coûteuse.
    let contentType: UTType?
    /// Date du fichier (≈ date de prise de vue pour un fichier d'appareil
    /// photo) ou `creationDate` de l'asset, et taille (fichiers seulement),
    /// lues à l'énumération pour le tri d'affichage — pas de lecture EXIF,
    /// trop coûteuse sur un dossier entier.
    let fileDate: Date?
    let fileSize: Int?

    var decision: CullDecision = .undecided

    /// Note 0–5 (F10), axe indépendant du keep/reject, façon Photo Mechanic.
    var rating: Int = 0

    /// Vrai une fois la photo copiée dans la pellicule iOS (source carte) ou
    /// ajoutée à l'album de destination (source photothèque), cette session.
    /// Permet de signaler ce qui est déjà fait et d'éviter les doublons
    /// involontaires.
    var savedToLibrary: Bool = false

    /// `localIdentifier` de l'asset **créé** par une copie fichier → pellicule
    /// (Batch H5, ① déduplication). Renseigné par `PhotoSaver`, persisté par
    /// `SessionStore`. En session combinée (carte + photothèque), il permet de
    /// masquer le doublon côté photothèque : l'asset créé par Peliculle est le
    /// même fichier que celui de la carte. Nil pour un asset (rien n'a été
    /// créé) ou une copie d'avant ce batch.
    var savedAssetID: String?

    /// Source de provenance de la photo dans la session (Batch H5). Posée à la
    /// **composition** de la session (`CullSession`) : c'est elle qui porte le
    /// support réel (carte SD, disque, iCloud, album, photothèque) là où le
    /// `backing` ne distingue que fichier vs asset. Sert à la provenance du
    /// viewer, au routage de la persistance (le bon `SessionStore`) et aux
    /// libellés/confirmations mixtes. Nil tant que l'item n'est pas rattaché.
    var origin: PhotoSource?

    /// Signaux de pré-tri on-device (Jalon 7), remplis paresseusement par
    /// `VisionAnalyzer` (apparition de la cellule, ou passe de fond quand un
    /// filtre/tri par signal l'exige). Jamais persistés : recalculés à bas
    /// coût depuis le cache d'aperçus.
    var analysis: PhotoAnalysis?

    /// EXIF brut (Jalon 8), rempli paresseusement par `ExifIndexer` — même
    /// cycle de vie que `analysis`. Pour un asset : chemin léger (date de
    /// prise de vue et GPS portés par `PHAsset`, sans I/O).
    var exif: PhotoExif?

    /// Durée d'un clip vidéo (idée 18), remplie paresseusement à
    /// l'apparition de la cellule (`AVURLAsset.load(.duration)`) — jamais
    /// lue au scan. Toujours nil pour une photo.
    var videoDuration: TimeInterval?

    /// Ratio largeur/hauteur d'un clip vidéo (orientation appliquée), rempli
    /// paresseusement par le viewer (`VideoInfo.aspectRatio(of:)`) — sert à
    /// ajuster la vue du lecteur au format exact du clip, sans letterbox.
    /// Toujours nil pour une photo.
    var videoAspect: CGFloat?

    /// Nom du lieu (géocodage inverse, bonus GPS Jalon 8) — résolu à la
    /// demande par `PlaceResolver` quand la photo a des coordonnées.
    var place: String?

    /// Date de prise de vue EXIF, repli sur la date fichier tant que l'EXIF
    /// n'est pas indexé (proche de la réalité pour un fichier d'appareil
    /// photo ; exacte pour un asset : `creationDate`). Sert au tri « Prise de
    /// vue », au regroupement par jour et au Mode Voyage.
    var captureDate: Date? { exif?.captureDate ?? fileDate }

    /// Orientation d'affichage (portrait / paysage), connue dès que l'EXIF est
    /// indexé — immédiatement pour un asset (dimensions portées par `PHAsset`),
    /// après la passe d'index pour un fichier. Nil tant qu'inconnue.
    var orientation: PhotoOrientation? { exif?.orientation }

    // Inits `nonisolated` : les items naissent dans les tâches détachées
    // d'énumération (`FolderAccess`, `PhotoLibrarySource`), hors main actor.
    nonisolated init(url: URL) {
        self.backing = .file(url)
        let values = try? url.resourceValues(
            forKeys: [.contentTypeKey, .contentModificationDateKey, .fileSizeKey]
        )
        self.contentType = values?.contentType
        self.fileDate = values?.contentModificationDate
        self.fileSize = values?.fileSize
    }

    nonisolated init(asset: PHAsset) {
        self.backing = .asset(asset)
        self.contentType = nil
        self.fileDate = asset.creationDate
        self.fileSize = nil
    }

    // MARK: - Accès par backing

    /// URL du fichier, nil pour un asset. Les opérations **fichier** (export,
    /// partage d'original, copie vers la pellicule) n'existent que sur la
    /// source carte ; l'UI les masque pour la photothèque.
    nonisolated var url: URL? {
        if case .file(let url) = backing { return url }
        return nil
    }

    nonisolated var asset: PHAsset? {
        if case .asset(let asset) = backing { return asset }
        return nil
    }

    /// Vrai si la photo est adossée à la photothèque (asset) — l'équivalent
    /// **par item** de `PhotoSource.isLibrary`, indispensable en session
    /// combinée où « garder » veut dire copier (fichier) ou ajouter à l'album
    /// (asset) selon la photo. Se lit sur le backing, jamais sur la session.
    nonisolated var isLibraryBacked: Bool {
        if case .asset = backing { return true }
        return false
    }

    /// Clé stable pour les caches et index (voir `PhotoBacking.cacheKey`).
    nonisolated var cacheKey: String { backing.cacheKey }

    /// Nom affiché (capsule du viewer, fiche EXIF, confirmations). Un asset
    /// n'a pas de nom de fichier accessible à bas coût → date de prise de vue.
    nonisolated var filename: String {
        switch backing {
        case .file(let url):
            return url.lastPathComponent
        case .asset(let asset):
            return asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "Photo"
        }
    }

    /// Vrai si le fichier est un RAW appareil photo (filtre F8, décodage
    /// pleine résolution F4). Indéterminable à bas coût pour un asset —
    /// `PHImageManager` gère le décodage de toute façon.
    nonisolated var isRAW: Bool { contentType?.conforms(to: .rawImage) ?? false }

    /// Vrai pour un clip vidéo de la carte (idée 18) : vignette via
    /// AVFoundation, lecture dans le viewer, pas de zoom ni de signaux
    /// Vision. Les sources photothèque ne chargent que des images.
    nonisolated var isVideo: Bool { contentType?.conforms(to: .movie) ?? false }

    /// Extension en majuscules (CR2, JPG, HEIC…), pour le filtre par format.
    /// Vide pour un asset (voir `FormatFilter.available`).
    nonisolated var formatExtension: String { url?.pathExtension.uppercased() ?? "" }
}

extension PhotoItem: Hashable {
    nonisolated static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool { lhs.id == rhs.id }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
