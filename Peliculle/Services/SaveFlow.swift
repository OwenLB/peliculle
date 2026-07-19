import UIKit

/// Flux d'enregistrement **partagé** entre la grille (lot/sélection) et le
/// viewer (photo courante) — revue qualité : les deux vues dupliquaient
/// garde-fous, pré-vol, appel `PhotoSaver` et messages, et divergeaient déjà
/// (la tâche d'arrière-plan et la notification de fin manquaient au viewer).
///
/// Le flux porte tout ce qui ne dépend pas de la présentation : garde-fou
/// album, pré-vol espace disque, tâche d'arrière-plan (le lot survit au
/// passage en arrière-plan), enregistrement, persistance, composition des
/// messages et notification de fin hors écran (idée 23 ②). L'appelant garde
/// la présentation : confirmation d'album en amont, progression, toast/alerte.
@MainActor
enum SaveFlow {

    /// Issue du flux, à présenter selon la politique UX4 : succès en toast,
    /// échec ou empêchement en alerte. Au plus un des deux est non-nil.
    struct Outcome {
        var successToast: String?
        var errorMessage: String?
    }

    /// Enregistre le lot (copie pellicule pour un fichier, ajout à l'album
    /// pour un asset — voir `PhotoSaver`) et renvoie le message à afficher.
    /// `isAppActive` (scenePhase de l'appelant) : faux quand le lot se
    /// termine hors écran → le récap part en notification, succès comme échec.
    static func run(
        _ items: [PhotoItem],
        session: CullSession,
        isAppActive: Bool = true,
        progress: @MainActor (Int) -> Void = { _ in }
    ) async -> Outcome {
        guard !items.isEmpty else { return Outcome() }

        // Jalon 10 / H5 — un asset photothèque « se garde » en l'ajoutant à
        // l'album : dès que le lot en contient un, un album de destination
        // est requis (sinon ces photos échoueraient, les fichiers passant).
        if items.contains(where: { $0.isLibraryBacked }),
           session.albumDestination.resolvedTitle == nil {
            return Outcome(errorMessage: String(localized: "Choisissez un album de destination : sur la photothèque, garder = ajouter à l'album."))
        }
        // Idée 20 — pré-vol : ne jamais démarrer un lot qui échouera à
        // mi-course faute de place sur l'iPhone.
        if let warning = SavePreflight.insufficientSpaceMessage(for: items) {
            return Outcome(errorMessage: warning)
        }

        // Idée 22 — le batch continue si on quitte l'app (sursis système).
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "PeliculleSave")
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        let outcome: Outcome
        do {
            let result = try await PhotoSaver.save(
                items,
                albumTitle: session.albumDestination.resolvedTitle,
                progress: progress
            )
            // Les marquages `savedToLibrary` doivent survivre au redémarrage.
            session.persistSoon()
            outcome = Self.outcome(of: result, items: items)
        } catch {
            outcome = Outcome(errorMessage: error.localizedDescription)
        }

        // Idée 23 — ② : le lot s'est terminé alors que l'app n'est plus à
        // l'écran → le récap part en notification (le toast s'afficherait
        // dans le vide).
        if !isAppActive, let message = outcome.errorMessage ?? outcome.successToast {
            CullNotifications.notifySaveDone(message: message)
        }
        return outcome
    }

    /// Revue UX (UX4) — issue heureuse → toast ; le moindre échec ou
    /// empêchement → alerte (il faut le lire).
    private static func outcome(of result: PhotoSaver.Result, items: [PhotoItem]) -> Outcome {
        // Lot d'assets uniquement : « garder » = ajouter à l'album, le récap
        // nomme l'album ; sans lui, rien n'a eu lieu.
        if items.allSatisfy(\.isLibraryBacked) {
            guard let album = result.albumTitle else {
                return Outcome(errorMessage: String(localized: "Ajout à l'album impossible (accès photothèque limité). Rien n'a été modifié."))
            }
            return Outcome(successToast: result.saved > 1
                ? String(localized: "\(result.saved) photos ajoutées à « \(album) »")
                : String(localized: "\(result.saved) photo ajoutée à « \(album) »"))
        }
        guard result.failed == 0 else {
            // Photo seule (viewer, menu contextuel) : l'échec la nomme.
            if items.count == 1, let item = items.first {
                return Outcome(errorMessage: String(localized: "L'enregistrement de \(item.filename) a échoué."))
            }
            return Outcome(errorMessage: String(localized: "\(result.saved) enregistrée(s), \(result.failed) en échec."))
        }
        // Retour Owen : le toast dit l'essentiel — « carte intacte » et
        // l'album de destination sont du détail (badge bleu, sheet Album).
        return Outcome(successToast: result.saved > 1
            ? String(localized: "\(result.saved) photos enregistrées")
            : String(localized: "\(result.saved) photo enregistrée"))
    }
}
