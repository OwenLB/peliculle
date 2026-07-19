import Foundation

/// Critère d'ordre d'affichage de la grille (persisté via `@AppStorage`, le
/// sens croissant/décroissant est un réglage séparé). S'appuie sur les
/// métadonnées de fichier lues à l'énumération (`fileDate`, `fileSize`),
/// jamais sur l'EXIF. Les égalités retombent sur date puis nom pour rester
/// déterministes (le tri de Swift n'est pas stable).
enum PhotoSort: String, CaseIterable, Identifiable {
    case captureDate
    case date
    case name
    case rating
    case size
    case aesthetic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .captureDate: return String(localized: "Prise de vue")
        case .date: return String(localized: "Date fichier")
        case .name: return String(localized: "Nom")
        case .rating: return String(localized: "Note")
        case .size: return String(localized: "Taille")
        case .aesthetic: return String(localized: "Esthétique")
        }
    }

    var icon: String {
        switch self {
        case .captureDate: return "camera"
        case .date: return "calendar"
        case .name: return "textformat"
        case .rating: return "star"
        case .size: return "scalemass"
        case .aesthetic: return "sparkles"
        }
    }

    /// Sens proposé au premier choix du critère : chronologique et
    /// alphabétique en croissant, meilleures notes, fichiers lourds et
    /// meilleurs scores d'abord.
    var defaultAscending: Bool {
        switch self {
        case .captureDate, .date, .name: return true
        case .rating, .size, .aesthetic: return false
        }
    }

    // Le comparateur lit l'état mutable des items (note, EXIF, analyse —
    // isolé main actor) : le tri d'affichage se fait sur le main thread.
    @MainActor
    func areInOrder(_ a: PhotoItem, _ b: PhotoItem, ascending: Bool) -> Bool {
        switch self {
        case .captureDate:
            // Repli date fichier tant que l'EXIF n'est pas indexé (voir
            // `PhotoItem.captureDate`) : l'ordre s'affine au fil de la passe
            // de fond déclenchée par `GridView` quand ce tri est actif.
            let dateA = a.captureDate ?? .distantPast
            let dateB = b.captureDate ?? .distantPast
            if dateA != dateB {
                return ascending ? dateA < dateB : dateA > dateB
            }
            return isNameAscending(a, b)
        case .date:
            if fileDate(a) != fileDate(b) {
                return ascending ? fileDate(a) < fileDate(b) : fileDate(a) > fileDate(b)
            }
            return isNameAscending(a, b)
        case .name:
            let comparison = a.filename.localizedStandardCompare(b.filename)
            return comparison == (ascending ? .orderedAscending : .orderedDescending)
        case .rating:
            if a.rating != b.rating {
                return ascending ? a.rating < b.rating : a.rating > b.rating
            }
            return PhotoSort.date.areInOrder(a, b, ascending: true)
        case .size:
            let sizeA = a.fileSize ?? 0
            let sizeB = b.fileSize ?? 0
            if sizeA != sizeB {
                return ascending ? sizeA < sizeB : sizeA > sizeB
            }
            return PhotoSort.date.areInOrder(a, b, ascending: true)
        case .aesthetic:
            // Photos non (encore) analysées derrière les meilleurs scores en
            // décroissant : la grille se réordonne au fil de l'analyse de
            // fond (déclenchée par `GridView` quand ce tri est actif).
            let scoreA = a.analysis?.aestheticScore ?? -1
            let scoreB = b.analysis?.aestheticScore ?? -1
            if scoreA != scoreB {
                return ascending ? scoreA < scoreB : scoreA > scoreB
            }
            return PhotoSort.date.areInOrder(a, b, ascending: true)
        }
    }

    private func fileDate(_ item: PhotoItem) -> Date { item.fileDate ?? .distantPast }

    private func isNameAscending(_ a: PhotoItem, _ b: PhotoItem) -> Bool {
        a.filename.localizedStandardCompare(b.filename) == .orderedAscending
    }
}
