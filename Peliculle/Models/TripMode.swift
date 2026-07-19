import Foundation

/// Mode Voyage (Jalon 9, idée 15) : borne l'affichage entier (grille, viewer,
/// tri rapide) à la plage de dates du voyage, sur la **date de prise de vue**
/// (repli date fichier, voir `PhotoItem.captureDate`). Le nom du voyage est
/// connecté à l'album d'enregistrement (idée 8bis). Persisté avec la session.
struct TripMode: Codable, Equatable {
    var isActive = false
    var name = ""
    /// Début du voyage (jour, borne incluse). Défaut : aujourd'hui.
    var startDate = Calendar.current.startOfDay(for: .now)
    /// Fin **optionnelle** (jour, borne incluse) — nil = voyage en cours,
    /// plage ouverte.
    var endDate: Date?

    /// Vrai si une date de prise de vue tombe dans le voyage. Mode inactif =
    /// tout passe ; photo sans date = exclue quand le mode est actif (le
    /// voyage est par définition un filtre de dates).
    func matches(_ date: Date?) -> Bool {
        guard isActive else { return true }
        guard let date else { return false }
        let calendar = Calendar.current
        guard date >= calendar.startOfDay(for: startDate) else { return false }
        if let endDate,
           let dayAfterEnd = calendar.date(
               byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)
           ),
           date >= dayAfterEnd {
            return false
        }
        return true
    }
}

/// Historique **global** des voyages — hors des sessions : un voyage (plage
/// de dates nommée) vaut pour toutes les sources. Archivage **implicite** :
/// tout voyage activé (réglage ⚙️, sheet de période) est enregistré en tête,
/// les précédents restent derrière — en créer un nouveau n'écrase plus rien.
/// Rouvrir un voyage passé refait un fetch borné sur ses dates ; les
/// décisions étant persistées par photo (`SessionStore`), le tri d'époque se
/// retrouve tel quel. Suppression par geste explicite (swipe dans la sheet).
struct SavedTrip: Codable, Identifiable, Equatable {
    var name: String
    var startDate: Date
    var endDate: Date?

    /// Identité de dédoublonnage : le **nom** (insensible à la casse) —
    /// rééditer les dates d'un voyage nommé le met à jour au lieu de le
    /// dupliquer — ou la plage de dates pour un voyage sans nom.
    var id: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.isEmpty else { return trimmed }
        let end = endDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "-"
        return "range|\(startDate.timeIntervalSinceReferenceDate)|\(end)"
    }

    init(_ trip: TripMode) {
        self.name = trip.name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.startDate = trip.startDate
        self.endDate = trip.endDate
    }

    /// `TripMode` actif équivalent, prêt à appliquer à une session.
    var tripMode: TripMode {
        TripMode(isActive: true, name: name, startDate: startDate, endDate: endDate)
    }

    private static let storageKey = "peliculle.savedTrips"

    static func load() -> [SavedTrip] {
        RecentList.load(key: storageKey)
    }

    static func save(_ list: [SavedTrip]) {
        RecentList.save(list, key: storageKey)
    }

    /// Enregistre (ou remonte en tête) un voyage **actif** — un voyage
    /// inactif est ignoré. Borné à 10 : au-delà, l'historique ne vaut plus
    /// sa place dans la sheet.
    static func record(_ trip: TripMode, in list: inout [SavedTrip]) {
        guard trip.isActive else { return }
        RecentList.record(SavedTrip(trip), in: &list, key: storageKey, limit: 10)
    }
}
