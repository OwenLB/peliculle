import Foundation
import UserNotifications

/// Idée 23 (batch G2) — notifications **100 % locales** (`UserNotifications`,
/// aucun backend, rien ne quitte l'iPhone) :
/// - **① Tri inachevé** : on quitte l'app avec des photos non triées → rappel
///   à l'heure choisie, annulé au retour ou quand le tri est fini.
/// - **② Fin d'enregistrement** : le batch se termine alors que l'app n'est
///   plus à l'écran → récap immédiat.
/// - **③ La passe du soir** : rappel quotidien pendant un voyage actif,
///   s'arrête seul à la fin du voyage.
///
/// Chaque notification a son **interrupteur** et, pour ① et ③, son **heure**
/// (réglages dans `NotificationSettingsView`, ⚙️ › Notifications…). La
/// permission système n'est **jamais** demandée à froid : elle part d'un
/// contexte (retour sur une session entamée, activation d'un réglage ou d'un
/// voyage).
enum CullNotifications {

    /// Clés UserDefaults, partagées avec les `@AppStorage` de la vue de
    /// réglages. ① et ② sont actives par défaut (elles ne vivent qu'après la
    /// permission) ; ③ est **opt-in**.
    enum Keys {
        static let unfinishedEnabled = "notif.unfinished.enabled"
        static let unfinishedMinutes = "notif.unfinished.minutes"
        static let saveDoneEnabled = "notif.saveDone.enabled"
        static let tripEnabled = "notif.trip.enabled"
        static let tripMinutes = "notif.trip.minutes"
    }

    /// Heures par défaut, en minutes depuis minuit : rappel de tri à 20 h,
    /// passe du soir à 21 h.
    static let defaultUnfinishedMinutes = 20 * 60
    static let defaultTripMinutes = 21 * 60

    /// Identifiants stables des requêtes — aussi les clés de routage des
    /// taps (`NotificationRouter`).
    static let unfinishedID = "peliculle.tri-inacheve"
    static let saveDoneID = "peliculle.enregistrement"
    static let tripID = "peliculle.passe-du-soir"

    private static var defaults: UserDefaults { .standard }

    static var unfinishedEnabled: Bool {
        defaults.object(forKey: Keys.unfinishedEnabled) as? Bool ?? true
    }
    static var saveDoneEnabled: Bool {
        defaults.object(forKey: Keys.saveDoneEnabled) as? Bool ?? true
    }
    static var tripEnabled: Bool {
        defaults.object(forKey: Keys.tripEnabled) as? Bool ?? false
    }
    static var unfinishedMinutes: Int {
        defaults.object(forKey: Keys.unfinishedMinutes) as? Int ?? defaultUnfinishedMinutes
    }
    static var tripMinutes: Int {
        defaults.object(forKey: Keys.tripMinutes) as? Int ?? defaultTripMinutes
    }

    // MARK: - Permission

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }

    /// Demande la permission système si la question n'est pas déjà tranchée.
    @discardableResult
    static func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        default:
            return true
        }
    }

    /// Le **contexte** de la demande pour ① : on revient sur une session dont
    /// le tri est **entamé mais pas fini** — exactement le moment où un
    /// rappel a du sens. Jamais d'alerte au premier lancement.
    @MainActor
    static func requestPermissionInContext(session: CullSession) async {
        guard unfinishedEnabled else { return }
        guard await authorizationStatus() == .notDetermined else { return }
        let undecided = undecidedCount(in: session)
        guard undecided > 0, undecided < session.items.count else { return }
        await requestPermission()
    }

    // MARK: - ① Tri inachevé

    /// À l'entrée en arrière-plan : programme (ou annule) le rappel selon ce
    /// qui reste à trier. Sans permission, `add` échoue en silence — la
    /// demande, elle, part du retour au premier plan (contexte).
    @MainActor
    static func scheduleUnfinishedOnExit(session: CullSession) {
        cancelUnfinished()
        guard unfinishedEnabled else { return }
        let count = undecidedCount(in: session)
        guard count > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Reprendre le tri")
        content.body = String(localized: "\(count) photo(s) à trier sur « \(session.source.displayName) ».")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: unfinishedID,
            content: content,
            trigger: UNCalendarNotificationTrigger(
                dateMatching: nextOccurrence(ofMinutes: unfinishedMinutes),
                repeats: false
            )
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Au retour au premier plan : l'utilisateur est là, le rappel n'a plus
    /// d'objet.
    static func cancelUnfinished() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [unfinishedID])
    }

    // MARK: - ② Fin d'enregistrement

    /// Récap immédiat quand le batch se termine hors premier plan. Le message
    /// est celui de l'alerte in-app — une seule vérité.
    static func notifySaveDone(message: String) {
        guard saveDoneEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Enregistrement terminé")
        content.body = message
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: saveDoneID, content: content, trigger: nil)
        )
    }

    // MARK: - ③ La passe du soir (Mode Voyage)

    /// Aligne le rappel quotidien sur l'état du voyage : actif (et pas déjà
    /// terminé) → programmé à l'heure choisie ; sinon → annulé. Rappelable à
    /// volonté (réglage, activation, fin de voyage) — l'identifiant est
    /// stable, le dernier appel fait foi.
    static func syncTripReminder(trip: TripMode) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [tripID])
        guard tripEnabled, trip.isActive else { return }
        if let end = trip.endDate,
           end < Calendar.current.startOfDay(for: .now) { return }

        let name = trip.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = UNMutableNotificationContent()
        content.title = name.isEmpty ? String(localized: "Voyage") : name
        content.body = String(localized: "La passe du soir ? Les photos du jour n'attendent que le tri.")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: tripID,
            content: content,
            trigger: UNCalendarNotificationTrigger(
                dateMatching: DateComponents(
                    hour: tripMinutes / 60,
                    minute: tripMinutes % 60
                ),
                repeats: true
            )
        )
        center.add(request)
    }

    /// Le voyage vient de changer (activation, édition, fin) : demander la
    /// permission si le rappel est attendu, puis aligner.
    static func tripChanged(_ trip: TripMode) async {
        if tripEnabled, trip.isActive {
            await requestPermission()
        }
        syncTripReminder(trip: trip)
    }

    // MARK: - Aides

    @MainActor
    private static func undecidedCount(in session: CullSession) -> Int {
        session.items.count { $0.decision == .undecided }
    }

    /// Prochaine occurrence de l'heure choisie : aujourd'hui si elle n'est
    /// pas passée, sinon demain.
    private static func nextOccurrence(ofMinutes minutes: Int) -> DateComponents {
        let calendar = Calendar.current
        var date = calendar.date(
            bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now
        ) ?? .now
        if date <= .now {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
        }
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }
}
