import Foundation
import Testing
@testable import Peliculle

/// Logique pure du groupement de similaires (`SimilarityGrouper`) — temps +
/// distance, sans Vision : distances synthétiques injectées.
struct SimilarityGrouperTests {

    private let epoch = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Construit les dates (offsets en secondes) et une fonction de distance
    /// à partir d'une table de paires ; les paires absentes valent « loin ».
    private func run(
        offsets: [TimeInterval],
        pairs: [String: Float],
        maxInterval: TimeInterval = 120,
        maxDistance: Float = 0.5
    ) -> [[Int]] {
        let dates = offsets.map { epoch.addingTimeInterval($0) }
        return SimilarityGrouper.groups(
            count: offsets.count,
            date: { dates[$0] },
            distance: { a, b in pairs["\(min(a, b))-\(max(a, b))"] ?? 10 },
            maxInterval: maxInterval,
            maxDistance: maxDistance
        )
    }

    @Test func procheTempsEtVisuelRegroupe() {
        // 0 et 1 : 10 s d'écart, distance 0,2 → un groupe.
        let groups = run(offsets: [0, 10], pairs: ["0-1": 0.2])
        #expect(groups == [[0, 1]])
    }

    @Test func procheTempsMaisVisuellementDifferentSepare() {
        // 10 s d'écart mais distance 0,9 (> seuil) → aucun groupe.
        let groups = run(offsets: [0, 10], pairs: ["0-1": 0.9])
        #expect(groups.isEmpty)
    }

    @Test func procheVisuelMaisHorsFenetreTempsSepare() {
        // Visuellement identiques (0,1) mais à 5 min → hors fenêtre, séparées.
        let groups = run(offsets: [0, 300], pairs: ["0-1": 0.1])
        #expect(groups.isEmpty)
    }

    @Test func chainageTransitifAuDelaDeLaFenetre() {
        // a→b (60 s) et b→c (60 s) proches et similaires ; a→c = 120 s (dans la
        // fenêtre pile) mais on ne compte pas dessus : le chaînage b→c suffit.
        let groups = run(
            offsets: [0, 60, 130],
            pairs: ["0-1": 0.2, "1-2": 0.2] // a-c absent (donc « loin »)
        )
        #expect(groups == [[0, 1, 2]])
    }

    @Test func deuxGroupesDistinctsOrdonnes() {
        // {0,1} tôt, {3,4} plus tard ; 2 isolée. Ordre par premier index.
        let groups = run(
            offsets: [0, 10, 400, 800, 810],
            pairs: ["0-1": 0.2, "3-4": 0.2]
        )
        #expect(groups == [[0, 1], [3, 4]])
    }

    @Test func distanceIncomparableNeGroupePas() {
        // Une empreinte manquante (nil) ne lie jamais.
        let groups = SimilarityGrouper.groups(
            count: 2,
            date: { [epoch, epoch.addingTimeInterval(5)][$0] },
            distance: { _, _ in nil },
            maxInterval: 120,
            maxDistance: 0.5
        )
        #expect(groups.isEmpty)
    }

    @Test func photoSeuleOuListeVideNeRegroupePas() {
        #expect(run(offsets: [], pairs: [:]).isEmpty)
        #expect(run(offsets: [0], pairs: [:]).isEmpty)
    }
}
