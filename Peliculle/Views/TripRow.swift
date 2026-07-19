import SwiftUI

/// Rangée d'un voyage — nom + plage de dates (« 5 juil. 2026 – … », fin
/// ouverte = en cours). Partagée entre la sheet Voyage (`TripSettingsView`)
/// et le choix de période photothèque (`LibraryScopeView`).
struct TripRow: View {
    let name: String
    let start: Date
    let end: Date?

    init(name: String, start: Date, end: Date?) {
        self.name = name
        self.start = start
        self.end = end
    }

    init(_ trip: SavedTrip) {
        self.init(name: trip.name, start: trip.startDate, end: trip.endDate)
    }

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(name.isEmpty ? String(localized: "Voyage") : name)
                Text(Self.dates(start: start, end: end))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "airplane")
        }
    }

    static func dates(start: Date, end: Date?) -> String {
        let from = start.formatted(date: .abbreviated, time: .omitted)
        guard let end else {
            return String(localized: "Depuis le \(from)")
        }
        return "\(from) – \(end.formatted(date: .abbreviated, time: .omitted))"
    }
}

extension SavedTrip {
    /// Seule sortie **explicite** de l'historique (l'archivage est
    /// implicite). Retire du registre global **et** désactive le voyage dans
    /// les sessions persistées : un fichier de session (carte SD, album,
    /// photothèque) le portant encore actif le ferait ressusciter au
    /// prochain passage (`peekLibraryTrip`).
    static func delete(_ removed: [SavedTrip]) {
        var all = load()
        all.removeAll { trip in removed.contains { $0.id == trip.id } }
        save(all)
        Task { await SessionStore.deactivateTrips(withIDs: Set(removed.map(\.id))) }
    }
}
