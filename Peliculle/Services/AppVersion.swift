import Foundation

/// Version lisible de l'app (« 0.1 (1) »), lue dans le bundle — une seule
/// vérité : `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` du projet Xcode.
/// Affichée en pied d'accueil et en tête du diagnostic de session (le rapport
/// se partage : savoir de quelle version il vient).
enum AppVersion {
    /// « 0.1 (1) » — version marketing + numéro de build.
    static var display: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
