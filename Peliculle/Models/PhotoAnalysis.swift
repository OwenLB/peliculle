import Foundation

/// Signaux de pré-tri d'une photo (Jalon 7), calculés on-device par
/// `VisionAnalyzer` sur l'aperçu ~400 px. De purs **indicateurs** : aucun
/// signal ne déclenche jamais une décision automatique, l'utilisateur reste
/// maître (voir ROADMAP).
/// `Codable` : les signaux sont persistés par `VisionAnalyzer` (cache disque
/// par `cacheKey`) — sur une photothèque de milliers de photos, la passe
/// d'analyse ne doit tourner qu'une fois, pas à chaque session.
struct PhotoAnalysis: Equatable, Codable {
    /// Score esthétique Vision (iOS 18+), ramené à 0…1. Pas de seuil maison à
    /// caler : il sert au tri d'affichage (`PhotoSort.aesthetic`) et à
    /// l'information (fiche EXIF), jamais d'alerte.
    var aestheticScore: Double?
}
