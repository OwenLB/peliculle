import SwiftUI

@main
struct PeliculleApp: App {
    // Idée 21 — onboarding gestuel : TipKit doit être configuré au
    // lancement pour que les tips s'affichent.
    // Idée 23 — le délégué de notifications doit être posé avant la fin du
    // lancement pour recevoir le tap qui a lancé l'app à froid.
    init() {
        OnboardingTips.configure()
        NotificationRouter.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
