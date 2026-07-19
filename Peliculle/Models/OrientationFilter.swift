import Foundation

/// Orientation d'affichage d'une photo, dérivée de ses dimensions **telles
/// qu'affichées** (l'orientation EXIF est déjà appliquée en amont, voir
/// `ExifFormat.displayDimensions`). Un carré parfait est rangé en paysage
/// (largeur ≥ hauteur) — cas rare, sans conséquence de tri.
enum PhotoOrientation: String, Hashable {
    case landscape
    case portrait

    var label: String {
        switch self {
        case .landscape: return String(localized: "Paysage")
        case .portrait: return String(localized: "Portrait")
        }
    }

    var icon: String {
        switch self {
        case .landscape: return "rectangle"
        case .portrait: return "rectangle.portrait"
        }
    }
}

/// Filtre d'affichage par orientation (paysage / portrait), combinable avec les
/// autres filtres. Comme les filtres EXIF et de netteté, une photo **non encore
/// indexée** (dimensions inconnues) ne matche que « Toutes » : activer un de ces
/// filtres déclenche la passe d'index de la session (voir `GridView`), la grille
/// se remplit au fil des résultats.
enum OrientationFilter: String, CaseIterable, Identifiable {
    case all
    case landscape
    case portrait

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return String(localized: "Toutes")
        case .landscape: return String(localized: "Paysage")
        case .portrait: return String(localized: "Portrait")
        }
    }

    var icon: String {
        switch self {
        case .all: return "rectangle.on.rectangle.angled"
        case .landscape: return "rectangle"
        case .portrait: return "rectangle.portrait"
        }
    }

    @MainActor
    func matches(_ item: PhotoItem) -> Bool {
        switch self {
        case .all:
            return true
        case .landscape:
            return item.orientation == .landscape
        case .portrait:
            return item.orientation == .portrait
        }
    }
}
