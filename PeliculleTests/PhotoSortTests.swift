import Foundation
import Testing
@testable import Peliculle

struct PhotoSortTests {

    private let epoch = Date(timeIntervalSinceReferenceDate: 700_000_000)

    @Test func nomTrieNumériquement() throws {
        let folder = try Fixtures.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // localizedStandardCompare : IMG_2 avant IMG_10 (pas l'ordre ASCII).
        let img2 = try Fixtures.photo(named: "IMG_2.jpg", in: folder)
        let img10 = try Fixtures.photo(named: "IMG_10.jpg", in: folder)

        #expect(PhotoSort.name.areInOrder(img2, img10, ascending: true))
        #expect(!PhotoSort.name.areInOrder(img10, img2, ascending: true))
        #expect(PhotoSort.name.areInOrder(img10, img2, ascending: false))
    }

    @Test func dateFichierAvecÉgalitéRetombeSurLeNom() throws {
        let folder = try Fixtures.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let old = try Fixtures.photo(named: "B.jpg", in: folder, date: epoch)
        let recent = try Fixtures.photo(named: "A.jpg", in: folder, date: epoch.addingTimeInterval(60))
        let sameDate = try Fixtures.photo(named: "C.jpg", in: folder, date: epoch)

        #expect(PhotoSort.date.areInOrder(old, recent, ascending: true))
        #expect(PhotoSort.date.areInOrder(recent, old, ascending: false))
        // Même date : B avant C quel que soit le sens (départage stable).
        #expect(PhotoSort.date.areInOrder(old, sameDate, ascending: true))
        #expect(PhotoSort.date.areInOrder(old, sameDate, ascending: false))
    }

    @Test func priseDeVuePréfèreLExifÀLaDateFichier() throws {
        let folder = try Fixtures.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Copiée récemment (date fichier tardive) mais prise tôt (EXIF).
        let shotEarly = try Fixtures.photo(named: "A.jpg", in: folder, date: epoch.addingTimeInterval(3600))
        var exif = PhotoExif()
        exif.captureDate = epoch
        shotEarly.exif = exif
        let shotLate = try Fixtures.photo(named: "B.jpg", in: folder, date: epoch.addingTimeInterval(600))

        // Par date fichier, A (3600) vient après B (600)…
        #expect(PhotoSort.date.areInOrder(shotLate, shotEarly, ascending: true))
        // …mais par prise de vue, l'EXIF de A (epoch) la remet devant.
        #expect(PhotoSort.captureDate.areInOrder(shotEarly, shotLate, ascending: true))
    }

    @Test func noteDécroissanteEtDépartageParDate() throws {
        let folder = try Fixtures.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let starred = try Fixtures.photo(named: "A.jpg", in: folder, date: epoch)
        starred.rating = 4
        let plain = try Fixtures.photo(named: "B.jpg", in: folder, date: epoch.addingTimeInterval(60))
        let starredLater = try Fixtures.photo(named: "C.jpg", in: folder, date: epoch.addingTimeInterval(120))
        starredLater.rating = 4

        #expect(PhotoSort.rating.areInOrder(starred, plain, ascending: false))
        #expect(PhotoSort.rating.areInOrder(plain, starred, ascending: true))
        // Notes égales : date fichier croissante, quel que soit le sens.
        #expect(PhotoSort.rating.areInOrder(starred, starredLater, ascending: false))
        #expect(PhotoSort.rating.areInOrder(starred, starredLater, ascending: true))
    }

    @Test func tailleEtScoreEsthétique() throws {
        let folder = try Fixtures.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let heavy = try Fixtures.photo(named: "A.jpg", in: folder, date: epoch, size: 5_000)
        let light = try Fixtures.photo(named: "B.jpg", in: folder, date: epoch, size: 100)

        #expect(PhotoSort.size.areInOrder(heavy, light, ascending: false))
        #expect(PhotoSort.size.areInOrder(light, heavy, ascending: true))

        var analysis = PhotoAnalysis()
        analysis.aestheticScore = 0.8
        heavy.analysis = analysis
        // light non analysée (score -1 implicite) : derrière en décroissant.
        #expect(PhotoSort.aesthetic.areInOrder(heavy, light, ascending: false))
    }

    @Test func sensParDéfautParCritère() {
        #expect(PhotoSort.captureDate.defaultAscending)
        #expect(PhotoSort.date.defaultAscending)
        #expect(PhotoSort.name.defaultAscending)
        #expect(!PhotoSort.rating.defaultAscending)
        #expect(!PhotoSort.size.defaultAscending)
        #expect(!PhotoSort.aesthetic.defaultAscending)
    }
}
