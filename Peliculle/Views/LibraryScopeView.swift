import SwiftUI

/// Choix de la **période** avant d'ouvrir la photothèque : la borne descend
/// dans le prédicat du fetch PhotoKit (`LibraryScope.fetchBounds`) — les
/// photos hors période ne sont jamais chargées, ce qui rend une photothèque
/// de milliers de photos triable. « Toutes les photos » reste disponible
/// pour le grand ménage assumé.
///
/// Pas de création de voyage ici : si un voyage est **en cours** (persisté
/// par la session photothèque, actif), on propose de filtrer dessus, et
/// l'historique global (`SavedTrip`) permet de rouvrir un voyage passé —
/// ses décisions de tri d'époque se retrouvent telles quelles. La
/// création/édition reste dans le réglage ⚙️ de la grille.
struct LibraryScopeView: View {
    /// Voyage actif persisté (`SessionStore.peekLibraryTrip`), nil sinon.
    var currentTrip: TripMode?
    /// Période choisie + Mode Voyage à activer (nil pour un choix hors
    /// voyage : le périmètre explicite remplace un voyage persisté).
    var onChoose: (LibraryScope, TripMode?) -> Void

    /// Historique hors voyage en cours — copie locale : le swipe de
    /// suppression retire l'entrée de la liste **et** du registre.
    @State private var pastTrips: [SavedTrip]

    @State private var rangeStart = Calendar.current.startOfDay(for: .now)
    @State private var rangeEnd = Date.now

    @Environment(\.dismiss) private var dismiss

    init(
        currentTrip: TripMode?,
        pastTrips: [SavedTrip] = [],
        onChoose: @escaping (LibraryScope, TripMode?) -> Void
    ) {
        self.currentTrip = currentTrip
        self.onChoose = onChoose
        _pastTrips = State(initialValue: pastTrips)
    }

    var body: some View {
        NavigationStack {
            List {
                if let trip = currentTrip {
                    Section("Voyage en cours") {
                        Button {
                            onChoose(.range(start: trip.startDate, end: trip.endDate), trip)
                        } label: {
                            TripRow(name: trip.name, start: trip.startDate, end: trip.endDate)
                        }
                    }
                }
                Section {
                    Button {
                        onChoose(.lastDays(7), nil)
                    } label: {
                        Label { Text("\(7) derniers jours") } icon: { Image(systemName: "calendar") }
                    }
                    Button {
                        onChoose(.lastDays(30), nil)
                    } label: {
                        Label { Text("\(30) derniers jours") } icon: { Image(systemName: "calendar") }
                    }
                    Button {
                        onChoose(.all, nil)
                    } label: {
                        Label("Toutes les photos", systemImage: "photo.on.rectangle.angled")
                    }
                }
                if !pastTrips.isEmpty {
                    Section("Voyages passés") {
                        ForEach(pastTrips) { trip in
                            Button {
                                onChoose(
                                    .range(start: trip.startDate, end: trip.endDate),
                                    trip.tripMode
                                )
                            } label: {
                                TripRow(trip)
                            }
                        }
                        .onDelete(perform: deleteTrips)
                    }
                }
                Section("Période personnalisée") {
                    DatePicker("Du", selection: $rangeStart, displayedComponents: .date)
                    DatePicker("Au", selection: $rangeEnd, in: rangeStart..., displayedComponents: .date)
                    Button("Ouvrir la période") {
                        onChoose(.range(start: rangeStart, end: rangeEnd), nil)
                    }
                }
            }
            .navigationTitle("Photothèque")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
    }

    /// Suppression par balayage — voir `SavedTrip.delete` (partagé avec
    /// `TripSettingsView`).
    private func deleteTrips(at offsets: IndexSet) {
        let removed = offsets.map { pastTrips[$0] }
        pastTrips.remove(atOffsets: offsets)
        SavedTrip.delete(removed)
    }
}

#Preview {
    LibraryScopeView(currentTrip: nil) { _, _ in }
}
