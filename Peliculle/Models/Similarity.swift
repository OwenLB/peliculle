import Foundation

/// Détection de photos **visuellement similaires** (idée : culling assisté).
/// Le principe : le **temps borne** les comparaisons (fenêtre glissante, coût
/// quasi-linéaire), la **vision tranche** à l'intérieur (empreinte Vision,
/// `SimilarityIndex`). Deux photos rejoignent le même groupe si elles sont
/// proches **dans le temps** *et* **visuellement** — un panoramique (5 cadrages
/// en 4 s) se sépare, une redite 2 min plus tard se rejoint.
///
/// Ce fichier ne porte que la **logique pure** (groupement) et les **réglages** :
/// aucune dépendance à Vision, pour rester testable sans device.

/// Fenêtre temporelle **maximale** entre deux photos d'un même groupe de
/// similaires (secondes). Exigence produit : des photos similaires doivent
/// **obligatoirement être proches dans le temps** — deux couchers de soleil de
/// jours différents ne sont pas des sosies. On borne donc **toujours** par le
/// temps (10 min), quel que soit le périmètre ; la distance visuelle tranche à
/// l'intérieur de cette fenêtre. Une rafale plus longue que la fenêtre chaîne
/// quand même de proche en proche (chaque photo a sa propre fenêtre glissante).
let similarityInterval: TimeInterval = 600

/// Fenêtre temporelle à appliquer pour un périmètre de `count` photos :
/// **toujours** bornée (proximité temporelle obligatoire, voir
/// `similarityInterval`) — le paramètre reste pour un éventuel ajustement futur
/// selon la taille du périmètre.
func similarityMaxInterval(for count: Int) -> TimeInterval {
    similarityInterval
}

/// Sensibilité de la détection = **seuil de distance visuelle** (3 crans).
/// La distance vient de `VNFeaturePrintObservation.computeDistance` : ~0 =
/// identique, plus c'est grand plus c'est différent. Les seuils ci-dessous sont
/// des **valeurs de départ à calibrer sur device** (paysage / ville) — l'échelle
/// exacte dépend de la révision Vision. Persisté en `@AppStorage` (rawValue).
enum SimilaritySensitivity: String, CaseIterable, Identifiable {
    case strict
    case normal
    case loose

    var id: String { rawValue }

    /// Seuil de distance : en dessous, deux photos sont « similaires ».
    /// TODO device : affiner ces trois valeurs sur de vraies photos.
    var maxDistance: Float {
        switch self {
        case .strict: return 0.35
        case .normal: return 0.55
        case .loose: return 0.75
        }
    }

    var label: String {
        switch self {
        case .strict: return String(localized: "Stricte")
        case .normal: return String(localized: "Normale")
        case .loose: return String(localized: "Large")
        }
    }
}

/// Groupement pur des similaires : à partir d'items **triés par date** et d'une
/// fonction de distance, relie ceux qui sont à la fois dans la fenêtre
/// temporelle **et** sous le seuil de distance (union-find). Isolé de Vision
/// exprès — l'acteur `SimilarityIndex` fournit la fonction de distance réelle,
/// les tests fournissent des distances synthétiques.
enum SimilarityGrouper {

    /// - Parameters:
    ///   - count: nombre d'items.
    ///   - date: date de l'item `i` (l'appelant garantit l'ordre **croissant**).
    ///   - distance: distance visuelle entre `i` et `j` (nil = incomparable →
    ///     jamais liés).
    ///   - maxInterval: fenêtre temporelle (secondes) au-delà de laquelle on ne
    ///     compare plus deux photos.
    ///   - maxDistance: seuil de similarité visuelle.
    /// - Returns: les groupes (indices) de **taille ≥ 2**, chacun trié par
    ///   index croissant, l'ensemble ordonné par premier index — déterministe.
    static func groups(
        count: Int,
        date: (Int) -> Date,
        distance: (Int, Int) -> Float?,
        maxInterval: TimeInterval,
        maxDistance: Float
    ) -> [[Int]] {
        guard count > 1 else { return [] }

        var parent = Array(0..<count)
        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root {
                parent[root] = parent[parent[root]] // compression de chemin
                root = parent[root]
            }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }

        // Fenêtre glissante : pour chaque i, on ne regarde que les j suivants
        // tant qu'ils sont à moins de `maxInterval`. Une rafale continue plus
        // longue que la fenêtre chaîne quand même, de proche en proche (chaque
        // index a sa propre fenêtre vers l'avant).
        for i in 0..<count {
            let anchor = date(i)
            var j = i + 1
            while j < count, date(j).timeIntervalSince(anchor) <= maxInterval {
                if let d = distance(i, j), d <= maxDistance {
                    union(i, j)
                }
                j += 1
            }
        }

        var components: [Int: [Int]] = [:]
        for i in 0..<count { components[find(i), default: []].append(i) }
        return components.values
            .filter { $0.count >= 2 }
            .sorted { ($0.first ?? 0) < ($1.first ?? 0) }
    }
}
