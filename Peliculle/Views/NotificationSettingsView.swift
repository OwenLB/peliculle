import SwiftUI
import UIKit

/// Idée 23 (batch G2) — réglages des notifications (⚙️ › Notifications…) :
/// chaque notification a son **interrupteur** indépendant, et les planifiées
/// (rappel de tri, passe du soir) leur **heure**. Activer un interrupteur
/// demande la permission système **à ce moment-là** (contexte) ; si elle a
/// été refusée, la vue pointe vers Réglages au lieu de faire semblant.
struct NotificationSettingsView: View {
    let session: CullSession

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @AppStorage(CullNotifications.Keys.unfinishedEnabled)
    private var unfinishedEnabled = true
    @AppStorage(CullNotifications.Keys.unfinishedMinutes)
    private var unfinishedMinutes = CullNotifications.defaultUnfinishedMinutes
    @AppStorage(CullNotifications.Keys.saveDoneEnabled)
    private var saveDoneEnabled = true
    @AppStorage(CullNotifications.Keys.tripEnabled)
    private var tripEnabled = false
    @AppStorage(CullNotifications.Keys.tripMinutes)
    private var tripMinutes = CullNotifications.defaultTripMinutes

    @State private var denied = false

    var body: some View {
        NavigationStack {
            Form {
                if denied {
                    Section {
                        Label(
                            "Notifications désactivées pour Peliculle — réactivez-les dans Réglages.",
                            systemImage: "bell.slash"
                        )
                        .foregroundStyle(.secondary)
                        Button("Ouvrir Réglages") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                openURL(url)
                            }
                        }
                    }
                }

                Section {
                    Toggle("Rappel de tri inachevé", isOn: $unfinishedEnabled)
                    if unfinishedEnabled {
                        DatePicker(
                            "Heure du rappel",
                            selection: timeBinding($unfinishedMinutes),
                            displayedComponents: .hourAndMinute
                        )
                    }
                } footer: {
                    Text("S'il reste des photos à trier quand vous quittez l'app, un rappel est programmé à cette heure — annulé dès que vous revenez.")
                }

                Section {
                    Toggle("Fin d'enregistrement", isOn: $saveDoneEnabled)
                } footer: {
                    Text("Prévient quand un enregistrement se termine alors que l'app n'est plus à l'écran.")
                }

                Section {
                    Toggle("La passe du soir", isOn: $tripEnabled)
                    if tripEnabled {
                        DatePicker(
                            "Heure",
                            selection: timeBinding($tripMinutes),
                            displayedComponents: .hourAndMinute
                        )
                    }
                } header: {
                    Text("Voyage")
                } footer: {
                    Text("Chaque jour pendant un voyage actif, un rappel pour trier les photos de la journée. S'arrête à la fin du voyage.")
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .task { await refreshDeniedState() }
            .onChange(of: unfinishedEnabled) { _, on in
                if on { requestPermission() }
            }
            .onChange(of: saveDoneEnabled) { _, on in
                if on { requestPermission() }
            }
            .onChange(of: tripEnabled) { _, on in
                if on { requestPermission() }
                CullNotifications.syncTripReminder(trip: session.trip)
            }
            .onChange(of: tripMinutes) {
                CullNotifications.syncTripReminder(trip: session.trip)
            }
        }
    }

    private func requestPermission() {
        Task {
            await CullNotifications.requestPermission()
            await refreshDeniedState()
        }
    }

    private func refreshDeniedState() async {
        denied = await CullNotifications.authorizationStatus() == .denied
    }

    /// Les heures sont stockées en minutes depuis minuit (`@AppStorage`) ;
    /// le `DatePicker` veut une `Date` — conversion aller-retour, le jour
    /// n'a aucune importance.
    private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: minutes.wrappedValue / 60,
                    minute: minutes.wrappedValue % 60,
                    second: 0,
                    of: .now
                ) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}
