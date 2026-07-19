import Foundation

/// Batch H5 — filtre « déjà rangée ? », dont le **sens dépend de la source** :
/// - source **externe** (carte SD, disque) : la photo a-t-elle été
///   **téléchargée** (copiée) dans la pellicule (`PhotoItem.savedToLibrary`,
///   gardé honnête par la réconciliation) ;
/// - source **photothèque** (album, toutes les photos) : la photo est-elle
///   **dans l'album de destination** — elle est déjà sur l'iPhone, la notion
///   de « télécharger » n'a pas d'objet. L'appartenance est vérifiée en réel
///   contre PhotoKit par la grille (elle seule connaît les membres de
///   l'album) ; l'enum ne fait que trancher l'affichage et les libellés.
enum SavedFilter: String, CaseIterable, Identifiable {
    case all
    case saved
    case notSaved

    var id: String { rawValue }

    /// Libellés adaptés à la source : téléchargement (fichier) vs appartenance
    /// à l'album (photothèque).
    func label(isLibrary: Bool) -> String {
        switch self {
        case .all:
            return String(localized: "Toutes")
        case .saved:
            return isLibrary
                ? String(localized: "Dans l'album")
                : String(localized: "Téléchargées")
        case .notSaved:
            return isLibrary
                ? String(localized: "Hors de l'album")
                : String(localized: "Non téléchargées")
        }
    }

    /// La grille calcule le drapeau « rangée » par photo (téléchargée pour un
    /// fichier, membre de l'album de destination pour un asset) ; ici on tranche.
    func matches(isSaved: Bool) -> Bool {
        switch self {
        case .all: return true
        case .saved: return isSaved
        case .notSaved: return !isSaved
        }
    }
}
