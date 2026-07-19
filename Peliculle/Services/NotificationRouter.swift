import Foundation
import UserNotifications

/// Idée 23 — routage des **taps** de notification : le tap doit mener au bon
/// endroit, pas seulement ouvrir l'app. ① « Tri inachevé » → reprendre la
/// dernière source ; ③ « La passe du soir » → Tri rapide sur les photos du
/// jour. (② « Fin d'enregistrement » est un récap : ouvrir l'app suffit.)
///
/// Le délégué pose une **route en attente**, consommée par la vue capable de
/// l'honorer : `ContentView` restaure une session si besoin (et consomme la
/// reprise), `GridView` ouvre le Tri rapide (via `onChange(initial:)` — la
/// route d'un lancement à froid est posée avant que la grille n'existe).
@MainActor
@Observable
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    enum Route {
        /// ① Tri inachevé : reprendre la dernière source.
        case resume
        /// ③ Passe du soir : Tri rapide sur « Aujourd'hui ».
        case quickCullToday
    }

    /// Route posée par un tap, nil au repos. Chaque consommateur la remet à
    /// nil dès qu'il l'honore — le dernier tap fait foi.
    var pendingRoute: Route?

    /// À appeler au lancement (init de l'app) : le tap qui lance l'app à
    /// froid n'est délivré qu'à un délégué déjà en place.
    func activate() {
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let id = response.notification.request.identifier
        await MainActor.run {
            switch id {
            case CullNotifications.unfinishedID:
                pendingRoute = .resume
            case CullNotifications.tripID:
                pendingRoute = .quickCullToday
            default:
                break
            }
        }
    }
}
