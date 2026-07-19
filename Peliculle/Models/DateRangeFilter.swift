import Foundation

/// Filtre de dates de la grille (menu filtres) : bornes Du/Au **optionnelles**
/// et indépendantes, au jour, sur la date de prise de vue (repli date
/// fichier — `PhotoItem.captureDate`). Mêmes conventions que `TripMode` :
/// bornes incluses, photo sans date exclue quand une borne est active.
/// Inerte en Mode Voyage : le voyage fait autorité sur la plage affichée
/// (l'entrée du menu filtres la montre, verrouillée).
struct DateRangeFilter: Equatable {
    /// Premier jour inclus (nil = pas de borne basse).
    var start: Date?
    /// Dernier jour inclus (nil = pas de borne haute).
    var end: Date?

    var isActive: Bool { start != nil || end != nil }

    func matches(_ date: Date?) -> Bool {
        guard isActive else { return true }
        guard let date else { return false }
        let calendar = Calendar.current
        if let start, date < calendar.startOfDay(for: start) {
            return false
        }
        if let end,
           let dayAfterEnd = calendar.date(
               byAdding: .day, value: 1, to: calendar.startOfDay(for: end)
           ),
           date >= dayAfterEnd {
            return false
        }
        return true
    }
}
