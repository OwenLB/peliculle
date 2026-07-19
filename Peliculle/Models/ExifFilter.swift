import Foundation

/// Filtres EXIF (Jalon 8, idée 10), combinables avec format / état / note /
/// signaux. Comme pour l'analyse : une photo **non indexée** ne matche que
/// « Tous » — activer un filtre déclenche l'indexation de fond de la session
/// (voir `GridView`), la grille se remplit au fil des lectures.
enum ISOFilter: String, CaseIterable, Identifiable {
    case all
    case low
    case mid
    case high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return String(localized: "Tous")
        case .low: return "≤ 400"
        case .mid: return "401 – 1600"
        case .high: return "> 1600"
        }
    }

    var icon: String {
        switch self {
        case .all: return "photo.on.rectangle.angled"
        case .low: return "sun.max"
        case .mid: return "cloud.sun"
        case .high: return "moon"
        }
    }

    @MainActor
    func matches(_ item: PhotoItem) -> Bool {
        guard self != .all else { return true }
        guard let iso = item.exif?.iso else { return false }
        switch self {
        case .all: return true
        case .low: return iso <= 400
        case .mid: return iso > 400 && iso <= 1600
        case .high: return iso > 1600
        }
    }
}

/// Plages sur la focale **réelle** (pas l'équivalent 24×36, rarement écrit) :
/// sur un capteur APS-C les bornes « ressenties » diffèrent — à ajuster à
/// l'usage si besoin.
enum FocalFilter: String, CaseIterable, Identifiable {
    case all
    case wide
    case standard
    case tele

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return String(localized: "Toutes")
        case .wide: return String(localized: "Grand-angle < 35 mm")
        case .standard: return String(localized: "Standard 35 – 85 mm")
        case .tele: return String(localized: "Télé > 85 mm")
        }
    }

    var icon: String {
        switch self {
        case .all: return "photo.on.rectangle.angled"
        case .wide: return "field.of.view.wide"
        case .standard: return "camera"
        case .tele: return "plus.magnifyingglass"
        }
    }

    @MainActor
    func matches(_ item: PhotoItem) -> Bool {
        guard self != .all else { return true }
        guard let focal = item.exif?.focalLength else { return false }
        switch self {
        case .all: return true
        case .wide: return focal < 35
        case .standard: return focal >= 35 && focal <= 85
        case .tele: return focal > 85
        }
    }
}
