import Foundation
import Testing
@testable import Peliculle

/// Sérialisée : ces tests écrivent de vrais fichiers de session dans
/// l'Application Support du hôte de test (puis les suppriment via la
/// sauvegarde « vierge » — même mécanisme que l'app).
@Suite(.serialized)
struct SessionStoreTests {

    // MARK: - Normalisation des clés (migration des anciens formats)

    @Test func clésAssetPassentInchangées() {
        #expect(SessionStore.normalizedKey("asset|ABC-123/L0/001") == "asset|ABC-123/L0/001")
    }

    @Test func cheminsRelatifsEtAbsolusDeviennentNomTaille() {
        #expect(SessionStore.normalizedKey("DCIM/100CANON/IMG_0001.CR2#123456") == "IMG_0001.CR2#123456")
        #expect(SessionStore.normalizedKey("/Volumes/EOS_DIGITAL/DCIM/IMG_0001.CR2#123456") == "IMG_0001.CR2#123456")
        // Déjà au bon format : intact.
        #expect(SessionStore.normalizedKey("IMG_0001.CR2#123456") == "IMG_0001.CR2#123456")
    }

    @Test func cléSansTailleRetombeSurLeNom() {
        #expect(SessionStore.normalizedKey("DCIM/100CANON/IMG_0001.CR2") == "IMG_0001.CR2")
    }

    // MARK: - Reprise et récupération par contenu

    /// Le scénario carte SD complet : trier, sauvegarder, « rebrancher » la
    /// carte sous un autre chemin (l'empreinte change), et retrouver quand
    /// même les décisions — par recoupement des clés nom + taille.
    @Test func repriseApresChangementDePointDeMontage() async throws {
        let folderA = try Fixtures.makeFolder()
        defer { try? FileManager.default.removeItem(at: folderA) }

        var items: [PhotoItem] = []
        for index in 1...4 {
            items.append(try Fixtures.photo(
                named: "IMG_000\(index).jpg", in: folderA, size: 1_000 + index
            ))
        }

        let storeA = await SessionStore.load(for: .folder(folderA, kind: .local), items: items)
        items[0].decision = .keep
        items[1].decision = .reject
        items[2].rating = 4
        storeA.save(items, album: AlbumDestination(), albumConfirmed: false, trip: TripMode())
        // L'écriture part sur une file utilitaire : on lui laisse le temps.
        try await Task.sleep(for: .milliseconds(500))

        // « Rebranchement » : même contenu, chemin différent → l'empreinte de
        // session ne retrouve rien, la récupération par contenu doit jouer.
        let folderB = folderA.deletingLastPathComponent()
            .appendingPathComponent("PeliculleTests-remount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: folderA, to: folderB)
        defer { try? FileManager.default.removeItem(at: folderB) }

        let files = try FileManager.default.contentsOfDirectory(
            at: folderB, includingPropertiesForKeys: nil
        )
        let itemsB = files.map(PhotoItem.init(url:))
        let storeB = await SessionStore.load(for: .folder(folderB, kind: .local), items: itemsB)
        let restored = storeB.apply(to: itemsB)

        #expect(storeB.recoveredFrom != nil, "la session aurait dû être récupérée par contenu")
        #expect(restored == 3)
        #expect(itemsB.first { $0.filename == "IMG_0001.jpg" }?.decision == .keep)
        #expect(itemsB.first { $0.filename == "IMG_0002.jpg" }?.decision == .reject)
        #expect(itemsB.first { $0.filename == "IMG_0003.jpg" }?.rating == 4)
        #expect(itemsB.first { $0.filename == "IMG_0004.jpg" }?.decision == .undecided)

        // Nettoyage : tout remettre à l'état vierge supprime le fichier de
        // session (comportement de `save`), rien ne traîne après le test.
        for item in itemsB {
            item.decision = .undecided
            item.rating = 0
            item.savedToLibrary = false
        }
        storeB.save(itemsB, album: AlbumDestination(), albumConfirmed: false, trip: TripMode())
        try await Task.sleep(for: .milliseconds(300))
    }

    /// Sans recoupement suffisant (< 3 clés communes), pas de récupération :
    /// une carte inconnue ne doit jamais adopter la session d'une autre.
    @Test func pasDeRécupérationSansRecoupement() async throws {
        let folderA = try Fixtures.makeFolder()
        defer { try? FileManager.default.removeItem(at: folderA) }
        var items: [PhotoItem] = []
        for index in 1...4 {
            items.append(try Fixtures.photo(
                named: "IMG_000\(index).jpg", in: folderA, size: 2_000 + index
            ))
        }
        let storeA = await SessionStore.load(for: .folder(folderA, kind: .local), items: items)
        for item in items { item.decision = .keep }
        storeA.save(items, album: AlbumDestination(), albumConfirmed: false, trip: TripMode())
        try await Task.sleep(for: .milliseconds(500))
        defer {
            // Nettoyage du fichier de session de la carte A.
            for item in items {
                item.decision = .undecided
                item.rating = 0
                item.savedToLibrary = false
            }
            storeA.save(items, album: AlbumDestination(), albumConfirmed: false, trip: TripMode())
        }

        // Une autre « carte » aux fichiers différents.
        let folderC = try Fixtures.makeFolder()
        defer { try? FileManager.default.removeItem(at: folderC) }
        let strangers = [
            try Fixtures.photo(named: "DSC_9001.jpg", in: folderC, size: 42),
            try Fixtures.photo(named: "DSC_9002.jpg", in: folderC, size: 43),
            try Fixtures.photo(named: "DSC_9003.jpg", in: folderC, size: 44),
        ]
        let storeC = await SessionStore.load(for: .folder(folderC, kind: .local), items: strangers)
        storeC.apply(to: strangers)

        #expect(storeC.recoveredFrom == nil)
        #expect(strangers.allSatisfy { $0.decision == .undecided })
    }

    // MARK: - Déduplication carte↔pellicule (Batch H5 ①)

    /// L'`localIdentifier` de l'asset créé par une copie fichier → pellicule
    /// survit à la reprise : c'est lui qui, en session combinée, identifie le
    /// doublon côté photothèque.
    @Test func idAssetCrééSurvitLaReprise() async throws {
        let folder = try Fixtures.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try Fixtures.photo(named: "IMG_5001.jpg", in: folder, size: 5_001)

        let store = await SessionStore.load(for: .folder(folder, kind: .local), items: [item])
        item.decision = .keep
        item.savedToLibrary = true
        item.savedAssetID = "ABC-123/L0/001"
        store.save([item], album: AlbumDestination(), albumConfirmed: false, trip: TripMode())
        try await Task.sleep(for: .milliseconds(500))

        // Relance : nouvelle énumération du même dossier, l'ID est restauré.
        let reItem = PhotoItem(url: folder.appendingPathComponent("IMG_5001.jpg"))
        let store2 = await SessionStore.load(for: .folder(folder, kind: .local), items: [reItem])
        store2.apply(to: [reItem])
        #expect(reItem.savedToLibrary == true)
        #expect(reItem.savedAssetID == "ABC-123/L0/001")

        // Nettoyage : état vierge → le fichier de session est supprimé.
        reItem.decision = .undecided
        reItem.savedToLibrary = false
        reItem.savedAssetID = nil
        store2.save([reItem], album: AlbumDestination(), albumConfirmed: false, trip: TripMode())
        try await Task.sleep(for: .milliseconds(300))
    }

    // MARK: - Composition combinée (Batch H5 ②)

    /// Deux sources dossier combinées : chaque photo est rattachée à sa source
    /// (`origin`) et l'ensemble est entrelacé par date de prise de vue.
    @MainActor
    @Test func compositionRattacheEtEntrelaceParDate() async throws {
        let folderA = try Fixtures.makeFolder()
        defer { try? FileManager.default.removeItem(at: folderA) }
        let folderB = try Fixtures.makeFolder()
        defer { try? FileManager.default.removeItem(at: folderB) }

        let older = try Fixtures.photo(
            named: "OLD.jpg", in: folderA,
            date: Date(timeIntervalSince1970: 1_000), size: 10
        )
        let newer = try Fixtures.photo(
            named: "NEW.jpg", in: folderB,
            date: Date(timeIntervalSince1970: 9_000), size: 11
        )

        let sourceA = PhotoSource.folder(folderA, kind: .local)
        let storeA = await SessionStore.load(for: sourceA, items: [older])
        let session = CullSession(source: sourceA, items: [older], store: storeA)

        let sourceB = PhotoSource.folder(folderB, kind: .local)
        let storeB = await SessionStore.load(for: sourceB, items: [newer])
        session.addSource(sourceB, items: [newer], store: storeB)

        #expect(older.origin == sourceA)
        #expect(newer.origin == sourceB)
        // Entrelacement chronologique : la plus ancienne d'abord.
        #expect(session.items.map(\.filename) == ["OLD.jpg", "NEW.jpg"])
        #expect(session.isCombined)
        #expect(session.hasFileSource)
        #expect(session.isLibraryOnly == false)

        // Retrait d'une source : ses photos quittent la session.
        _ = session.removeSources { $0 == sourceB }
        #expect(session.items.map(\.filename) == ["OLD.jpg"])
        #expect(session.isCombined == false)

        // État vierge → les fichiers de session sont supprimés.
        session.persistNow()
        try await Task.sleep(for: .milliseconds(300))
    }
}
