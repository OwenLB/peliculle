import Photos

/// Jalon 10 — accès à la photothèque comme **source de tri** : autorisation,
/// liste des albums, énumération des assets (album ou photothèque entière).
/// Lecture seule ici — la couche destination vit dans `PhotoSaver` /
/// `PhotoDeleter`.
enum PhotoLibrarySource {

    /// Un album utilisateur proposé par le sélecteur : titre, compte d'images
    /// et asset de couverture (vignette via `ThumbnailLoader`).
    struct AlbumInfo: Identifiable {
        let id: String
        let title: String
        let count: Int
        let coverAsset: PHAsset?
    }

    // MARK: - Autorisation

    /// Trier la photothèque exige l'accès **complet** en lecture (`.readWrite`
    /// couvre lecture + albums de destination). L'accès « limité » ne montre
    /// qu'une sélection : accepté aussi — l'utilisateur voit ce qu'il a choisi
    /// de partager.
    static func requestReadAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Vrai si l'accès est **déjà** accordé — pour restaurer une source
    /// photothèque au lancement sans jamais déclencher d'alerte.
    static var hasReadAccess: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Vrai seulement si l'accès **complet** (`.authorized`) est accordé. La
    /// réconciliation « la copie carte est-elle encore dans la photothèque ? »
    /// (`existingAssetIDs`) l'exige : en accès **limité**, un asset absent du
    /// fetch peut n'être qu'hors sélection partagée, pas supprimé — on
    /// démarquerait une copie à tort. Ne déclenche jamais d'alerte.
    static var hasFullReadAccess: Bool {
        PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
    }

    /// Parmi `ids`, les `localIdentifier` qui existent **encore** dans la
    /// photothèque. Fetch en lot (un seul aller PhotoKit), hors main thread.
    /// Sert à corriger le marquage « téléchargé » d'une copie carte supprimée
    /// depuis l'app Photos (Batch H5, réconciliation).
    static func existingAssetIDs(_ ids: [String]) async -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return await Task.detached(priority: .userInitiated) {
            var alive: Set<String> = []
            PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
                .enumerateObjects { asset, _, _ in alive.insert(asset.localIdentifier) }
            return alive
        }.value
    }

    /// Les `localIdentifier` des assets **contenus** dans l'album utilisateur
    /// au titre donné — appartenance réelle, pour le filtre « dans l'album de
    /// destination » d'une source photothèque (Batch H5). Vide si l'album
    /// n'existe pas (encore). Fetch hors main thread.
    static func assetIDs(inAlbumTitled title: String) async -> Set<String> {
        await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.predicate = NSPredicate(format: "title = %@", title)
            let albums = PHAssetCollection.fetchAssetCollections(
                with: .album, subtype: .albumRegular, options: options
            )
            guard let album = albums.firstObject else { return Set<String>() }
            var ids: Set<String> = []
            PHAsset.fetchAssets(in: album, options: nil)
                .enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
            return ids
        }.value
    }

    // MARK: - Albums

    /// Les albums utilisateur, dans l'ordre de la photothèque, avec leur
    /// compte d'**images** (les vidéos sont hors périmètre de l'app).
    static func userAlbums() async -> [AlbumInfo] {
        await Task.detached(priority: .userInitiated) {
            let collections = PHAssetCollection.fetchAssetCollections(
                with: .album, subtype: .albumRegular, options: nil
            )
            var albums: [AlbumInfo] = []
            collections.enumerateObjects { collection, _, _ in
                let assets = PHAsset.fetchAssets(in: collection, options: Self.imagesOnly)
                // On n'affiche pas les albums vides : ils n'apportent rien comme
                // source de tri, et écartent le bruit d'albums hérités (structures
                // de culling « étoiles / rejected / flagged / exported »
                // synchronisées par un autre appareil ou une app tierce, souvent
                // sans photo sur ce téléphone).
                guard assets.count > 0 else { return }
                albums.append(AlbumInfo(
                    id: collection.localIdentifier,
                    title: collection.localizedTitle ?? "Album",
                    count: assets.count,
                    coverAsset: assets.firstObject
                ))
            }
            return albums
        }.value
    }

    // MARK: - Énumération des photos

    /// Les photos d'une source photothèque, en `PhotoItem` prêts pour la
    /// session. `albumID` nil = la photothèque, bornée par `scope` : la
    /// période descend en **prédicat de fetch** — les photos hors période ne
    /// sont jamais matérialisées, c'est ce qui rend une photothèque de
    /// 10 000 photos triable. Ordre chronologique de prise de vue (le tri
    /// d'affichage de la grille reste maître ensuite).
    /// `@MainActor` pour le remplissage EXIF final : l'énumération (fetch
    /// PhotoKit) reste en tâche détachée, seule l'affectation aux items —
    /// état isolé main actor — revient sur le main thread (aucune I/O).
    @MainActor
    static func loadItems(albumID: String?, scope: LibraryScope = .all) async -> [PhotoItem] {
        let loaded: [(item: PhotoItem, exif: PhotoExif)] = await Task.detached(priority: .userInitiated) {
            let options = fetchOptions(scope: albumID == nil ? scope : .all)
            let fetched: PHFetchResult<PHAsset>
            if let albumID,
               let collection = PHAssetCollection.fetchAssetCollections(
                   withLocalIdentifiers: [albumID], options: nil
               ).firstObject {
                fetched = PHAsset.fetchAssets(in: collection, options: options)
            } else if albumID == nil {
                fetched = PHAsset.fetchAssets(with: options)
            } else {
                // Album introuvable (supprimé depuis) : source vide, l'UI
                // affiche son état « aucune photo ».
                return []
            }
            var items: [(item: PhotoItem, exif: PhotoExif)] = []
            items.reserveCapacity(fetched.count)
            fetched.enumerateObjects { asset, _, _ in
                // EXIF rempli à la naissance (date + GPS portés par PHAsset,
                // aucune I/O) : la passe d'indexation de session n'a plus
                // rien à faire sur une source photothèque.
                items.append((PhotoItem(asset: asset), ExifIndexer.lightweightExif(for: asset)))
            }
            return items
        }.value
        return loaded.map { item, exif in
            item.exif = exif
            return item
        }
    }

    private static var imagesOnly: PHFetchOptions {
        fetchOptions(scope: .all)
    }

    private static func fetchOptions(scope: LibraryScope) -> PHFetchOptions {
        let options = PHFetchOptions()
        var predicates = [
            NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
        ]
        let bounds = scope.fetchBounds
        if let start = bounds.start {
            predicates.append(NSPredicate(format: "creationDate >= %@", start as NSDate))
        }
        if let end = bounds.end {
            predicates.append(NSPredicate(format: "creationDate < %@", end as NSDate))
        }
        options.predicate = predicates.count == 1
            ? predicates[0]
            : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return options
    }
}
