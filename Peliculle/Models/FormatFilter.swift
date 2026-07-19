import Foundation

/// F8 — filtre d'affichage par format. « Tous », un raccourci « RAW », un
/// raccourci « Vidéos » (idée 18), puis une entrée par extension réellement
/// présente dans la session.
enum FormatFilter: Hashable, Identifiable {
    case all
    case raw
    case video
    case ext(String)

    var id: String {
        switch self {
        case .all: return "all"
        case .raw: return "raw"
        case .video: return "video"
        case .ext(let value): return "ext-\(value)"
        }
    }

    var label: String {
        switch self {
        case .all: return String(localized: "Tous")
        // « RAW » et les extensions sont des termes techniques universels.
        case .raw: return "RAW"
        case .video: return String(localized: "Vidéos")
        case .ext(let value): return value
        }
    }

    var icon: String {
        switch self {
        case .all: return "photo.stack"
        case .raw: return "camera.aperture"
        case .video: return "video"
        case .ext: return "doc"
        }
    }

    func matches(_ item: PhotoItem) -> Bool {
        switch self {
        case .all: return true
        case .raw: return item.isRAW
        case .video: return item.isVideo
        case .ext(let value): return item.formatExtension == value
        }
    }

    /// Construit la liste des filtres pertinents pour un ensemble de photos.
    static func available(for items: [PhotoItem]) -> [FormatFilter] {
        var filters: [FormatFilter] = [.all]
        if items.contains(where: { $0.isRAW }) {
            filters.append(.raw)
        }
        if items.contains(where: { $0.isVideo }) {
            filters.append(.video)
        }
        // Extension inconnue (assets photothèque, Jalon 10) : pas d'entrée
        // vide — sans extensions, le filtre format n'apparaît pas du tout.
        let extensions = Set(items.map(\.formatExtension)).subtracting([""]).sorted()
        filters.append(contentsOf: extensions.map { .ext($0) })
        return filters
    }
}
