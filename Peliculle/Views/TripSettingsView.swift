import SwiftUI

/// Drawer du Mode Voyage (Jalon 9, idée 15), en sheet demi-hauteur depuis le
/// ⚙️ de la grille — même patron que l'album d'enregistrement. Tout le cycle
/// de vie du voyage vit ici : **activation** (qui crée un voyage neuf par
/// défaut), édition du voyage en cours, fin (toggle coupé = archivage dans
/// l'historique `SavedTrip`), reprise ou suppression d'un voyage passé
/// (balayage). Les bindings écrivent directement dans `session.trip` :
/// l'effet est immédiat (l'affichage entier se borne à la plage) et persisté
/// même si la sheet est balayée. La validation connecte le **nom** du voyage
/// à l'album d'enregistrement (idée 8bis).
struct TripSettingsView: View {
    @Bindable var session: CullSession

    /// Historique hors voyage en cours — copie locale rechargée après chaque
    /// mutation : le balayage de suppression retire l'entrée de la liste,
    /// du registre **et** des sessions persistées (voir `deleteTrips`).
    @State private var pastTrips: [SavedTrip] = []

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Mode Voyage", isOn: isActive)
                } footer: {
                    Text("Borne tout l'affichage (grille, viewer, tri rapide) aux photos prises pendant le voyage.")
                }
                if session.trip.isActive {
                    Section {
                        TextField(
                            "Nom du voyage (Portugal…)",
                            text: $session.trip.name
                        )
                        .textInputAutocapitalization(.words)
                        DatePicker(
                            "Début",
                            selection: $session.trip.startDate,
                            displayedComponents: .date
                        )
                        Toggle("Voyage en cours (fin ouverte)", isOn: openEnded)
                        if session.trip.endDate != nil {
                            DatePicker(
                                "Fin",
                                selection: endDate,
                                in: session.trip.startDate...,
                                displayedComponents: .date
                            )
                        }
                    } header: {
                        Text("Voyage en cours")
                    } footer: {
                        Text("Le nom devient l'album d'enregistrement (« \(session.trip.name.isEmpty ? "Portugal" : session.trip.name) »).")
                    }
                }
                if !pastTrips.isEmpty {
                    Section {
                        ForEach(pastTrips) { trip in
                            Button {
                                resume(trip)
                            } label: {
                                TripRow(trip)
                            }
                            .foregroundStyle(.primary)
                        }
                        .onDelete(perform: deleteTrips)
                    } header: {
                        Text("Voyages passés")
                    } footer: {
                        Text("Touchez un voyage pour le reprendre ; balayez pour le supprimer de l'historique.")
                    }
                }
            }
            .navigationTitle("Voyage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        connectAlbum()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { reloadPastTrips() }
    }

    /// Activer = **créer un voyage neuf** (plage vierge démarrant aujourd'hui,
    /// à nommer) — reprendre un voyage passé se fait dans l'historique
    /// au-dessous. Couper = terminer : archivage dans l'historique puis
    /// désactivation — terminer ne perd jamais un voyage.
    private var isActive: Binding<Bool> {
        Binding(
            get: { session.trip.isActive },
            set: { active in
                if active {
                    session.trip = TripMode(isActive: true)
                } else {
                    var trips = SavedTrip.load()
                    SavedTrip.record(session.trip, in: &trips)
                    session.trip.isActive = false
                }
                reloadPastTrips()
            }
        )
    }

    /// Fin ouverte = voyage en cours (nil). La refermer propose aujourd'hui.
    private var openEnded: Binding<Bool> {
        Binding(
            get: { session.trip.endDate == nil },
            set: { open in
                session.trip.endDate = open
                    ? nil
                    : max(Calendar.current.startOfDay(for: .now), session.trip.startDate)
            }
        )
    }

    private var endDate: Binding<Date> {
        Binding(
            get: { session.trip.endDate ?? .now },
            set: { session.trip.endDate = $0 }
        )
    }

    // MARK: - Historique

    /// Historique global hors voyage courant — rechargé après chaque
    /// mutation plutôt que calculé en direct, pour que la liste ne bouge pas
    /// sous le doigt pendant la frappe du nom.
    private func reloadPastTrips() {
        let all = SavedTrip.load()
        guard session.trip.isActive else {
            pastTrips = all
            return
        }
        let currentID = SavedTrip(session.trip).id
        pastTrips = all.filter { $0.id != currentID }
    }

    /// Reprendre un voyage passé : le courant est archivé implicitement, le
    /// repris redevient le voyage de la session et remonte en tête.
    private func resume(_ saved: SavedTrip) {
        var trips = SavedTrip.load()
        SavedTrip.record(session.trip, in: &trips)
        session.trip = saved.tripMode
        SavedTrip.record(session.trip, in: &trips)
        reloadPastTrips()
    }

    /// Suppression par balayage — voir `SavedTrip.delete` (partagé avec
    /// `LibraryScopeView`).
    private func deleteTrips(at offsets: IndexSet) {
        let removed = offsets.map { pastTrips[$0] }
        pastTrips.remove(atOffsets: offsets)
        SavedTrip.delete(removed)
    }

    /// Idée 15 ↔ 8bis : le voyage nommé alimente l'album d'enregistrement.
    /// Seulement à la validation (pas à chaque frappe), et seulement si un nom
    /// est donné — sans nom, le réglage d'album reste ce qu'il était.
    private func connectAlbum() {
        let name = session.trip.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.trip.isActive, !name.isEmpty else { return }
        session.albumDestination.mode = .named
        session.albumDestination.customName = name
    }
}
