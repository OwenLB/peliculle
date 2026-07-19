import Foundation

/// Destination des photos enregistrées dans la photothèque (idée 8bis).
/// Réglage **par session de tri** (pas global : un voyage ≠ l'autre), persisté
/// avec elle dans `SessionStore` :
/// - **peliculle** : album unique « Peliculle », tout va dedans (façon
///   Lightroom) ;
/// - **daté** (défaut) : « Peliculle — 7 juil. 2026 » ;
/// - **nommé** : texte libre (« Portugal », « Lisbonne »…), date optionnelle
///   en suffixe pour garder un album par jour dans le contexte du voyage ;
/// - **aucun** : en vrac dans la pellicule, comme avant l'idée 8.
struct AlbumDestination: Codable, Equatable {

    enum Mode: String, Codable, CaseIterable, Identifiable {
        case peliculle
        case dated
        case named
        case none

        var id: Self { self }

        var label: String {
            switch self {
            // « Peliculle » est le nom de l'app (marque) : pas traduit.
            case .peliculle: "Peliculle"
            case .dated: String(localized: "Daté")
            case .named: String(localized: "Nommé")
            case .none: String(localized: "Aucun")
            }
        }
    }

    var mode: Mode = .dated
    var customName: String = ""
    var appendDate: Bool = false

    /// Titre d'album effectif pour un enregistrement **maintenant**, ou `nil`
    /// pour un enregistrement sans album. Nom vide en mode nommé → repli sur
    /// le daté, pour ne jamais créer d'album sans titre.
    var resolvedTitle: String? {
        let today = Date.now.formatted(date: .abbreviated, time: .omitted)
        switch mode {
        case .peliculle:
            return "Peliculle"
        case .dated:
            return "Peliculle — \(today)"
        case .named:
            let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return "Peliculle — \(today)" }
            return appendDate ? "\(name) — \(today)" : name
        case .none:
            return nil
        }
    }
}
