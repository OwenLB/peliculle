import Foundation

/// L'état **complet** des filtres de la grille (revue qualité) : les dix
/// dimensions vivaient en `@State` séparés dans `GridView` et gonflaient
/// l'init de `FilterSheet` d'autant de bindings. Une seule valeur : un seul
/// `@State`, un seul binding, et la remise à zéro redevient `= GridFilters()`.
///
/// Le tri (`PhotoSort`), lui, reste à part : c'est un **réglage persistant**
/// (`@AppStorage`), pas un filtre.
struct GridFilters: Equatable {
    var format: FormatFilter = .all
    var minRating = 0
    var decision: DecisionFilter = .all
    /// Filtre « déjà rangée ? » (Batch H5) — téléchargée dans la pellicule
    /// pour une source externe, dans l'album de destination pour une
    /// photothèque (l'appartenance réelle est sondée par la grille).
    var saved: SavedFilter = .all
    /// Filtres EXIF (Jalon 8, idée 10). Boîtier/objectif : nil = tous.
    var iso: ISOFilter = .all
    var focal: FocalFilter = .all
    var camera: String?
    var lens: String?
    var orientation: OrientationFilter = .all
    /// Bornes Du/Au sur la date de prise de vue — inertes quand le Mode
    /// Voyage borne déjà l'affichage (il fait autorité sur les dates).
    var dateRange = DateRangeFilter()

    var isExifFiltering: Bool {
        iso != .all || focal != .all || camera != nil || lens != nil
            || orientation != .all
    }

    /// Vrai si au moins un filtre écarte potentiellement des photos.
    /// `tripActive` : un voyage actif rend la plage de dates inerte.
    func isActive(tripActive: Bool) -> Bool {
        format != .all || minRating > 0 || decision != .all
            || saved != .all
            || isExifFiltering
            || (!tripActive && dateRange.isActive)
    }

    /// Prédicat des dimensions **intrinsèques** à la photo. Les dimensions
    /// contextuelles restent à la charge de la grille : périmètre voyage
    /// (session) et statut « rangée » (`saved`, sondage d'album), passé ici
    /// en valeur.
    @MainActor
    func matches(_ item: PhotoItem, isSaved: Bool, tripActive: Bool) -> Bool {
        (tripActive || dateRange.matches(item.captureDate))
            && format.matches(item)
            && item.rating >= minRating
            && decision.matches(item)
            && saved.matches(isSaved: isSaved)
            && iso.matches(item)
            && focal.matches(item)
            && orientation.matches(item)
            && (camera == nil || item.exif?.camera == camera)
            && (lens == nil || item.exif?.lens == lens)
    }
}
