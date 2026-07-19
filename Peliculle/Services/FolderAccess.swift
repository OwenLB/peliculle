import Foundation
import Observation

/// F1 — accès aux dossiers (cartes SD, disques…) avec persistance
/// (security-scoped bookmark). Tant que la carte reste connectée, l'accès est
/// retrouvé au lancement sans re-sélection. **Lecture seule stricte** : ce type
/// ne fait qu'ouvrir un scope de lecture et énumérer.
///
/// Batch H5 — **multi-scope** : une session combinée peut réunir plusieurs
/// sources dossier (deux cartes, carte + disque). On garde donc un scope de
/// sécurité **par dossier ouvert**, jamais un seul global — ajouter un dossier
/// ne doit pas relâcher les précédents. Seule la restauration au lancement
/// reste mono-dossier (un seul bookmark persisté : le dernier ouvert).
///
/// Toutes les opérations qui touchent le volume (résolution de bookmark,
/// ouverture du scope, création de bookmark, sonde d'accessibilité) sont
/// `async` et s'exécutent **hors du main thread** : sur une carte SD lente ou
/// en cours de déconnexion, chacune peut bloquer plusieurs secondes et
/// gèlerait toute l'UI.
@MainActor
@Observable
final class FolderAccess {

    private let bookmarkKey = "peliculle.folderBookmark"

    /// Dossiers actuellement sous scope de sécurité, un par source dossier de
    /// la session. Valeur = vrai si `startAccessingSecurityScopedResource` a
    /// réellement ouvert le scope : le `stop` correspondant ne part que dans ce
    /// cas (sur-libérer un scope jamais ouvert est un déséquilibre signalé).
    private var scopes: [URL: Bool] = [:]

    /// Dernier dossier ouvert/restauré : porte le bookmark de restauration au
    /// lancement (le combiné ne restaure que celui-ci).
    private(set) var primaryURL: URL?

    /// Vrai si un bookmark existe mais n'a pas pu être résolu (carte absente,
    /// bookmark périmé) : l'UI proposera une re-sélection gracieuse.
    private(set) var needsReselection = false

    // MARK: - Ouverture

    /// Change de source dossier (choix ou restauration d'un dossier primaire) :
    /// relâche **tous** les scopes précédents puis ouvre celui-ci et persiste
    /// son bookmark. C'est le chemin « remplacer la session ».
    @discardableResult
    func open(_ url: URL) async -> Data? {
        stopAll()
        return await addScope(url)
    }

    /// Ajoute un dossier à la session **sans** relâcher les autres (Batch H5,
    /// combiné multi-dossiers). Devient le dernier ouvert (bookmark de
    /// restauration).
    @discardableResult
    func addScope(_ url: URL) async -> Data? {
        if scopes[url] == nil {
            // `start` peut renvoyer false (URL déjà accessible sans scope, ou
            // accès refusé) : la lecture tentera sa chance quand même, mais le
            // `stop` correspondant ne devra alors jamais partir.
            let started = await Task.detached(priority: .userInitiated) {
                url.startAccessingSecurityScopedResource()
            }.value
            scopes[url] = started
        }
        primaryURL = url
        needsReselection = false
        return await saveBookmark(for: url)
    }

    /// Tente de restaurer le dernier dossier connu. Renvoie l'URL si l'accès a
    /// pu être rouvert, sinon `nil` (et positionne `needsReselection`).
    func restore() async -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return nil
        }
        let resolved = await Task.detached(priority: .userInitiated) { () -> (url: URL, isStale: Bool)? in
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else {
                return nil
            }
            return (url, isStale)
        }.value

        guard let resolved else {
            needsReselection = true
            return nil
        }

        // Lancement : aucun scope précédent à relâcher — ajout simple.
        await addScope(resolved.url)
        return resolved.url
    }

    // MARK: - Cycle de vie des scopes de sécurité

    /// Relâche le scope d'un dossier précis (source retirée / carte débranchée
    /// en combiné) ; les autres dossiers restent accessibles.
    func stopAccess(_ url: URL) {
        if scopes[url] == true {
            url.stopAccessingSecurityScopedResource()
        }
        scopes[url] = nil
        if primaryURL == url { primaryURL = scopes.keys.first }
    }

    /// Relâche **tous** les scopes (changement de source, retour à l'accueil).
    func stopAll() {
        for (url, started) in scopes where started {
            url.stopAccessingSecurityScopedResource()
        }
        scopes.removeAll()
        primaryURL = nil
    }

    @discardableResult
    private func saveBookmark(for url: URL) async -> Data? {
        // Sur iOS, le bookmark d'une URL issue du sélecteur est déjà
        // security-scoped ; pas d'option `.withSecurityScope` (macOS uniquement).
        let data = await Task.detached(priority: .utility) {
            try? url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }.value
        guard let data else { return nil }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        return data
    }

    // MARK: - Robustesse

    /// Vrai tant que le dossier donné (et donc sa carte) reste accessible.
    /// Sert à détecter une déconnexion **par dossier** en cours de session.
    func isReachable(_ url: URL) async -> Bool {
        await Task.detached(priority: .utility) {
            (try? url.checkResourceIsReachable()) ?? false
        }.value
    }

    // MARK: - Lecture

    /// Énumère les photos d'un dossier, hors thread principal.
    func loadItems(from url: URL) async -> [PhotoItem] {
        await Task.detached(priority: .userInitiated) {
            FolderScanner.scan(url).map(PhotoItem.init)
        }.value
    }
}
