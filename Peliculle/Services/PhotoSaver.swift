import Photos

/// F6 + Jalon 10 — la couche « destination », adaptée au backing :
/// - **Fichier (carte SD)** : copie le **fichier original** (pas le preview)
///   dans la pellicule iOS ; la carte n'est pas modifiée.
/// - **Asset photothèque** : la photo y est **déjà** → rien à copier, garder
///   = **ajouter à l'album de destination** (non destructif, l'original reste
///   où il est). Sans album demandé, il n'y a tout simplement rien à faire —
///   l'UI le signale en amont.
///
/// Rangement (idées 8/8bis) : le lot est regroupé dans l'album demandé par
/// l'appelant (voir `AlbumDestination` — daté, nommé, ou aucun). Créer /
/// retrouver un album exige l'accès photothèque **complet** (`.readWrite`) ;
/// si l'utilisateur ne l'accorde pas, on retombe sur le comportement
/// historique **ajout seul** (`.addOnly`) : les photos sont enregistrées en
/// vrac, jamais d'échec à cause de l'album. Sans album demandé, on ne demande
/// d'ailleurs que l'ajout seul.
enum PhotoSaver {

    enum SaveError: LocalizedError {
        case notAuthorized

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return String(localized: "Autorisation d'ajout à la photothèque refusée.")
            }
        }
    }

    struct Result {
        var saved: Int
        var failed: Int
        /// Titre de l'album où le lot a été rangé, `nil` si enregistré en
        /// vrac (aucun album demandé, ou accès complet refusé).
        var albumTitle: String?
    }

    /// Niveau d'accès obtenu : `.full` permet en plus le rangement en album.
    private enum Access {
        case none
        case addOnly
        case full
    }

    /// Récupère l'identifiant créé dans un bloc `performChanges` (`@Sendable`,
    /// exécuté sur la file PhotoKit) : écrit dans le bloc, lu après l'`await`
    /// — jamais d'accès concurrent, d'où le `@unchecked`.
    private final class PlaceholderBox: @unchecked Sendable {
        var id: String?
    }

    /// Enregistre les items un par un pour pouvoir reporter la progression et
    /// isoler les échecs éventuels. Chaque item traité avec succès est marqué
    /// `savedToLibrary`, puis le lot est rangé dans `albumTitle` (nil = pas
    /// d'album). Les items déjà en photothèque (backing asset) rejoignent
    /// directement l'album.
    ///
    /// `@MainActor` : la boucle lit et marque l'état de tri des items
    /// (isolé main actor) ; le travail lourd (copie, album) se fait de toute
    /// façon derrière les `await` de PhotoKit, sur ses files à lui.
    @MainActor
    static func save(
        _ items: [PhotoItem],
        albumTitle: String? = nil,
        progress: @MainActor (Int) -> Void = { _ in }
    ) async throws -> Result {
        // Un lot d'assets sans album : rien à copier, rien à ranger — on
        // refuse plutôt que de faire semblant (l'UI demande l'album en amont).
        let needsAlbum = albumTitle != nil || items.contains { $0.asset != nil }
        let access = await requestAccess(needsAlbum: needsAlbum)
        guard access != .none else { throw SaveError.notAuthorized }

        var result = Result(saved: 0, failed: 0)
        var savedAssetIDs: [String] = []
        // Assets dont l'« enregistrement » **est** l'ajout à l'album : comptés
        // et marqués seulement une fois l'ajout réellement effectué (fin de
        // lot) — l'album est tout ce que « garder » fait sur une source
        // photothèque, le badge et le récap doivent dire vrai.
        var pendingAlbumItems: [PhotoItem] = []
        for (offset, item) in items.enumerated() {
            switch item.backing {
            case .file(let url):
                // Batch H5 (Q3) — déjà téléchargée et **encore présente** dans
                // la photothèque : ne pas recréer de copie (ce serait un
                // doublon). On la traite comme un asset — elle rejoint l'album
                // de destination si demandé, comptée seulement dans ce cas.
                // Le re-contrôle d'existence couvre « supprimée depuis Photos
                // entre-temps » : `savedAssetID` ne se résout plus → on retombe
                // sur la copie normale (la réconciliation l'aurait déjà nettoyé,
                // mais ce garde-fou rend l'enregistrement sûr à l'instant T).
                if item.savedToLibrary, let existingID = item.savedAssetID,
                   Self.assetExists(withID: existingID) {
                    if access == .full, albumTitle != nil {
                        savedAssetIDs.append(existingID)
                        pendingAlbumItems.append(item)
                    }
                    // Sinon : déjà dans la pellicule, aucun album demandé — rien
                    // à faire, surtout pas une seconde copie.
                    progress(offset + 1)
                    continue
                }
                let placeholder = PlaceholderBox()
                do {
                    // Idée 18 — même flux pour un clip vidéo, seule la
                    // nature de la ressource change.
                    let resourceType: PHAssetResourceType = item.isVideo ? .video : .photo
                    try await PHPhotoLibrary.shared().performChanges {
                        let request = PHAssetCreationRequest.forAsset()
                        let options = PHAssetResourceCreationOptions()
                        options.shouldMoveFile = false // on ne touche pas la carte
                        request.addResource(with: resourceType, fileURL: url, options: options)
                        placeholder.id = request.placeholderForCreatedAsset?.localIdentifier
                    }
                    // La copie est un enregistrement à part entière : comptée
                    // même si le rangement en album échoue ensuite (la photo
                    // est alors en vrac, le récap le dira).
                    result.saved += 1
                    if let placeholderID = placeholder.id { savedAssetIDs.append(placeholderID) }
                    // Batch H5 ① — mémoriser l'asset créé : en session combinée
                    // (carte + photothèque), c'est lui qui identifie le doublon
                    // côté photothèque (même fichier). Persisté par `SessionStore`.
                    item.savedToLibrary = true
                    item.savedAssetID = placeholder.id
                } catch {
                    result.failed += 1
                }
            case .asset(let asset):
                // Sans accès complet (ou sans album), l'ajout est impossible :
                // compté en échec, la photo n'est **pas** marquée.
                if access == .full, albumTitle != nil {
                    savedAssetIDs.append(asset.localIdentifier)
                    pendingAlbumItems.append(item)
                } else {
                    result.failed += 1
                }
            }
            progress(offset + 1)
        }

        if access == .full, let albumTitle, !savedAssetIDs.isEmpty {
            if await addToAlbum(titled: albumTitle, assetIDs: savedAssetIDs) {
                result.albumTitle = albumTitle
                result.saved += pendingAlbumItems.count
                for item in pendingAlbumItems {
                    item.savedToLibrary = true
                }
            } else {
                // L'album n'a pas pu être créé/retrouvé : les copies de
                // fichiers restent valables (en vrac), mais pour un asset
                // rien n'a eu lieu — échec, sans marquage.
                result.failed += pendingAlbumItems.count
            }
        }
        return result
    }

    // MARK: - Autorisation

    /// Sans album demandé, `.addOnly` suffit (posture minimale historique).
    /// Sinon on demande `.readWrite` (nécessaire à l'album) ; refusé ou
    /// limité ? On se rabat sur `.addOnly` — un accès déjà accordé lors d'une
    /// version précédente reste valable sans nouvelle alerte.
    private static func requestAccess(needsAlbum: Bool) async -> Access {
        if needsAlbum {
            switch await PHPhotoLibrary.requestAuthorization(for: .readWrite) {
            case .authorized:
                return .full
            case .limited:
                // L'ajout d'assets fonctionne en accès limité, pas les albums.
                return .addOnly
            default:
                break
            }
        }
        let addOnly = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        return (addOnly == .authorized || addOnly == .limited) ? .addOnly : .none
    }

    /// Vrai si l'asset au `localIdentifier` donné existe **encore** dans la
    /// photothèque (Batch H5 Q3) — dernier rempart contre le doublon : on ne
    /// recopie un fichier carte que si sa copie précédente a réellement
    /// disparu. Fetch léger par identifiant.
    private static func assetExists(withID id: String) -> Bool {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject != nil
    }

    // MARK: - Album de destination (idées 8/8bis)

    /// Ajoute les assets (fraîchement créés ou déjà existants) à l'album
    /// demandé, créé au besoin. Renvoie le succès : l'appelant n'annonce
    /// l'album (et ne compte les ajouts d'assets) que si l'ajout a vraiment
    /// eu lieu — en échec, les copies de fichiers restent en vrac.
    private static func addToAlbum(titled title: String, assetIDs: [String]) async -> Bool {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        guard assets.count > 0, let album = await album(titled: title) else { return false }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest(for: album)?.addAssets(assets)
            }
            return true
        } catch {
            return false
        }
    }

    /// Retrouve l'album par titre, ou le crée. Le fetch par titre évite de
    /// stocker des identifiants : robuste même si l'utilisateur supprime
    /// l'album entre deux enregistrements.
    private static func album(titled title: String) async -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", title)
        let existing = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumRegular, options: options
        )
        if let album = existing.firstObject { return album }

        let placeholder = PlaceholderBox()
        try? await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: title)
            placeholder.id = request.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let placeholderID = placeholder.id else { return nil }
        return PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [placeholderID], options: nil
        ).firstObject
    }
}
