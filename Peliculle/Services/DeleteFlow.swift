import Foundation

/// Flux de suppression **partagé** entre la grille (sélection, purge des
/// rejetées, menu contextuel) et le viewer (photo courante) — revue qualité :
/// les textes de confirmation et la composition des messages étaient
/// dupliqués mot pour mot entre les deux vues.
///
/// Le flux porte la suppression effective (`PhotoDeleter`), le retrait de la
/// session et la composition des messages ; l'appelant garde la présentation
/// (alertes de confirmation, toast/alerte, retrait des pages du viewer).
@MainActor
enum DeleteFlow {

    /// Issue de la suppression. `deleted` : les photos réellement supprimées
    /// (déjà retirées de la session). `cancelled` : dialogue système refusé,
    /// un choix et non un échec — rien à dire si rien n'a été supprimé.
    struct Outcome {
        var deleted: [PhotoItem] = []
        var failed = 0
        var cancelled = false
        var errorMessage: String?
    }

    /// Supprime les photos de leur source (après confirmation de l'appelant),
    /// retire les supprimées de la session et compose le message d'échec.
    static func run(_ items: [PhotoItem], session: CullSession) async -> Outcome {
        let summary = await PhotoDeleter.delete(items)
        session.remove(summary.deleted)
        var outcome = Outcome(
            deleted: summary.deleted,
            failed: summary.failed,
            cancelled: summary.cancelled
        )
        if summary.failed > 0 {
            // Photo seule (viewer, menu contextuel) : l'échec la nomme.
            if items.count == 1, let item = items.first {
                outcome.errorMessage = String(localized: "La suppression de \(item.filename) a échoué.")
            } else {
                outcome.errorMessage = summary.deleted.isEmpty
                    ? String(localized: "\(summary.failed) suppression(s) en échec.")
                    : String(localized: "\(summary.deleted.count) supprimée(s), \(summary.failed) en échec.")
            }
        }
        return outcome
    }

    // MARK: - Textes de confirmation (partagés grille / viewer)

    /// Avertissement pour **une** photo, adapté à sa provenance — correct en
    /// session combinée où l'UI décide par photo (`isLibraryBacked`).
    static func confirmationMessage(for item: PhotoItem) -> String {
        item.isLibraryBacked
            ? String(localized: "\(item.filename) sera supprimée de votre photothèque (récupérable 30 jours dans « Supprimés récemment »).")
            : String(localized: "\(item.filename) sera définitivement supprimée de la carte SD. Cette action est irréversible.")
    }

    /// Avertissement pour un **lot**, adapté aux sources de la session. La
    /// suppression photothèque est en plus re-confirmée par le dialogue
    /// système PhotoKit. En combiné, le message couvre les deux mondes.
    static func confirmationMessage(session: CullSession) -> String {
        if session.isCombined && session.hasFileSource && session.hasLibrarySource {
            return String(localized: "Les fichiers seront supprimés de la carte, les photos de la photothèque (récupérables 30 jours). Action irréversible sur la carte.")
        }
        return session.isLibraryOnly
            ? String(localized: "Les photos seront supprimées de votre photothèque (récupérables 30 jours dans « Supprimés récemment »).")
            : String(localized: "Les fichiers seront définitivement supprimés de la carte SD. Cette action est irréversible.")
    }
}
