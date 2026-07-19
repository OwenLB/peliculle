import Foundation

/// Filtre d'affichage par état de tri (complète le filtre format F8 et le
/// filtre de note F10). Utile pour relire ses gardées avant enregistrement ou
/// retrouver ce qui reste à trier.
enum DecisionFilter: String, CaseIterable, Identifiable {
    case all
    case keep
    case reject
    case undecided

    var id: String { rawValue }

    /// Jalon 11 — les libellés dynamiques (hors littéraux SwiftUI) passent
    /// par `String(localized:)` pour rejoindre le String Catalog.
    var label: String {
        switch self {
        case .all: return String(localized: "Toutes")
        case .keep: return String(localized: "Gardées")
        case .reject: return String(localized: "Rejetées")
        case .undecided: return String(localized: "Non triées")
        }
    }

    var icon: String {
        switch self {
        case .all: return "photo.on.rectangle.angled"
        case .keep: return "checkmark.circle"
        case .reject: return "xmark.circle"
        case .undecided: return "questionmark.circle"
        }
    }

    // Les prédicats lisent l'état de tri des items (isolé main actor) — ils
    // ne servent qu'au filtrage d'affichage, sur le main thread.
    @MainActor
    func matches(_ item: PhotoItem) -> Bool {
        switch self {
        case .all: return true
        case .keep: return item.decision == .keep
        case .reject: return item.decision == .reject
        case .undecided: return item.decision == .undecided
        }
    }
}
